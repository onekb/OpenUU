import AppKit
@preconcurrency import AVFoundation
import CoreMedia
import Foundation

/// Real-time video stream telemetry displayed in the bottom-left Debug HUD overlay.
struct VideoStreamTelemetry: Sendable {
    let fps: Int
    let hostFPS: Int
    let maxGapMs: Int
    let bitrateMbps: Double
    let encodedWidth: Int
    let encodedHeight: Int
    let logicalWidth: Int
    let logicalHeight: Int
    let scaleRatio: Double
    let avgDecodeMs: Double
    let lastFrameBytes: Int
    let isLastKeyframe: Bool
    let skippedBurstFrames: Int
    let updatedAt: CFAbsoluteTime
}

/// Thread-safe lock-protected router that enqueues incoming QUIC video packets directly onto each window's
/// dedicated `VideoDisplayRenderer` queue without hopping through `@MainActor`.
final class FastVideoRouter: @unchecked Sendable {
    private struct Entry {
        let renderer: VideoDisplayRenderer
        var width: UInt16
        var height: UInt16
    }

    private let lock = NSLock()
    private var entries: [UInt32: Entry] = [:]

    func renderer(for windowID: UInt32) -> VideoDisplayRenderer {
        lock.lock()
        defer { lock.unlock() }
        if let existing = entries[windowID] {
            return existing.renderer
        }
        let created = VideoDisplayRenderer()
        entries[windowID] = Entry(renderer: created, width: 0, height: 0)
        return created
    }

    /// Enqueues the video packet directly onto the window's renderQueue in strict FIFO order.
    /// Returns `true` if this is the first frame or if the encoded dimensions changed (requiring a `@MainActor` window sync).
    func routeAndEnqueue(_ packet: EncodedVideoPacket) -> Bool {
        lock.lock()
        var needsWindowSync = false
        let targetRenderer: VideoDisplayRenderer
        if var existing = entries[packet.windowID] {
            if existing.width != packet.width || existing.height != packet.height {
                existing.width = packet.width
                existing.height = packet.height
                entries[packet.windowID] = existing
                needsWindowSync = true
            }
            targetRenderer = existing.renderer
        } else {
            let created = VideoDisplayRenderer()
            entries[packet.windowID] = Entry(renderer: created, width: packet.width, height: packet.height)
            targetRenderer = created
            needsWindowSync = true
        }
        lock.unlock()

        targetRenderer.enqueue(packet: packet)
        return needsWindowSync
    }

    func unregister(windowID: UInt32) {
        lock.lock()
        entries.removeValue(forKey: windowID)
        lock.unlock()
    }

    func clear() {
        lock.lock()
        entries.removeAll()
        lock.unlock()
    }
}

/// Hardware-accelerated H.264 renderer backed by `AVSampleBufferDisplayLayer` with a Client-clock VSync Frame Pacer.
/// - Drives `displayLayer.controlTimebase` strictly from the Client Mac's local `CMClockGetHostTimeClock()` (rate = 1.0),
///   completely decoupling playback from the Host Mac's boot clock (zero clock-drift stalls).
/// - Smoothly micro-paces Wi-Fi / QUIC packet bursts across consecutive VSync intervals (`+12ms` spacing, capped at `38ms` max lead)
///   so burst frames are never overwritten before VSync by `DisplayImmediately`.
final class VideoDisplayRenderer: @unchecked Sendable {
    let displayLayer = AVSampleBufferDisplayLayer()
    private nonisolated(unsafe) var sbRenderer: AVSampleBufferVideoRenderer?
    private nonisolated(unsafe) var controlTimebase: CMTimebase?
    private var lastScheduledPTS: Double = 0
    private var formatDescription: CMVideoFormatDescription?
    private var lastSPS: Data?
    private var lastPPS: Data?
    private let renderQueue = DispatchQueue(label: "com.chameye.render", qos: .userInteractive)

