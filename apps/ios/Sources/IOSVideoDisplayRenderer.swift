@preconcurrency import AVFoundation
import CoreMedia
import Foundation
import UIKit

/// Real-time hardware decode telemetry displayed in the Debug HUD overlay.
struct VideoStreamTelemetry: Sendable, Equatable {
    let codecName: String
    let fps: Int
    let bitrateMbps: Double
    let encodedWidth: Int
    let encodedHeight: Int
    let decodedFrames: UInt64
    let avgDecodeMs: Double
    let isLastKeyframe: Bool

    static let empty = VideoStreamTelemetry(
        codecName: "—",
        fps: 0,
        bitrateMbps: 0,
        encodedWidth: 0,
        encodedHeight: 0,
        decodedFrames: 0,
        avgDecodeMs: 0,
        isLastKeyframe: false
    )
}

/// Hardware-accelerated H.264 / HEVC Annex-B -> AVCC/HVCC video renderer backed by
/// `AVSampleBufferDisplayLayer` + Client-clock `CMTimebase` VSync micro-pacer.
final class IOSVideoDisplayRenderer: @unchecked Sendable {
    let displayLayer = AVSampleBufferDisplayLayer()

    private nonisolated(unsafe) var sbRenderer: AVSampleBufferVideoRenderer?
    private nonisolated(unsafe) var controlTimebase: CMTimebase?
    private let renderQueue = DispatchQueue(label: "ren.onekb.openuu.render", qos: .userInteractive)

    private var formatDescription: CMVideoFormatDescription?
    private var lastVPS: Data?
    private var lastSPS: Data?
    private var lastPPS: Data?
    private var lastCodec: UInt8 = 0
    private var lastScheduledPTS: Double = 0
    private var maxJitterLeadSec: Double = 0.038

    // Live telemetry counters (mutated strictly on renderQueue)
    private var decodedFramesTotal: UInt64 = 0
    private var statsWindowStartAt: CFAbsoluteTime = 0
    private var statsFramesInWindow: Int = 0
    private var statsBytesInWindow: Int = 0
    private var statsDecodeMsSum: Double = 0
    private var lastPublishedFPS: Int = 0
    private var lastPublishedBitrateMbps: Double = 0
    private var lastKeyframeRequestAt: CFAbsoluteTime = 0

    var onTelemetryUpdated: (@Sendable (VideoStreamTelemetry) -> Void)?
    var onRequestKeyframe: (@Sendable () -> Void)?

