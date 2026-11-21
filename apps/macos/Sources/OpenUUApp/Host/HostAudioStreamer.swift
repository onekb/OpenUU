import AppKit
import AVFoundation
import AudioToolbox
import CoreAudio
import CoreMedia
import Darwin
import Foundation
@preconcurrency import ScreenCaptureKit

/// Captures remote audio for the active OpenUU Host session (either per-app audio in Single-Window mode
/// or system-wide audio in Full Desktop mode), optionally mutes Host speakers cleanly via CoreAudio Process Tap
/// (`CATapMutedWhenTapped` on macOS 14.2+, auto-restored by macOS HAL on stop/exit), and encodes 48kHz stereo AAC-LC.
final class HostAudioStreamer: NSObject, SCStreamOutput, @unchecked Sendable {
    static let codecAacLc: UInt8 = 3
    private static let targetSampleRate: Double = 48_000
    private static let targetChannels: AVAudioChannelCount = 2
    private static let aacFrameSamples: Int = 1024

    private let audioQueue = DispatchQueue(label: "ren.onekb.openuu.host.audio", qos: .userInteractive)

    var onEncodedAudio: ((_ codec: UInt8, _ flags: UInt8, _ channels: UInt8, _ sampleRate: UInt32, _ ptsUS: UInt64, _ data: Data) -> Void)?

    // Desired state (guarded by `audioQueue`)
    private var isEnabled: Bool = true
    private var muteHostSpeakers: Bool = true
    private var networkTier: StreamNetworkTier = .lan
    private var wantFullDesktop: Bool = false
    private var wantBundleIDs: Set<String> = []
    private var generation: UInt64 = 0

    // Active capture state (guarded by `audioQueue`)
    private var activeTapID: AudioObjectID = AudioObjectID(kAudioObjectUnknown)
    private var activeAggregateID: AudioObjectID = AudioObjectID(kAudioObjectUnknown)
    private var activeIOProcID: AudioDeviceIOProcID?
    private var activeTappedProcessObjects: Set<AudioObjectID> = []
    private var processListListenerBlock: AudioObjectPropertyListenerBlock?
    private var scAudioStream: SCStream?
    private var didMuteFallbackOutputDevice: Bool = false
    private var fallbackMutedDeviceID: AudioObjectID = AudioObjectID(kAudioObjectUnknown)

    // AAC-LC encoder & PCM accumulator state (guarded by `audioQueue`)
    private var pcmFormat: AVAudioFormat?
    private var aacFormat: AVAudioFormat?
    private var aacEncoder: AVAudioConverter?
    private var activeBitrate: Int = 0
    private var pendingLeft: [Float] = []
    private var pendingRight: [Float] = []
    private var resamplePhase: Double = 0
    private var lastLeftSample: Float = 0
    private var lastRightSample: Float = 0
    private var hasLastSample: Bool = false
    private var silentFrameStreak: Int = 0
    private var encodedFrameCounter: UInt64 = 0
    private var streamStartHostTimeUS: UInt64 = 0

    override init() {
        super.init()
        pendingLeft.reserveCapacity(4096)
        pendingRight.reserveCapacity(4096)
    }

    deinit {
        stopSynchronously()
    }

    func updatePreferences(enabled: Bool, muteHost: Bool) {
        audioQueue.async { [weak self] in
            guard let self else { return }
            let changed = (self.isEnabled != enabled) || (self.muteHostSpeakers != muteHost)
            self.isEnabled = enabled
            self.muteHostSpeakers = muteHost
            if changed {
                self.reconcileCaptureOnQueue()
            }
        }
    }

    func setNetworkTier(_ tier: StreamNetworkTier) {
        audioQueue.async { [weak self] in
            guard let self, self.networkTier != tier else { return }
            self.networkTier = tier
            self.updateEncoderBitrateOnQueue()
        }
    }

    func updateScope(isFullDesktop: Bool, sharedBundleIDs: Set<String>) {
        audioQueue.async { [weak self] in
            guard let self else { return }
            if self.wantFullDesktop == isFullDesktop && self.wantBundleIDs == sharedBundleIDs {
                // Even if bundle IDs didn't change, refresh process tap membership in case new helper PIDs spawned
                if #available(macOS 14.2, *),
                   self.isEnabled,
                   self.muteHostSpeakers,
                   !self.wantFullDesktop,
                   !self.wantBundleIDs.isEmpty {
                    self.refreshSingleAppTapOnQueue()
                }
                return
            }
            self.wantFullDesktop = isFullDesktop
            self.wantBundleIDs = sharedBundleIDs
            self.reconcileCaptureOnQueue()
        }
    }

