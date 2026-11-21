import AVFoundation
import AudioToolbox
import Foundation

/// Low-latency hardware/native audio decoder and player for iOS / iPadOS remote sessions.
/// Configures `AVAudioSession` with `.playback` + `.mixWithOthers` so remote Mac audio is audible
/// even when the iPhone hardware Ring/Silent switch is muted, and recovers automatically across interruptions.
final class IOSAudioStreamPlayer: @unchecked Sendable {
    private static let codecPcmS16Le: UInt8 = 1
    private static let codecAacLc: UInt8 = 3
    private static let maxInFlightBuffers: Int = 10

    private let playQueue = DispatchQueue(label: "ren.onekb.openuu.ios.audio", qos: .userInteractive)
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
    private var audioSessionActivated: Bool = false
    private var observers: [NSObjectProtocol] = []

    init() {}

    deinit {
        for obs in observers {
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
            } else if !self.isStopped, let eng = self.engine, eng.isRunning {
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
            if self.audioSessionActivated {
                try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
                self.audioSessionActivated = false
            }
        }
    }

    func enqueue(_ packet: EncodedAudioPacket) {
        guard (packet.flags & 0x02) == 0, !packet.data.isEmpty else { return }
        playQueue.async { [weak self] in
            self?.decodeAndScheduleOnQueue(packet)
        }
    }

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

        let decoded: AVAudioPCMBuffer?
        switch packet.codec {
        case Self.codecAacLc:
            decoded = decodeAacPacketOnQueue(packet.data, pcmFormat: pcmFmt)
        case Self.codecPcmS16Le:
            decoded = decodePcm16PacketOnQueue(packet.data, channels: Int(ch), pcmFormat: pcmFmt)
        default:
            decoded = nil
        }

        guard let pcmBuf = decoded, pcmBuf.frameLength > 0 else { return }

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

        let session = AVAudioSession.sharedInstance()
        if !audioSessionActivated {
            try? session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try? session.setPreferredIOBufferDuration(0.01)
            try? session.setActive(true)
            audioSessionActivated = true
        }

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
            return false
        }

        let center = NotificationCenter.default
        let o1 = center.addObserver(forName: .AVAudioEngineConfigurationChange, object: eng, queue: nil) { [weak self] _ in
            self?.playQueue.async { [weak self] in
                guard let self, !self.isStopped, !self.isMuted, let e = self.engine, let n = self.playerNode else { return }
                self.inFlightBuffers = 0
                try? e.start()
                n.play()
            }
        }
        let o2 = center.addObserver(forName: AVAudioSession.interruptionNotification, object: session, queue: nil) { [weak self] note in
            let typeVal = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            let ended = (typeVal == AVAudioSession.InterruptionType.ended.rawValue)
            guard ended else { return }
            self?.playQueue.async { [weak self] in
                guard let self, !self.isStopped, !self.isMuted, let e = self.engine, let n = self.playerNode else { return }
                try? AVAudioSession.sharedInstance().setActive(true)
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
        self.observers = [o1, o2]
        self.activeSampleRate = sampleRate
        self.activeChannels = channels
        self.inFlightBuffers = 0
        return true
    }

    private func teardownEngineOnQueue() {
        for obs in observers {
            NotificationCenter.default.removeObserver(obs)
        }
        observers.removeAll()
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