    var onTelemetryUpdated: ((VideoStreamTelemetry) -> Void)?
    private var statsWindowStartAt: CFAbsoluteTime = 0
    private var statsFramesInWindow: Int = 0
    private var statsBytesInWindow: Int = 0
    private var statsDecodeMsSum: Double = 0
    private var statsSkippedFrames: Int = 0
    private var lastFrameArrivalAt: CFAbsoluteTime = 0
    private var maxGapMsInWindow: Int = 0
    private var windowFirstHostPTSUS: UInt64 = 0
    private var windowLastHostPTSUS: UInt64 = 0
    private var lastTelemetrySnapshot: VideoStreamTelemetry?

    init() {
        displayLayer.backgroundColor = CGColor.clear
        displayLayer.actions = [
            "contents": NSNull(),
            "bounds": NSNull(),
            "position": NSNull(),
        ]
        let sel = NSSelectorFromString("sampleBufferRenderer")
        if displayLayer.responds(to: sel),
           let unmanaged = displayLayer.perform(sel) {
            sbRenderer = unmanaged.takeUnretainedValue() as? AVSampleBufferVideoRenderer
        }
        setupClientClockTimebase()
    }

    private func setupClientClockTimebase() {
        var tb: CMTimebase?
        let hostClock = CMClockGetHostTimeClock()
        if CMTimebaseCreateWithSourceClock(
            allocator: kCFAllocatorDefault,
            sourceClock: hostClock,
            timebaseOut: &tb
        ) == noErr, let tb {
            CMTimebaseSetTime(tb, time: CMClockGetTime(hostClock))
            CMTimebaseSetRate(tb, rate: 1.0)
            controlTimebase = tb
        }
    }

    @MainActor
    func configureOnMainActor() {
        displayLayer.videoGravity = .resize
        displayLayer.backgroundColor = CGColor.clear
        sbRenderer = displayLayer.sampleBufferRenderer
        if let tb = controlTimebase {
            displayLayer.controlTimebase = tb
        }
    }

    func enqueue(packet: EncodedVideoPacket) {
        renderQueue.async { [weak self] in
            self?.processAnnexB(packet: packet)
        }
    }

    private func processAnnexB(packet: EncodedVideoPacket) {
        let startTime = CFAbsoluteTimeGetCurrent()
        let data = packet.data
        let ranges = splitAnnexBRanges(data)
        guard !ranges.isEmpty else { return }

        var sps: Data?
        var pps: Data?
        var sliceRanges: [Range<Int>] = []
        sliceRanges.reserveCapacity(ranges.count)
        var totalAVCCLen = 0

        data.withUnsafeBytes { rawBuf in
            guard let base = rawBuf.bindMemory(to: UInt8.self).baseAddress else { return }
            for range in ranges {
                let firstByte = base[range.lowerBound]
                let naluType = firstByte & 0x1F
                switch naluType {
                case 7:
                    sps = Data(bytes: base.advanced(by: range.lowerBound), count: range.count)
                case 8:
                    pps = Data(bytes: base.advanced(by: range.lowerBound), count: range.count)
                case 1, 5:
                    sliceRanges.append(range)
                    totalAVCCLen += 4 + range.count
                default:
                    break
                }
            }
        }

        if let sps, let pps, (sps != lastSPS || pps != lastPPS || formatDescription == nil) {
            lastSPS = sps
            lastPPS = pps
            formatDescription = makeH264FormatDescription(sps: sps, pps: pps)
        }

        guard let formatDesc = formatDescription,
              !sliceRanges.isEmpty,
              totalAVCCLen > 0 else {
            return
        }

        var blockBuffer: CMBlockBuffer?
        let status = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: totalAVCCLen,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: totalAVCCLen,
            flags: kCMBlockBufferAssureMemoryNowFlag,
            blockBufferOut: &blockBuffer
        )
        guard status == kCMBlockBufferNoErr, let blockBuffer else { return }

        var dstPtr: UnsafeMutablePointer<Int8>?
        guard CMBlockBufferGetDataPointer(
            blockBuffer,
            atOffset: 0,
            lengthAtOffsetOut: nil,
            totalLengthOut: nil,
            dataPointerOut: &dstPtr
        ) == kCMBlockBufferNoErr, let dstPtr else { return }