    func stop() {
        audioQueue.async { [weak self] in
            guard let self else { return }
            self.wantFullDesktop = false
            self.wantBundleIDs.removeAll()
            self.stopCaptureEnginesOnQueue()
        }
    }

    func stopSynchronously() {
        audioQueue.sync {
            wantFullDesktop = false
            wantBundleIDs.removeAll()
            stopCaptureEnginesOnQueue()
        }
    }

    // MARK: - Capture Engine Orchestration (`audioQueue`)

    private func reconcileCaptureOnQueue() {
        generation &+= 1
        let gen = generation
        stopCaptureEnginesOnQueue()

        guard isEnabled, (wantFullDesktop || !wantBundleIDs.isEmpty) else {
            return
        }

        ensureEncoderReadyOnQueue()

        if muteHostSpeakers {
            if #available(macOS 14.2, *) {
                if wantFullDesktop {
                    if startGlobalMutedTapOnQueue() {
                        OpenUULogger.shared.info("AUDIO", "started global CoreAudio tap (host speakers muted while streaming)")
                        return
                    }
                } else {
                    installProcessListListenerOnQueue()
                    if startOrWaitSingleAppMutedTapOnQueue() {
                        return
                    }
                }
            } else {
                applyFallbackDeviceMuteIfNeededOnQueue()
            }
        }

