import AVFoundation
import AudioToolbox
import Foundation

/// Low-latency hardware/native audio decoder and player for an independent `RemotePeerSession` on macOS.
/// Decodes incoming AAC-LC (`codec = 3`) or PCM16 (`codec = 1`) streams into `AVAudioEngine` + `AVAudioPlayerNode`
/// with automatic jitter bounds and AirPods / output-device hot-swap recovery.
final class AudioStreamPlayer: @unchecked Sendable {
    private static let codecPcmS16Le: UInt8 = 1
    private static let codecAacLc: UInt8 = 3
    private static let maxInFlightBuffers: Int = 10

    private let playQueue = DispatchQueue(label: "ren.onekb.openuu.client.audio", qos: .userInteractive)
    private var engine: AVAudioEngine?
    private var playerNode: AVAudioPlayerNode?
    private var pcmFormat: AVAudioFormat?
    private var aacFormat: AVAudioFormat?
    private var aacDecoder: AVAudioConverter?
    private var activeSampleRate: UInt32 = 0
    private var activeChannels: UInt8 = 0
    private var inFlightBuffers: Int = 0
    private var isMuted: Bool = false
    private var isStopped: Bool = true
    private var configChangeObserver: NSObjectProtocol?

    init() {}

    deinit {
        if let obs = configChangeObserver {
            NotificationCenter.default.removeObserver(obs)
        }
        engine?.stop()
    }

    func setMuted(_ muted: Bool) {
        playQueue.async { [weak self] in
            guard let self, self.isMuted != muted else { return }
            self.isMuted = muted
            if muted {
                self.playerNode?.stop()
                self.inFlightBuffers = 0
            } else if !self.isStopped, let engine = self.engine, engine.isRunning {
                self.playerNode?.play()
            }
        }
    }

    func stop() {
        playQueue.async { [weak self] in
            guard let self else { return }
            self.isStopped = true
            self.teardownEngineOnQueue()
            self.aacDecoder = nil
            self.aacFormat = nil
            self.pcmFormat = nil
            self.activeSampleRate = 0
            self.activeChannels = 0
            self.inFlightBuffers = 0
        }
    }

    func enqueue(_ packet: EncodedAudioPacket) {
        // Ignore pure codec-config frames if any (`AUDIO_FLAG_CONFIG == 0x02`)
        guard (packet.flags & 0x02) == 0, !packet.data.isEmpty else { return }
        playQueue.async { [weak self] in
            self?.decodeAndScheduleOnQueue(packet)
        }
    }

    // MARK: - Internal (`playQueue`)

    private func decodeAndScheduleOnQueue(_ packet: EncodedAudioPacket) {
        guard !isMuted else { return }
        isStopped = false

        let sr = packet.sampleRate > 0 ? packet.sampleRate : 48_000
        let ch = max(1, min(2, packet.channels))

        guard ensurePipelineReadyOnQueue(sampleRate: sr, channels: ch) else { return }
        guard let pcmFmt = pcmFormat, let player = playerNode, let eng = engine else { return }

        if !eng.isRunning {
            do {
                try eng.start()
                player.play()
            } catch {
                return
            }
        } else if !player.isPlaying {
            player.play()
        }

        let decodedBuffer: AVAudioPCMBuffer?
        switch packet.codec {
        case Self.codecAacLc:
            decodedBuffer = decodeAacPacketOnQueue(packet.data, pcmFormat: pcmFmt)
        case Self.codecPcmS16Le:
            decodedBuffer = decodePcm16PacketOnQueue(packet.data, channels: Int(ch), pcmFormat: pcmFmt)
        default:
            decodedBuffer = nil
        }

        guard let pcmBuf = decodedBuffer, pcmBuf.frameLength > 0 else { return }

        // Jitter ceiling: never allow > ~210ms of buffered audio to accumulate behind live video
        if inFlightBuffers >= Self.maxInFlightBuffers {
            player.stop()
            player.play()
            inFlightBuffers = 0
        }

        inFlightBuffers += 1
        player.scheduleBuffer(pcmBuf, completionCallbackType: .dataConsumed) { [weak self] _ in
            guard let self else { return }
            self.playQueue.async { [weak self] in
                guard let self else { return }
                self.inFlightBuffers = max(0, self.inFlightBuffers - 1)
            }
        }
    }