        data.withUnsafeBytes { rawBuf in
            guard let srcBase = rawBuf.baseAddress else { return }
            var writeOffset = 0
            for range in sliceRanges {
                let naluLen = range.count
                var lenBE = UInt32(naluLen).bigEndian
                memcpy(dstPtr.advanced(by: writeOffset), &lenBE, 4)
                writeOffset += 4
                memcpy(dstPtr.advanced(by: writeOffset), srcBase.advanced(by: range.lowerBound), naluLen)
                writeOffset += naluLen
            }
        }

        let isFirstFrame = (lastScheduledPTS == 0)
        let isKeyframe = (packet.flags & 0x01) != 0
        let nowSec = controlTimebase.map { CMTimebaseGetTime($0).seconds }
            ?? CMClockGetTime(CMClockGetHostTimeClock()).seconds

        let scheduledSec: Double
        var shouldFlushBeforeEnqueue = false
        if isFirstFrame || lastScheduledPTS <= nowSec {
            scheduledSec = nowSec + 0.002
        } else {
            let backlog = lastScheduledPTS - nowSec
            if isKeyframe && backlog > 0.026 {
                // Fresh IDR keyframe arrived while old burst frames are queued: jump directly to present.
                shouldFlushBeforeEnqueue = true
                scheduledSec = nowSec + 0.002
            } else {
                // Smoothly pace Wi-Fi / QUIC burst frames across consecutive VSyncs (+13ms normal, +9ms catch-up),
                // strictly bounded to <= 38ms maximum lead so latency never accumulates.
                let step = backlog > 0.020 ? 0.009 : 0.013
                scheduledSec = min(nowSec + 0.038, lastScheduledPTS + step)
            }
        }
        lastScheduledPTS = scheduledSec