        // Unmuted capture OR automatic fallback when CoreAudio Process Tap is unavailable
        let fullDesktop = wantFullDesktop
        let bundles = wantBundleIDs
        Task { [weak self] in
            await self?.startScreenCaptureAudioAsync(expectedGen: gen, isFullDesktop: fullDesktop, bundles: bundles)
        }
    }

    private func stopCaptureEnginesOnQueue() {
        removeProcessListListenerOnQueue()
        teardownActiveTapAndAggregateOnQueue()
        restoreFallbackDeviceMuteOnQueue()

        if let sc = scAudioStream {
            scAudioStream = nil
            Task {
                try? await sc.stopCapture()
            }
        }

        pendingLeft.removeAll(keepingCapacity: true)
        pendingRight.removeAll(keepingCapacity: true)
        resamplePhase = 0
        hasLastSample = false
        silentFrameStreak = 0
    }

    // MARK: - macOS 14.2+ CoreAudio Process Tap (`CATapMutedWhenTapped`)

    @available(macOS 14.2, *)
    private func startGlobalMutedTapOnQueue() -> Bool {
        let myObj = Self.translatePIDToAudioObject(ProcessInfo.processInfo.processIdentifier)
        let excluded = myObj != AudioObjectID(kAudioObjectUnknown) ? [myObj] : []
        let desc = CATapDescription(stereoGlobalTapButExcludeProcesses: excluded)
        desc.name = "OpenUU Remote Desktop Audio Tap"
        desc.uuid = UUID()
        desc.isPrivate = true
        desc.muteBehavior = .mutedWhenTapped
        return activateTapAndAggregateOnQueue(tapDesc: desc, trackedObjects: [])
    }

    @available(macOS 14.2, *)
    private func startOrWaitSingleAppMutedTapOnQueue() -> Bool {
        let matched = Self.resolveMatchingAudioProcessObjects(for: wantBundleIDs)
        if matched.isEmpty {
            // None of the shared apps have connected to CoreAudio HAL yet (silent so far).
            // Our `kAudioHardwarePropertyProcessObjectList` listener will activate the tap the instant they play sound!
            OpenUULogger.shared.debug("AUDIO", "armed CoreAudio process-tap listener for bundles=\(wantBundleIDs)")
            return true
        }
        let desc = CATapDescription(stereoMixdownOfProcesses: Array(matched))
        desc.name = "OpenUU App Audio Tap"
        desc.uuid = UUID()
        desc.isPrivate = true
        desc.muteBehavior = .mutedWhenTapped
        let ok = activateTapAndAggregateOnQueue(tapDesc: desc, trackedObjects: matched)
        if ok {
            OpenUULogger.shared.info("AUDIO", "started per-app CoreAudio tap processes=\(matched.count) (app muted on host)")
        }
        return ok
    }

    @available(macOS 14.2, *)
    private func refreshSingleAppTapOnQueue() {
        guard isEnabled, muteHostSpeakers, !wantFullDesktop, !wantBundleIDs.isEmpty else { return }
        let matched = Self.resolveMatchingAudioProcessObjects(for: wantBundleIDs)
        guard matched != activeTappedProcessObjects else { return }

        teardownActiveTapAndAggregateOnQueue()
        guard !matched.isEmpty else { return }

        let desc = CATapDescription(stereoMixdownOfProcesses: Array(matched))
        desc.name = "OpenUU App Audio Tap"
        desc.uuid = UUID()
        desc.isPrivate = true
        desc.muteBehavior = .mutedWhenTapped
        if activateTapAndAggregateOnQueue(tapDesc: desc, trackedObjects: matched) {
            OpenUULogger.shared.info("AUDIO", "updated per-app CoreAudio tap processes=\(matched.count)")
        }
    }

    @available(macOS 14.2, *)
    private func activateTapAndAggregateOnQueue(tapDesc: CATapDescription, trackedObjects: Set<AudioObjectID>) -> Bool {
        var tapID = AudioObjectID(kAudioObjectUnknown)
        let tapErr = AudioHardwareCreateProcessTap(tapDesc, &tapID)
        guard tapErr == noErr, tapID != AudioObjectID(kAudioObjectUnknown) else {
            OpenUULogger.shared.warn("AUDIO", "AudioHardwareCreateProcessTap failed status=\(tapErr), falling back to SCStream")
            return false
        }

        let tapUID = Self.readTapUID(tapID) ?? tapDesc.uuid.uuidString
        let aggUID = "ren.onekb.openuu.aggtap.\(UUID().uuidString)"
        let aggComposition: [String: Any] = [
            kAudioAggregateDeviceNameKey as String: "OpenUU Audio Tap Device",
            kAudioAggregateDeviceUIDKey as String: aggUID,
            kAudioAggregateDeviceIsPrivateKey as String: 1,
            kAudioAggregateDeviceTapAutoStartKey as String: 1,
            kAudioAggregateDeviceTapListKey as String: [
                [
                    kAudioSubTapUIDKey as String: tapUID,
                    kAudioSubTapDriftCompensationKey as String: 1,
                ]
            ],
        ]

        var aggID = AudioObjectID(kAudioObjectUnknown)
        let aggErr = AudioHardwareCreateAggregateDevice(aggComposition as CFDictionary, &aggID)
        guard aggErr == noErr, aggID != AudioObjectID(kAudioObjectUnknown) else {
            _ = AudioHardwareDestroyProcessTap(tapID)
            OpenUULogger.shared.warn("AUDIO", "AudioHardwareCreateAggregateDevice failed status=\(aggErr), falling back to SCStream")
            return false
        }

        let streamASBD = Self.readInputStreamFormat(deviceID: aggID)
            ?? Self.readTapStreamFormat(tapID: tapID)
            ?? AudioStreamBasicDescription(
                mSampleRate: Self.targetSampleRate,
                mFormatID: kAudioFormatLinearPCM,
                mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
                mBytesPerPacket: 8,
                mFramesPerPacket: 1,
                mBytesPerFrame: 8,
                mChannelsPerFrame: 2,
                mBitsPerChannel: 32,
                mReserved: 0
            )

        var ioProcID: AudioDeviceIOProcID?
        let ioErr = AudioDeviceCreateIOProcIDWithBlock(&ioProcID, aggID, nil) { [weak self] _, inInputData, _, _, _ in
            guard let self else { return }
            guard let chunk = Self.extractStereoFloatChunk(from: inInputData, asbd: streamASBD) else { return }
            self.audioQueue.async { [weak self] in
                self?.consumeStereoChunkOnQueue(
                    left: chunk.left,
                    right: chunk.right,
                    sourceSampleRate: streamASBD.mSampleRate
                )
            }
        }

        guard ioErr == noErr, let validIOProc = ioProcID else {
            _ = AudioHardwareDestroyAggregateDevice(aggID)
            _ = AudioHardwareDestroyProcessTap(tapID)
            OpenUULogger.shared.warn("AUDIO", "AudioDeviceCreateIOProcIDWithBlock failed status=\(ioErr)")
            return false
        }

        let startErr = AudioDeviceStart(aggID, validIOProc)
        guard startErr == noErr else {
            _ = AudioDeviceDestroyIOProcID(aggID, validIOProc)
            _ = AudioHardwareDestroyAggregateDevice(aggID)
            _ = AudioHardwareDestroyProcessTap(tapID)
            OpenUULogger.shared.warn("AUDIO", "AudioDeviceStart failed status=\(startErr)")
            return false
        }

        self.activeTapID = tapID
        self.activeAggregateID = aggID
        self.activeIOProcID = validIOProc
        self.activeTappedProcessObjects = trackedObjects
        return true
    }

    private func teardownActiveTapAndAggregateOnQueue() {
        if activeAggregateID != AudioObjectID(kAudioObjectUnknown) {
            if let proc = activeIOProcID {
                _ = AudioDeviceStop(activeAggregateID, proc)
                _ = AudioDeviceDestroyIOProcID(activeAggregateID, proc)
                activeIOProcID = nil
            }
            _ = AudioHardwareDestroyAggregateDevice(activeAggregateID)
            activeAggregateID = AudioObjectID(kAudioObjectUnknown)
        }
        if activeTapID != AudioObjectID(kAudioObjectUnknown) {
            if #available(macOS 14.2, *) {
                _ = AudioHardwareDestroyProcessTap(activeTapID)
            }
            activeTapID = AudioObjectID(kAudioObjectUnknown)
        }
        activeTappedProcessObjects.removeAll()
    }

    @available(macOS 14.2, *)
    private func installProcessListListenerOnQueue() {
        guard processListListenerBlock == nil else { return }
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.refreshSingleAppTapOnQueue()
        }
        if AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &addr, audioQueue, block) == noErr {
            processListListenerBlock = block
        }
    }

    private func removeProcessListListenerOnQueue() {
        guard let block = processListListenerBlock else { return }
        processListListenerBlock = nil
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        _ = AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &addr, audioQueue, block)
    }

    // MARK: - macOS 14.0-14.1 Device Mute Fallback

    private func applyFallbackDeviceMuteIfNeededOnQueue() {
        guard !didMuteFallbackOutputDevice else { return }
        guard let devID = Self.defaultOutputDeviceID(), devID != AudioObjectID(kAudioObjectUnknown) else { return }
        if let wasMuted = Self.getDeviceMute(devID), !wasMuted {
            if Self.setDeviceMute(devID, muted: true) {
                didMuteFallbackOutputDevice = true
                fallbackMutedDeviceID = devID
            }
        }
    }

    private func restoreFallbackDeviceMuteOnQueue() {
        guard didMuteFallbackOutputDevice, fallbackMutedDeviceID != AudioObjectID(kAudioObjectUnknown) else { return }
        _ = Self.setDeviceMute(fallbackMutedDeviceID, muted: false)
        didMuteFallbackOutputDevice = false
        fallbackMutedDeviceID = AudioObjectID(kAudioObjectUnknown)
    }

    // MARK: - ScreenCaptureKit Audio Engine (Unmuted Mode & Fallback)

    private func startScreenCaptureAudioAsync(expectedGen: UInt64, isFullDesktop: Bool, bundles: Set<String>) async {
        guard let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false) else {
            return
        }
        let mainID = CGMainDisplayID()
        guard let display = content.displays.first(where: { $0.displayID == mainID }) ?? content.displays.first else {
            return
        }

        let filter: SCContentFilter
        if isFullDesktop {
            filter = SCContentFilter(display: display, excludingWindows: [])
        } else {
            let matchingPIDs = Self.resolveAllMatchingPIDs(for: bundles)
            let myPID = ProcessInfo.processInfo.processIdentifier
            let targetApps = content.applications.filter { app in
                guard app.processID != myPID else { return false }
                if matchingPIDs.contains(app.processID) { return true }
                return Self.bundleMatches(app.bundleIdentifier, sharedBundles: bundles)
            }
            guard !targetApps.isEmpty else { return }
            filter = SCContentFilter(display: display, including: targetApps, exceptingWindows: [])
        }

        let cfg = SCStreamConfiguration()
        cfg.width = 2
        cfg.height = 2
        cfg.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        cfg.capturesAudio = true
        cfg.sampleRate = Int(Self.targetSampleRate)
        cfg.channelCount = Int(Self.targetChannels)
        cfg.excludesCurrentProcessAudio = true
        if #available(macOS 14.0, *) {
            cfg.presenterOverlayPrivacyAlertSetting = .never
        }

        let stream = SCStream(filter: filter, configuration: cfg, delegate: nil)
        do {
            try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: audioQueue)
            try await stream.startCapture()
            let accepted: Bool = audioQueue.sync {
                guard self.generation == expectedGen, self.isEnabled else { return false }
                self.scAudioStream = stream
                return true
            }
            if accepted {
                OpenUULogger.shared.info("AUDIO", "started SCStream audio capture fullDesktop=\(isFullDesktop) hostMuted=\(muteHostSpeakers)")
            } else {
                try? await stream.stopCapture()
            }
        } catch {
            OpenUULogger.shared.warn("AUDIO", "SCStream audio start failed error=\(error.localizedDescription)")
        }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, CMSampleBufferDataIsReady(sampleBuffer) else { return }
        guard let fmtDesc = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbdPtr = CMAudioFormatDescriptionGetStreamBasicDescription(fmtDesc) else {
            return
        }
        let asbd = asbdPtr.pointee

        var blockBuffer: CMBlockBuffer?
        let ablByteSize = MemoryLayout<AudioBufferList>.size + MemoryLayout<AudioBuffer>.size * 4
        let rawPtr = UnsafeMutableRawPointer.allocate(byteCount: ablByteSize, alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { rawPtr.deallocate() }
        let ablPtr = rawPtr.bindMemory(to: AudioBufferList.self, capacity: 1)

        let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: nil,
            bufferListOut: ablPtr,
            bufferListSize: ablByteSize,
            blockBufferAllocator: kCFAllocatorDefault,
            blockBufferMemoryAllocator: kCFAllocatorDefault,
            flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment,
            blockBufferOut: &blockBuffer
        )
        guard status == noErr else { return }
        guard let chunk = Self.extractStereoFloatChunk(from: UnsafePointer(ablPtr), asbd: asbd) else { return }
        consumeStereoChunkOnQueue(left: chunk.left, right: chunk.right, sourceSampleRate: asbd.mSampleRate)
    }

    // MARK: - PCM Normalization, Resampling, Silence Gate & AAC-LC Hardware/Native Encoding (`audioQueue`)

    private func ensureEncoderReadyOnQueue() {
        if aacEncoder != nil {
            updateEncoderBitrateOnQueue()
            return
        }
        guard let pcmFmt = AVAudioFormat(standardFormatWithSampleRate: Self.targetSampleRate, channels: Self.targetChannels) else {
            return
        }
        var aacDesc = AudioStreamBasicDescription(
            mSampleRate: Self.targetSampleRate,
            mFormatID: kAudioFormatMPEG4AAC,
            mFormatFlags: UInt32(MPEG4ObjectID.AAC_LC.rawValue),
            mBytesPerPacket: 0,
            mFramesPerPacket: UInt32(Self.aacFrameSamples),
            mBytesPerFrame: 0,
            mChannelsPerFrame: Self.targetChannels,
            mBitsPerChannel: 0,
            mReserved: 0
        )
        guard let aacFmt = AVAudioFormat(streamDescription: &aacDesc),
              let conv = AVAudioConverter(from: pcmFmt, to: aacFmt) else {
            OpenUULogger.shared.error("AUDIO", "failed to initialize 48kHz stereo AAC-LC encoder")
            return
        }
        self.pcmFormat = pcmFmt
        self.aacFormat = aacFmt
        self.aacEncoder = conv
        self.encodedFrameCounter = 0
        self.streamStartHostTimeUS = UInt64(DispatchTime.now().uptimeNanoseconds / 1_000)
        updateEncoderBitrateOnQueue()
    }

    private func updateEncoderBitrateOnQueue() {
        guard let conv = aacEncoder else { return }
        let desiredBitrate: Int = switch networkTier {
        case .lan: 128_000
        case .wanDirect: 96_000
        case .wanRelay: 64_000
        }
        guard desiredBitrate != activeBitrate else { return }
        conv.bitRate = desiredBitrate
        activeBitrate = desiredBitrate
    }

    private func consumeStereoChunkOnQueue(left: [Float], right: [Float], sourceSampleRate: Double) {
        guard !left.isEmpty, left.count == right.count else { return }
        ensureEncoderReadyOnQueue()
        guard let encoder = aacEncoder, let pcmFmt = pcmFormat, let aacFmt = aacFormat else { return }

        if abs(sourceSampleRate - Self.targetSampleRate) <= 1.0 || sourceSampleRate <= 1_000 {
            pendingLeft.append(contentsOf: left)
            pendingRight.append(contentsOf: right)
        } else {
            // Smooth linear resampling to canonical 48,000 Hz stereo
            let step = sourceSampleRate / Self.targetSampleRate
            let count = left.count
            if !hasLastSample {
                lastLeftSample = left[0]
                lastRightSample = right[0]
                hasLastSample = true
            }
            var pos = resamplePhase
            while pos < Double(count) {
                let idx = Int(floor(pos))
                let frac = Float(pos - floor(pos))
                let l0: Float = idx == 0 ? lastLeftSample : left[min(count - 1, idx - 1)]
                let r0: Float = idx == 0 ? lastRightSample : right[min(count - 1, idx - 1)]
                let l1: Float = left[min(count - 1, idx)]
                let r1: Float = right[min(count - 1, idx)]
                pendingLeft.append(l0 + (l1 - l0) * frac)
                pendingRight.append(r0 + (r1 - r0) * frac)
                pos += step
            }
            resamplePhase = pos - Double(count)
            lastLeftSample = left[count - 1]
            lastRightSample = right[count - 1]
        }

        // Prevent unbounded accumulation on encoder stall
        if pendingLeft.count > Self.aacFrameSamples * 16 {
            let dropCount = pendingLeft.count - Self.aacFrameSamples * 4
            pendingLeft.removeFirst(dropCount)
            pendingRight.removeFirst(dropCount)
        }

        while pendingLeft.count >= Self.aacFrameSamples {
            var peak: Float = 0
            for i in 0..<Self.aacFrameSamples {
                let p = max(abs(pendingLeft[i]), abs(pendingRight[i]))
                if p > peak { peak = p }
            }

            if peak < 1.5e-5 {
                silentFrameStreak += 1
                if silentFrameStreak > 8 {
                    // Pure digital silence gate: save 100% network bandwidth while remote Mac is quiet
                    pendingLeft.removeFirst(Self.aacFrameSamples)
                    pendingRight.removeFirst(Self.aacFrameSamples)
                    encodedFrameCounter &+= 1
                    continue
                }
            } else {
                silentFrameStreak = 0
            }

            guard let inBuf = AVAudioPCMBuffer(pcmFormat: pcmFmt, frameCapacity: AVAudioFrameCount(Self.aacFrameSamples)),
                  let chData = inBuf.floatChannelData else {
                pendingLeft.removeFirst(Self.aacFrameSamples)
                pendingRight.removeFirst(Self.aacFrameSamples)
                continue
            }
            inBuf.frameLength = AVAudioFrameCount(Self.aacFrameSamples)
            let dstL = chData[0]
            let dstR = chData[1]
            for i in 0..<Self.aacFrameSamples {
                dstL[i] = max(-1.0, min(1.0, pendingLeft[i]))
                dstR[i] = max(-1.0, min(1.0, pendingRight[i]))
            }
            pendingLeft.removeFirst(Self.aacFrameSamples)
            pendingRight.removeFirst(Self.aacFrameSamples)

            let maxPkt = max(Int(encoder.maximumOutputPacketSize), 2048)
            let outBuf = AVAudioCompressedBuffer(format: aacFmt, packetCapacity: 1, maximumPacketSize: maxPkt)
            var fed = false
            var convErr: NSError?
            let status = encoder.convert(to: outBuf, error: &convErr) { _, outStatus in
                if fed {
                    outStatus.pointee = .noDataNow
                    return nil
                }
                fed = true
                outStatus.pointee = .haveData
                return inBuf
            }

            let ptsUS = streamStartHostTimeUS &+ (encodedFrameCounter * 1_024_000_000 / 48_000)
            encodedFrameCounter &+= 1

            if convErr == nil && (status == .haveData || outBuf.packetCount > 0) {
                let byteLen = Int(outBuf.packetDescriptions?[0].mDataByteSize ?? outBuf.byteLength)
                let offset = Int(outBuf.packetDescriptions?[0].mStartOffset ?? 0)
                if byteLen > 0 {
                    let packetData = Data(bytes: outBuf.data.advanced(by: offset), count: byteLen)
                    onEncodedAudio?(
                        Self.codecAacLc,
                        0,
                        UInt8(Self.targetChannels),
                        UInt32(Self.targetSampleRate),
                        ptsUS,
                        packetData
                    )
                }
            }
        }
    }

    // MARK: - Low-Level CoreAudio & Process Tree Helpers

    private static func extractStereoFloatChunk(
        from ablPtr: UnsafePointer<AudioBufferList>,
        asbd: AudioStreamBasicDescription
    ) -> (left: [Float], right: [Float])? {
        let abl = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: ablPtr))
        guard !abl.isEmpty else { return nil }

        let isFloat = (asbd.mFormatFlags & kAudioFormatFlagIsFloat) != 0
        let isSignedInt = (asbd.mFormatFlags & kAudioFormatFlagIsSignedInteger) != 0
        let isNonInterleaved = (asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0 || abl.count >= 2

        if isFloat {
            if isNonInterleaved {
                let b0 = abl[0]
                guard let p0 = b0.mData?.assumingMemoryBound(to: Float.self) else { return nil }
                let frames = Int(b0.mDataByteSize) / MemoryLayout<Float>.size
                guard frames > 0 else { return nil }
                let left = Array(UnsafeBufferPointer(start: p0, count: frames))
                if abl.count >= 2, let p1 = abl[1].mData?.assumingMemoryBound(to: Float.self) {
                    let f1 = min(frames, Int(abl[1].mDataByteSize) / MemoryLayout<Float>.size)
                    if f1 == frames {
                        return (left, Array(UnsafeBufferPointer(start: p1, count: frames)))
                    }
                }
                return (left, left)
            } else {
                let b0 = abl[0]
                let ch = max(1, Int(b0.mNumberChannels > 0 ? b0.mNumberChannels : asbd.mChannelsPerFrame))
                guard let p0 = b0.mData?.assumingMemoryBound(to: Float.self) else { return nil }
                let totalSamples = Int(b0.mDataByteSize) / MemoryLayout<Float>.size
                let frames = totalSamples / ch
                guard frames > 0 else { return nil }
                var left = [Float](repeating: 0, count: frames)
                var right = [Float](repeating: 0, count: frames)
                if ch == 1 {
                    for i in 0..<frames {
                        let s = p0[i]
                        left[i] = s
                        right[i] = s
                    }
                } else {
                    for i in 0..<frames {
                        left[i] = p0[i * ch]
                        right[i] = p0[i * ch + 1]
                    }
                }
                return (left, right)
            }
        } else if isSignedInt && asbd.mBitsPerChannel == 16 {
            let scale: Float = 1.0 / 32768.0
            if isNonInterleaved {
                let b0 = abl[0]
                guard let p0 = b0.mData?.assumingMemoryBound(to: Int16.self) else { return nil }
                let frames = Int(b0.mDataByteSize) / MemoryLayout<Int16>.size
                guard frames > 0 else { return nil }
                var left = [Float](repeating: 0, count: frames)
                for i in 0..<frames { left[i] = Float(p0[i]) * scale }
                if abl.count >= 2, let p1 = abl[1].mData?.assumingMemoryBound(to: Int16.self) {
                    let f1 = min(frames, Int(abl[1].mDataByteSize) / MemoryLayout<Int16>.size)
                    if f1 == frames {
                        var right = [Float](repeating: 0, count: frames)
                        for i in 0..<frames { right[i] = Float(p1[i]) * scale }
                        return (left, right)
                    }
                }
                return (left, left)
            } else {
                let b0 = abl[0]
                let ch = max(1, Int(b0.mNumberChannels > 0 ? b0.mNumberChannels : asbd.mChannelsPerFrame))
                guard let p0 = b0.mData?.assumingMemoryBound(to: Int16.self) else { return nil }
                let totalSamples = Int(b0.mDataByteSize) / MemoryLayout<Int16>.size
                let frames = totalSamples / ch
                guard frames > 0 else { return nil }
                var left = [Float](repeating: 0, count: frames)
                var right = [Float](repeating: 0, count: frames)
                if ch == 1 {
                    for i in 0..<frames {
                        let s = Float(p0[i]) * scale
                        left[i] = s
                        right[i] = s
                    }
                } else {
                    for i in 0..<frames {
                        left[i] = Float(p0[i * ch]) * scale
                        right[i] = Float(p0[i * ch + 1]) * scale
                    }
                }
                return (left, right)
            }
        }
        return nil
    }

    private static func bundleMatches(_ rawBundleID: String?, sharedBundles: Set<String>) -> Bool {
        guard let bid = rawBundleID, !bid.isEmpty else { return false }
        if sharedBundles.contains(bid) { return true }
        if sharedBundles.contains(WindowCatalog.weChatBundleID) && bid.localizedCaseInsensitiveContains("WeChatAppEx") {
            return true
        }
        return sharedBundles.contains { shared in
            !shared.isEmpty && bid.hasPrefix(shared + ".")
        }
    }

    private static func resolveAllMatchingPIDs(for sharedBundles: Set<String>) -> Set<pid_t> {
        guard !sharedBundles.isEmpty else { return [] }
        let myPID = ProcessInfo.processInfo.processIdentifier
        var rootPIDs: Set<pid_t> = []
        for app in NSWorkspace.shared.runningApplications {
            guard app.processIdentifier != myPID else { continue }
            if bundleMatches(app.bundleIdentifier, sharedBundles: sharedBundles) {
                rootPIDs.insert(app.processIdentifier)
            }
        }
        guard !rootPIDs.isEmpty else { return [] }

        let ppidMap = buildParentPIDMap()
        var matched = rootPIDs
        for candidatePID in ppidMap.keys where candidatePID > 1 && candidatePID != myPID {
            var cur = candidatePID
            for _ in 0..<8 {
                if matched.contains(cur) {
                    matched.insert(candidatePID)
                    break
                }
                guard let parent = ppidMap[cur], parent > 1, parent != cur else { break }
                cur = parent
            }
        }
        return matched
    }

    private static func buildParentPIDMap() -> [pid_t: pid_t] {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        var size: Int = 0
        guard sysctl(&mib, 4, nil, &size, nil, 0) == 0, size > 0 else { return [:] }
        let stride = MemoryLayout<kinfo_proc>.stride
        let capacity = (size / stride) + 32
        var procs = [kinfo_proc](repeating: kinfo_proc(), count: capacity)
        var actualSize = capacity * stride
        guard sysctl(&mib, 4, &procs, &actualSize, nil, 0) == 0 else { return [:] }
        let count = actualSize / stride
        var map: [pid_t: pid_t] = [:]
        map.reserveCapacity(count)
        for i in 0..<count {
            let p = procs[i].kp_proc.p_pid
            let pp = procs[i].kp_eproc.e_ppid
            if p > 0 {
                map[p] = pp
            }
        }
        return map
    }

    private static func resolveMatchingAudioProcessObjects(for sharedBundles: Set<String>) -> Set<AudioObjectID> {
        let matchingPIDs = resolveAllMatchingPIDs(for: sharedBundles)
        let myPID = ProcessInfo.processInfo.processIdentifier
        let allProcObjects = listAllAudioProcessObjects()
        var result: Set<AudioObjectID> = []
        for objID in allProcObjects {
            let pid = readProcessObjectPID(objID) ?? 0
            if pid == myPID { continue }
            if pid > 0 && matchingPIDs.contains(pid) {
                result.insert(objID)
                continue
            }
            if let bid = readProcessObjectBundleID(objID), bundleMatches(bid, sharedBundles: sharedBundles) {
                result.insert(objID)
            }
        }
        return result
    }

    private static func translatePIDToAudioObject(_ pid: pid_t) -> AudioObjectID {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var pidVal = pid
        var objID = AudioObjectID(kAudioObjectUnknown)
        var dataSize = UInt32(MemoryLayout<AudioObjectID>.size)
        let err = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &addr,
            UInt32(MemoryLayout<pid_t>.size),
            &pidVal,
            &dataSize,
            &objID
        )
        return err == noErr ? objID : AudioObjectID(kAudioObjectUnknown)
    }

    private static func listAllAudioProcessObjects() -> [AudioObjectID] {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &dataSize) == noErr,
              dataSize >= UInt32(MemoryLayout<AudioObjectID>.size) else {
            return []
        }
        let count = Int(dataSize) / MemoryLayout<AudioObjectID>.size
        var ids = [AudioObjectID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &dataSize, &ids) == noErr else {
            return []
        }
        return ids
    }

    private static func readProcessObjectPID(_ objID: AudioObjectID) -> pid_t? {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyPID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var pid: pid_t = 0
        var size = UInt32(MemoryLayout<pid_t>.size)
        guard AudioObjectGetPropertyData(objID, &addr, 0, nil, &size, &pid) == noErr else { return nil }
        return pid
    }

    private static func readProcessObjectBundleID(_ objID: AudioObjectID) -> String? {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyBundleID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var cfStr: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let err = withUnsafeMutablePointer(to: &cfStr) { ptr in
            AudioObjectGetPropertyData(objID, &addr, 0, nil, &size, ptr)
        }
        guard err == noErr, let cfStr else { return nil }
        return cfStr.takeRetainedValue() as String
    }

    private static func readTapUID(_ tapID: AudioObjectID) -> String? {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var cfStr: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let err = withUnsafeMutablePointer(to: &cfStr) { ptr in
            AudioObjectGetPropertyData(tapID, &addr, 0, nil, &size, ptr)
        }
        guard err == noErr, let cfStr else { return nil }
        return cfStr.takeRetainedValue() as String
    }

    private static func readTapStreamFormat(tapID: AudioObjectID) -> AudioStreamBasicDescription? {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        guard AudioObjectGetPropertyData(tapID, &addr, 0, nil, &size, &asbd) == noErr else { return nil }
        return asbd
    }

    private static func readInputStreamFormat(deviceID: AudioObjectID) -> AudioStreamBasicDescription? {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamFormat,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        guard AudioObjectGetPropertyData(deviceID, &addr, 0, nil, &size, &asbd) == noErr else { return nil }
        return asbd
    }

    private static func defaultOutputDeviceID() -> AudioObjectID? {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var devID = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &devID) == noErr else {
            return nil
        }
        return devID
    }

    private static func getDeviceMute(_ devID: AudioObjectID) -> Bool? {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectHasProperty(devID, &addr) else { return nil }
        var val: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(devID, &addr, 0, nil, &size, &val) == noErr else { return nil }
        return val != 0
    }

    private static func setDeviceMute(_ devID: AudioObjectID, muted: Bool) -> Bool {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var settable: DarwinBoolean = false
        guard AudioObjectHasProperty(devID, &addr),
              AudioObjectIsPropertySettable(devID, &addr, &settable) == noErr,
              settable.boolValue else {
            return false
        }
        var val: UInt32 = muted ? 1 : 0
        return AudioObjectSetPropertyData(devID, &addr, 0, nil, UInt32(MemoryLayout<UInt32>.size), &val) == noErr
    }
}