    private func ensurePipelineReadyOnQueue(sampleRate: UInt32, channels: UInt8) -> Bool {
        if engine != nil,
           pcmFormat != nil,
           activeSampleRate == sampleRate,
           activeChannels == channels {
            return true
        }

        teardownEngineOnQueue()

        guard let pcmFmt = AVAudioFormat(
            standardFormatWithSampleRate: Double(sampleRate),
            channels: AVAudioChannelCount(channels)
        ) else {
            return false
        }

        var aacDesc = AudioStreamBasicDescription(
            mSampleRate: Double(sampleRate),
            mFormatID: kAudioFormatMPEG4AAC,
            mFormatFlags: UInt32(MPEG4ObjectID.AAC_LC.rawValue),
            mBytesPerPacket: 0,
            mFramesPerPacket: 1024,
            mBytesPerFrame: 0,
            mChannelsPerFrame: UInt32(channels),
            mBitsPerChannel: 0,
            mReserved: 0
        )
        let aacFmt = AVAudioFormat(streamDescription: &aacDesc)
        let decoder = aacFmt.flatMap { AVAudioConverter(from: $0, to: pcmFmt) }

        let eng = AVAudioEngine()
        let node = AVAudioPlayerNode()
        eng.attach(node)
        eng.connect(node, to: eng.mainMixerNode, format: pcmFmt)

        do {
            try eng.start()
            node.play()
        } catch {
            OpenUULogger.shared.warn("AUDIO", "AVAudioEngine start failed error=\(error.localizedDescription)")
            return false
        }

        let obs = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: eng,
            queue: nil
        ) { [weak self] _ in
            self?.playQueue.async { [weak self] in
                guard let self, !self.isStopped, !self.isMuted, let e = self.engine, let n = self.playerNode else { return }
                self.inFlightBuffers = 0
                try? e.start()
                n.play()
            }
        }

        self.pcmFormat = pcmFmt
        self.aacFormat = aacFmt
        self.aacDecoder = decoder
        self.engine = eng
        self.playerNode = node
        self.configChangeObserver = obs
        self.activeSampleRate = sampleRate
        self.activeChannels = channels
        self.inFlightBuffers = 0
        return true
    }

    private func teardownEngineOnQueue() {
        if let obs = configChangeObserver {
            NotificationCenter.default.removeObserver(obs)
            configChangeObserver = nil
        }
        playerNode?.stop()
        engine?.stop()
        playerNode = nil
        engine = nil
    }

    private func decodeAacPacketOnQueue(_ data: Data, pcmFormat: AVAudioFormat) -> AVAudioPCMBuffer? {
        guard let decoder = aacDecoder, let aacFmt = aacFormat else { return nil }
        let compBuf = AVAudioCompressedBuffer(
            format: aacFmt,
            packetCapacity: 1,
            maximumPacketSize: max(data.count, 2048)
        )
        data.copyBytes(to: compBuf.data.assumingMemoryBound(to: UInt8.self), count: data.count)
        compBuf.byteLength = UInt32(data.count)
        compBuf.packetCount = 1
        compBuf.packetDescriptions?[0] = AudioStreamPacketDescription(
            mStartOffset: 0,
            mVariableFramesInPacket: 0,
            mDataByteSize: UInt32(data.count)
        )

        guard let outBuf = AVAudioPCMBuffer(pcmFormat: pcmFormat, frameCapacity: 1024) else {
            return nil
        }
        var fed = false
        var convErr: NSError?
        let status = decoder.convert(to: outBuf, error: &convErr) { _, outStatus in
            if fed {
                outStatus.pointee = .noDataNow
                return nil
            }
            fed = true
            outStatus.pointee = .haveData
            return compBuf
        }
        guard convErr == nil, status == .haveData || outBuf.frameLength > 0 else {
            return nil
        }
        return outBuf
    }

    private func decodePcm16PacketOnQueue(_ data: Data, channels: Int, pcmFormat: AVAudioFormat) -> AVAudioPCMBuffer? {
        let totalSamples = data.count / MemoryLayout<Int16>.size
        let frames = totalSamples / max(1, channels)
        guard frames > 0,
              let outBuf = AVAudioPCMBuffer(pcmFormat: pcmFormat, frameCapacity: AVAudioFrameCount(frames)),
              let chData = outBuf.floatChannelData else {
            return nil
        }
        outBuf.frameLength = AVAudioFrameCount(frames)
        let scale: Float = 1.0 / 32768.0
        data.withUnsafeBytes { raw in
            guard let src = raw.bindMemory(to: Int16.self).baseAddress else { return }
            if channels == 1 {
                let dst0 = chData[0]
                for i in 0..<frames {
                    dst0[i] = Float(Int16(littleEndian: src[i])) * scale
                }
            } else {
                let dst0 = chData[0]
                let dst1 = chData[1]
                for i in 0..<frames {
                    dst0[i] = Float(Int16(littleEndian: src[i * channels])) * scale
                    dst1[i] = Float(Int16(littleEndian: src[i * channels + 1])) * scale
                }
            }
        }
        return outBuf
    }
}