        var timing = CMSampleTimingInfo(
            duration: .invalid,
            presentationTimeStamp: CMTime(seconds: scheduledSec, preferredTimescale: 1_000_000),
            decodeTimeStamp: .invalid
        )
        var sampleSize = totalAVCCLen
        var sampleBuffer: CMSampleBuffer?
        let sbStatus = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: blockBuffer,
            formatDescription: formatDesc,
            sampleCount: 1,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &sampleSize,
            sampleBufferOut: &sampleBuffer
        )
        guard sbStatus == noErr, let sampleBuffer else { return }

        if isFirstFrame,
           let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: true) {
            let dict = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(
                dict,
                Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                Unmanaged.passUnretained(kCFBooleanTrue).toOpaque()
            )
        }

        if let renderer = sbRenderer {
            if renderer.status == .failed || shouldFlushBeforeEnqueue {
                renderer.flush()
            }
            renderer.enqueue(sampleBuffer)
        }

        let endTime = CFAbsoluteTimeGetCurrent()
        let decodeMs = max(0, (endTime - startTime) * 1000.0)
        recordFrameTelemetry(
            packet: packet,
            formatDesc: formatDesc,
            decodeMs: decodeMs,
            wasSuppressed: false,
            now: endTime
        )
    }

    private func recordFrameTelemetry(
        packet: EncodedVideoPacket,
        formatDesc: CMVideoFormatDescription,
        decodeMs: Double,
        wasSuppressed: Bool,
        now: CFAbsoluteTime
    ) {
        if statsWindowStartAt == 0 {
            statsWindowStartAt = now
        }
        if lastFrameArrivalAt > 0 {
            let gapMs = Int(round(max(0, (now - lastFrameArrivalAt) * 1000.0)))
            if gapMs < 1500 {
                maxGapMsInWindow = max(maxGapMsInWindow, gapMs)
            }
        }
        lastFrameArrivalAt = now
        if packet.timestampUS > 0 {
            if windowFirstHostPTSUS == 0 {
                windowFirstHostPTSUS = packet.timestampUS
            }
            windowLastHostPTSUS = packet.timestampUS
        }
        statsFramesInWindow += 1
        statsBytesInWindow += packet.data.count
        statsDecodeMsSum += decodeMs
        if wasSuppressed {
            statsSkippedFrames += 1
        }

        let elapsed = now - statsWindowStartAt
        guard elapsed >= 0.45 else { return }

        let fps = Int(round(Double(statsFramesInWindow) / elapsed))
        let hostFPS: Int
        if windowLastHostPTSUS > windowFirstHostPTSUS && statsFramesInWindow > 1 {
            let hostSpanSec = Double(windowLastHostPTSUS - windowFirstHostPTSUS) / 1_000_000.0
            hostFPS = hostSpanSec > 0.05 ? Int(round(Double(statsFramesInWindow - 1) / hostSpanSec)) : fps
        } else {
            hostFPS = fps
        }
        let bitrateMbps = (Double(statsBytesInWindow) * 8.0) / (elapsed * 1_000_000.0)
        let avgDecodeMs = statsFramesInWindow > 0 ? (statsDecodeMsSum / Double(statsFramesInWindow)) : decodeMs
        let dims = CMVideoFormatDescriptionGetDimensions(formatDesc)
        let encW = Int(dims.width)
        let encH = Int(dims.height)
        let logW = max(1, Int(packet.width) / 2)
        let logH = max(1, Int(packet.height) / 2)
        let scale = Double(encW) / Double(logW)

        let snapshot = VideoStreamTelemetry(
            fps: fps,
            hostFPS: hostFPS,
            maxGapMs: maxGapMsInWindow,
            bitrateMbps: bitrateMbps,
            encodedWidth: encW,
            encodedHeight: encH,
            logicalWidth: logW,
            logicalHeight: logH,
            scaleRatio: scale,
            avgDecodeMs: avgDecodeMs,
            lastFrameBytes: packet.data.count,
            isLastKeyframe: (packet.flags & 0x01) != 0,
            skippedBurstFrames: statsSkippedFrames,
            updatedAt: now
        )
        lastTelemetrySnapshot = snapshot
        statsWindowStartAt = now
        statsFramesInWindow = 0
        statsBytesInWindow = 0
        statsDecodeMsSum = 0
        maxGapMsInWindow = 0
        windowFirstHostPTSUS = 0
        windowLastHostPTSUS = 0

        if let cb = onTelemetryUpdated {
            cb(snapshot)
        }
    }

    /// Scans Annex-B start codes (`00 00 00 01` or `00 00 01`) directly over the raw buffer pointer
    /// without allocating intermediate `[UInt8]` or `[Data]` slices.
    private func splitAnnexBRanges(_ data: Data) -> [Range<Int>] {
        var result: [Range<Int>] = []
        result.reserveCapacity(4)
        data.withUnsafeBytes { rawBuf in
            guard let bytes = rawBuf.bindMemory(to: UInt8.self).baseAddress else { return }
            let count = rawBuf.count
            var i = 0
            var naluStart: Int?

            while i + 2 < count {
                if bytes[i] == 0 && bytes[i + 1] == 0 {
                    let is4Byte = (i + 3 < count) && bytes[i + 2] == 0 && bytes[i + 3] == 1
                    let is3Byte = !is4Byte && bytes[i + 2] == 1
                    if is4Byte || is3Byte {
                        if let start = naluStart, start < i {
                            result.append(start..<i)
                        }
                        i += is4Byte ? 4 : 3
                        naluStart = i
                        continue
                    }
                }
                i += 1
            }
            if let start = naluStart, start < count {
                result.append(start..<count)
            }
        }
        return result
    }

    private func makeH264FormatDescription(sps: Data, pps: Data) -> CMVideoFormatDescription? {
        var desc: CMVideoFormatDescription?
        let status: OSStatus = sps.withUnsafeBytes { spsRaw in
            pps.withUnsafeBytes { ppsRaw in
                guard let spsPtr = spsRaw.bindMemory(to: UInt8.self).baseAddress,
                      let ppsPtr = ppsRaw.bindMemory(to: UInt8.self).baseAddress else {
                    return -1
                }
                let ptrs: [UnsafePointer<UInt8>] = [spsPtr, ppsPtr]
                let sizes: [Int] = [sps.count, pps.count]
                return CMVideoFormatDescriptionCreateFromH264ParameterSets(
                    allocator: kCFAllocatorDefault,
                    parameterSetCount: 2,
                    parameterSetPointers: ptrs,
                    parameterSetSizes: sizes,
                    nalUnitHeaderLength: 4,
                    formatDescriptionOut: &desc
                )
            }
        }
        return status == noErr ? desc : nil
    }
}