    @MainActor
    init() {
        displayLayer.videoGravity = .resizeAspect
        displayLayer.backgroundColor = UIColor.clear.cgColor
        displayLayer.actions = [
            "contents": NSNull(),
            "bounds": NSNull(),
            "position": NSNull(),
        ]
        setupClientClockTimebase()
        if let tb = controlTimebase {
            displayLayer.controlTimebase = tb
        }
        sbRenderer = displayLayer.sampleBufferRenderer
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
    func configureOnMainActor(videoFitMode: VideoFitMode = .fit) {
        displayLayer.videoGravity = (videoFitMode == .fill) ? .resizeAspectFill : .resizeAspect
        displayLayer.backgroundColor = UIColor.clear.cgColor
        nonisolated(unsafe) let renderer = displayLayer.sampleBufferRenderer
        if let tb = controlTimebase {
            displayLayer.controlTimebase = tb
        }
        renderQueue.async { [weak self] in
            self?.sbRenderer = renderer
        }
    }

    @MainActor
    func setVideoFitMode(_ mode: VideoFitMode) {
        displayLayer.videoGravity = (mode == .fill) ? .resizeAspectFill : .resizeAspect
    }

    func setWanJitterMode(_ enabled: Bool) {
        renderQueue.async { [weak self] in
            self?.maxJitterLeadSec = enabled ? 0.075 : 0.038
        }
    }

    func enqueue(packet: EncodedVideoPacket) {
        renderQueue.async { [weak self] in
            self?.processAnnexB(packet: packet)
        }
    }

    /// Flushes the display layer, removes the displayed image, and resets decoder state for a new stream.
    func resetStream(resetDecodedCounter: Bool = true) {
        renderQueue.async { [weak self] in
            guard let self else { return }
            self.formatDescription = nil
            self.lastVPS = nil
            self.lastSPS = nil
            self.lastPPS = nil
            self.lastCodec = 0
            self.lastScheduledPTS = 0
            self.statsWindowStartAt = 0
            self.statsFramesInWindow = 0
            self.statsBytesInWindow = 0
            self.statsDecodeMsSum = 0
            self.lastPublishedFPS = 0
            self.lastPublishedBitrateMbps = 0
            if resetDecodedCounter {
                self.decodedFramesTotal = 0
            }
            if let renderer = self.sbRenderer {
                renderer.flush(removingDisplayedImage: true, completionHandler: nil)
            }
        }
        DispatchQueue.main.async { [weak self] in
            self?.displayLayer.sampleBufferRenderer.flush(removingDisplayedImage: true, completionHandler: nil)
        }
    }

    private func processAnnexB(packet: EncodedVideoPacket) {
        let startTime = CFAbsoluteTimeGetCurrent()
        let data = packet.data
        let ranges = splitAnnexBRanges(data)
        guard !ranges.isEmpty else { return }

        let isHEVC = (packet.codec == 2)
        var vps: Data?
        var sps: Data?
        var pps: Data?
        var sliceRanges: [Range<Int>] = []
        sliceRanges.reserveCapacity(ranges.count)
        var totalAVCCLen = 0

        data.withUnsafeBytes { rawBuf in
            guard let base = rawBuf.bindMemory(to: UInt8.self).baseAddress else { return }
            for range in ranges {
                guard range.lowerBound < range.upperBound else { continue }
                let firstByte = base[range.lowerBound]
                if isHEVC {
                    let naluType = (firstByte >> 1) & 0x3F
                    switch naluType {
                    case 32:
                        vps = Data(bytes: base.advanced(by: range.lowerBound), count: range.count)
                    case 33:
                        sps = Data(bytes: base.advanced(by: range.lowerBound), count: range.count)
                    case 34:
                        pps = Data(bytes: base.advanced(by: range.lowerBound), count: range.count)
                    case 0...9, 16...21:
                        sliceRanges.append(range)
                        totalAVCCLen += 4 + range.count
                    default:
                        break
                    }
                } else {
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
        }

        if isHEVC {
            if let vps, let sps, let pps,
               (vps != lastVPS || sps != lastSPS || pps != lastPPS || lastCodec != 2 || formatDescription == nil) {
                lastVPS = vps
                lastSPS = sps
                lastPPS = pps
                lastCodec = 2
                formatDescription = makeHEVCFormatDescription(vps: vps, sps: sps, pps: pps)
            }
        } else {
            if let sps, let pps,
               (sps != lastSPS || pps != lastPPS || lastCodec != 1 || formatDescription == nil) {
                lastVPS = nil
                lastSPS = sps
                lastPPS = pps
                lastCodec = 1
                formatDescription = makeH264FormatDescription(sps: sps, pps: pps)
            }
        }

        guard let formatDesc = formatDescription else {
            maybeRequestKeyframe(now: startTime)
            return
        }
        guard !sliceRanges.isEmpty, totalAVCCLen > 0 else { return }

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
        let flushThreshold = maxJitterLeadSec * 0.72
        if isFirstFrame || lastScheduledPTS <= nowSec {
            scheduledSec = nowSec + 0.002
        } else {
            let backlog = lastScheduledPTS - nowSec
            if isKeyframe && backlog > flushThreshold {
                shouldFlushBeforeEnqueue = true
                scheduledSec = nowSec + 0.002
            } else {
                let step = backlog > (maxJitterLeadSec * 0.52) ? 0.009 : 0.014
                scheduledSec = min(nowSec + maxJitterLeadSec, lastScheduledPTS + step)
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

        guard let renderer = sbRenderer else { return }
        if renderer.status == .failed {
            renderer.flush()
            maybeRequestKeyframe(now: startTime)
        } else if shouldFlushBeforeEnqueue {
            renderer.flush()
        }
        renderer.enqueue(sampleBuffer)

        decodedFramesTotal += 1
        let endTime = CFAbsoluteTimeGetCurrent()
        let decodeMs = max(0, (endTime - startTime) * 1000.0)
        recordFrameTelemetry(
            packet: packet,
            formatDesc: formatDesc,
            decodeMs: decodeMs,
            now: endTime
        )
    }

    private func maybeRequestKeyframe(now: CFAbsoluteTime) {
        if now - lastKeyframeRequestAt >= 1.0 {
            lastKeyframeRequestAt = now
            onRequestKeyframe?()
        }
    }

    private func recordFrameTelemetry(
        packet: EncodedVideoPacket,
        formatDesc: CMVideoFormatDescription,
        decodeMs: Double,
        now: CFAbsoluteTime
    ) {
        if statsWindowStartAt == 0 {
            statsWindowStartAt = now
        }
        statsFramesInWindow += 1
        statsBytesInWindow += packet.data.count
        statsDecodeMsSum += decodeMs

        let elapsed = now - statsWindowStartAt
        let isMilestone = (decodedFramesTotal == 1 || decodedFramesTotal == 5)
        guard elapsed >= 0.45 || isMilestone else { return }

        let safeElapsed = max(elapsed, 0.016)
        let fps: Int
        let bitrateMbps: Double
        if elapsed >= 0.25 {
            fps = Int(round(Double(statsFramesInWindow) / safeElapsed))
            bitrateMbps = (Double(statsBytesInWindow) * 8.0) / (safeElapsed * 1_000_000.0)
            lastPublishedFPS = fps
            lastPublishedBitrateMbps = bitrateMbps
        } else {
            fps = max(lastPublishedFPS, statsFramesInWindow)
            bitrateMbps = lastPublishedBitrateMbps > 0
                ? lastPublishedBitrateMbps
                : (Double(statsBytesInWindow) * 8.0) / (safeElapsed * 1_000_000.0)
        }

        let avgDecodeMs = statsFramesInWindow > 0 ? (statsDecodeMsSum / Double(statsFramesInWindow)) : decodeMs
        let dims = CMVideoFormatDescriptionGetDimensions(formatDesc)
        let encW = dims.width > 0 ? Int(dims.width) : Int(packet.width)
        let encH = dims.height > 0 ? Int(dims.height) : Int(packet.height)

        let snapshot = VideoStreamTelemetry(
            codecName: packet.codec == 2 ? "HEVC" : "H.264",
            fps: fps,
            bitrateMbps: bitrateMbps,
            encodedWidth: encW,
            encodedHeight: encH,
            decodedFrames: decodedFramesTotal,
            avgDecodeMs: avgDecodeMs,
            isLastKeyframe: (packet.flags & 0x01) != 0
        )

        if elapsed >= 0.45 {
            statsWindowStartAt = now
            statsFramesInWindow = 0
            statsBytesInWindow = 0
            statsDecodeMsSum = 0
        }

        onTelemetryUpdated?(snapshot)
    }

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

    private func makeHEVCFormatDescription(vps: Data, sps: Data, pps: Data) -> CMVideoFormatDescription? {
        var desc: CMVideoFormatDescription?
        let status: OSStatus = vps.withUnsafeBytes { vpsRaw in
            sps.withUnsafeBytes { spsRaw in
                pps.withUnsafeBytes { ppsRaw in
                    guard let vpsPtr = vpsRaw.bindMemory(to: UInt8.self).baseAddress,
                          let spsPtr = spsRaw.bindMemory(to: UInt8.self).baseAddress,
                          let ppsPtr = ppsRaw.bindMemory(to: UInt8.self).baseAddress else {
                        return -1
                    }
                    let ptrs: [UnsafePointer<UInt8>] = [vpsPtr, spsPtr, ppsPtr]
                    let sizes: [Int] = [vps.count, sps.count, pps.count]
                    return CMVideoFormatDescriptionCreateFromHEVCParameterSets(
                        allocator: kCFAllocatorDefault,
                        parameterSetCount: 3,
                        parameterSetPointers: ptrs,
                        parameterSetSizes: sizes,
                        nalUnitHeaderLength: 4,
                        extensions: nil,
                        formatDescriptionOut: &desc
                    )
                }
            }
        }
        return status == noErr ? desc : nil
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
