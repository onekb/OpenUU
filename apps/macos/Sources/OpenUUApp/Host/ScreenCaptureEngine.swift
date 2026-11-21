import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
@preconcurrency import ScreenCaptureKit
import VideoToolbox

enum StreamNetworkTier: String, Sendable {
    case lan = "lan"
    case wanDirect = "wan_direct"
    case wanRelay = "wan_relay"

    var prefersHEVC: Bool {
        self != .lan
    }

    var label: String {
        switch self {
        case .lan: return "局域网直连"
        case .wanDirect: return "P2P 直连"
        case .wanRelay: return "中继保底"
        }
    }
}

/// Captures a single macOS window via ScreenCaptureKit and hardware-encodes frames via VideoToolbox (H.264 / HEVC Annex-B).
final class ScreenCaptureEngine: NSObject, SCStreamOutput, @unchecked Sendable {
    private var stream: SCStream?
    private var compressionSession: VTCompressionSession?
    private var encoderCache: [String: VTCompressionSession] = [:]
    private var activeEncoderWidth: Int32 = 0
    private var activeEncoderHeight: Int32 = 0
    private let captureQueue = DispatchQueue(label: "ren.onekb.openuu.capture", qos: .userInteractive)
    private var targetWindowID: UInt32 = 0
    /// Always reports the 2x Retina logical-equivalent dimensions in packet headers so the Client window
    /// never resizes or shifts mouse coordinates when internal capture resolution scales down during video motion.
    private var encodedWidth: UInt16 = 0
    private var encodedHeight: UInt16 = 0
    private var forceNextKeyframe = true
    private var currentConfig: SCStreamConfiguration?
    private var currentFPS: Int = 60
    private var lastTrackedSize: CGSize = .zero
    private var isFloatingPopover: Bool = false
    private var isNativeMenuPopover: Bool = false
    private var hasDetectedAlphaTrim: Bool = false
    private var captureScaleFactor: CGFloat = 2.0
    var dynamicResolutionEnabled: Bool = true
    var networkTier: StreamNetworkTier = .lan
    private var pixelCropRect: (x: Int, y: Int, w: Int, h: Int)?
    private var croppedPixelBuffer: CVPixelBuffer?
    private var lastEncodedPixelBuffer: CVPixelBuffer?
    private var lastEncodedPTS: CMTime = .invalid
    private var encodedFrameCount: UInt64 = 0
    private var resizeDropBudget: Int = 0
    private var expectedCaptureWidth: Int = 0
    private var expectedCaptureHeight: Int = 0

    var onEncodedFrame: ((_ codec: UInt8, _ flags: UInt8, _ windowID: UInt32, _ ptsUS: UInt64, _ width: UInt16, _ height: UInt16, _ data: Data) -> Void)?
    var onContentInsetDetected: ((_ windowID: UInt32, _ insetOrigin: CGPoint, _ croppedLogicalSize: CGSize) -> Void)?

    /// Ensures small floating popovers/context menus meet hardware H.264/HEVC encoder & decoder minimum dimensions.
    private static func ensureMinimumEncodeDimensions(width: Int, height: Int, isPopover: Bool) -> (w: Int, h: Int) {
        var w = max(2, width & ~1)
        var h = max(2, height & ~1)
        if isPopover && (w < 128 || h < 128) {
            let scale = max(128.0 / CGFloat(w), 128.0 / CGFloat(h))
            w = max(128, Int(ceil(CGFloat(w) * scale)) & ~1)
            h = max(128, Int(ceil(CGFloat(h) * scale)) & ~1)
        }
        return (w, h)
    }

    /// Computes steady, non-oscillating pixel dimensions for capture & H.264/HEVC encoding.
    private func effectiveEncodeDimensions(for logicalSize: CGSize) -> (w: Int, h: Int) {
        let baseScale = max(1.0, captureScaleFactor)
        let effScale: CGFloat
        if !isFloatingPopover && (dynamicResolutionEnabled || networkTier == .wanRelay) {
            let maxEdge = max(1.0, max(logicalSize.width, logicalSize.height))
            let targetMaxPx: CGFloat = switch networkTier {
            case .lan: 1600.0
            case .wanDirect: 1500.0
            case .wanRelay: 1360.0
            }
            let minScale: CGFloat = networkTier == .wanRelay ? 1.05 : 1.15
            effScale = min(baseScale, min(1.35, max(minScale, targetMaxPx / maxEdge)))
        } else {
            effScale = baseScale
        }
        let rawW = max(2, Int(logicalSize.width * effScale) & ~1)
        let rawH = max(2, Int(logicalSize.height * effScale) & ~1)
        return Self.ensureMinimumEncodeDimensions(width: rawW, height: rawH, isPopover: isFloatingPopover)
    }

    private func effectiveTargetFPS(baseFPS: Int) -> Int {
        switch networkTier {
        case .lan: return max(24, min(60, baseFPS))
        case .wanDirect: return max(24, min(45, baseFPS))
        case .wanRelay: return min(30, max(24, baseFPS))
        }
    }

    func startCapture(window: SCWindow, fps: Int = 60, scaleFactor: CGFloat = 2.0) async throws {
        await stopCapture()
        // Build filter first so we can read the window's true backing `pointPixelScale` (1.0 on 1x Mac mini
        // external monitors, 2.0 on Retina displays) instead of assuming 2.0 and mismatching buffer dimensions!
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let filterScale = CGFloat(max(1.0, filter.pointPixelScale))

        self.targetWindowID = window.windowID
        self.currentFPS = fps
        self.isFloatingPopover = window.windowLayer > 0
        // Native macOS context/popup menus (`NSMenu`, `kCGPopUpMenuWindowLevel` == 101) use `NSVisualEffectView`
        // (`CABackdropLayer`) without custom outer transparent shadow margins. Capturing them with
        // `shouldBeOpaque = true` ensures ScreenCaptureKit renders an opaque system menu material in both
        // Light Mode and Dark Mode instead of leaving the backdrop transparent black!
        self.isNativeMenuPopover = window.windowLayer >= 100
        self.hasDetectedAlphaTrim = isNativeMenuPopover
        self.pixelCropRect = nil
        self.croppedPixelBuffer = nil
        self.lastEncodedPixelBuffer = nil
        self.lastEncodedPTS = .invalid
        self.encodedFrameCount = 0
        self.resizeDropBudget = 0
        self.captureScaleFactor = min(scaleFactor, max(1.0, filterScale))
        self.lastTrackedSize = window.frame.size

        // Wire headers always carry 2x Retina-equivalent logical dimensions so Clients compute `logical = header / 2`.
        let reportedW = max(2, Int(window.frame.width * 2.0) & ~1)
        let reportedH = max(2, Int(window.frame.height * 2.0) & ~1)
        self.encodedWidth = UInt16(reportedW)
        self.encodedHeight = UInt16(reportedH)
        self.forceNextKeyframe = true

        let (encW, encH) = effectiveEncodeDimensions(for: window.frame.size)
        self.expectedCaptureWidth = encW
        self.expectedCaptureHeight = encH
        try activateEncoder(width: Int32(encW), height: Int32(encH), fps: fps)

        let useBGRA = isFloatingPopover && !isNativeMenuPopover
        let config = SCStreamConfiguration()
        config.width = encW
        config.height = encH
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(fps))
        // For custom floating popovers (`0 < windowLayer < 100`, e.g. WeChat emoji picker), use BGRA so we can
        // auto-trim transparent custom shadow margins! For native menus (`>= 100`) and normal windows, use `420f`.
        config.pixelFormat = useBGRA
            ? kCVPixelFormatType_32BGRA
            : kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        Self.applyCanonicalSRGBStreamConfig(config, isBGRA: useBGRA)
        config.showsCursor = false
        config.queueDepth = 6
        config.scalesToFit = true
        if #available(macOS 14.0, *) {
            config.captureResolution = isFloatingPopover ? .best : .automatic
            config.ignoreShadowsDisplay = true
            config.ignoreShadowsSingleWindow = true
            config.ignoreGlobalClipDisplay = true
            config.ignoreGlobalClipSingleWindow = true
            // Keep opaque backing for normal windows and native `NSMenu` context menus; keep transparent
            // only for custom app popovers (`0 < windowLayer < 100`) until shadow-trim check completes.
            config.shouldBeOpaque = !useBGRA
            config.presenterOverlayPrivacyAlertSetting = .never
        }
        if #available(macOS 14.2, *) {
            // Each child window / Mini Program / floating popover is captured as its own independent stream by
            // `MultiWindowCaptureManager`, so never composite child windows into the parent window's backing frame.
            config.includeChildWindows = false
        }

        self.currentConfig = config

        let scStream = SCStream(filter: filter, configuration: config, delegate: nil)
        try scStream.addStreamOutput(self, type: .screen, sampleHandlerQueue: captureQueue)
        try await scStream.startCapture()
        self.stream = scStream
    }

    /// Captures an entire macOS display (Full Remote Desktop mode) using `SCContentFilter(display:excludingWindows:)`.
    func startDesktopCapture(display: SCDisplay, windowID: UInt32, fps: Int = 45, scaleFactor: CGFloat = 2.0) async throws {
        await stopCapture()
        self.targetWindowID = windowID
        self.currentFPS = fps
        self.isFloatingPopover = false
        self.isNativeMenuPopover = false
        self.hasDetectedAlphaTrim = false
        self.pixelCropRect = nil
        self.croppedPixelBuffer = nil
        self.lastEncodedPixelBuffer = nil
        self.lastEncodedPTS = .invalid
        self.encodedFrameCount = 0
        self.resizeDropBudget = 0
        self.captureScaleFactor = scaleFactor
        let logicalSize = CGSize(width: CGFloat(display.width), height: CGFloat(display.height))
        self.lastTrackedSize = logicalSize

        let reportedW = max(2, Int(logicalSize.width * 2.0) & ~1)
        let reportedH = max(2, Int(logicalSize.height * 2.0) & ~1)
        self.encodedWidth = UInt16(reportedW)
        self.encodedHeight = UInt16(reportedH)
        self.forceNextKeyframe = true

        let (encW, encH) = effectiveEncodeDimensions(for: logicalSize)
        try activateEncoder(width: Int32(encW), height: Int32(encH), fps: fps)

        let config = SCStreamConfiguration()
        config.width = encW
        config.height = encH
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(fps))
        config.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        Self.applyCanonicalSRGBStreamConfig(config, isBGRA: false)
        config.showsCursor = false
        config.queueDepth = 6
        config.scalesToFit = true
        if #available(macOS 14.0, *) {
            config.captureResolution = .automatic
            config.shouldBeOpaque = true
            config.presenterOverlayPrivacyAlertSetting = .never
        }

        let filter = SCContentFilter(display: display, excludingWindows: [])
        self.currentConfig = config

        let scStream = SCStream(filter: filter, configuration: config, delegate: nil)
        try scStream.addStreamOutput(self, type: .screen, sampleHandlerQueue: captureQueue)
        try await scStream.startCapture()
        self.stream = scStream
    }

    func checkWindowSizeNow() {
        captureQueue.async { [weak self] in
            guard let self, self.targetWindowID != 0, !self.isFloatingPopover else { return }
            self.checkWindowSizeOnQueue(windowID: self.targetWindowID, fps: self.currentFPS)
        }
    }

    func updateWindowLogicalSize(_ logicalSize: CGSize) {
        captureQueue.async { [weak self] in
            guard let self else { return }
            self.handleDetectedWindowLogicalSize(logicalSize, fps: self.currentFPS)
        }
    }

    private func checkWindowSizeOnQueue(windowID: UInt32, fps: Int) {
        guard let infoList = CGWindowListCopyWindowInfo([.optionIncludingWindow], windowID) as? [[String: Any]],
              let info = infoList.first,
              let boundsDict = info[kCGWindowBounds as String] as? NSDictionary,
              let rect = CGRect(dictionaryRepresentation: boundsDict),
              rect.width >= 60, rect.height >= 60 else {
            return
        }
        handleDetectedWindowLogicalSize(rect.size, fps: fps)
    }

    private func handleDetectedWindowLogicalSize(_ newLogicalSize: CGSize, fps: Int, forceReconfigure: Bool = false) {
        let minW: CGFloat = isFloatingPopover ? 40 : 60
        let minH: CGFloat = isFloatingPopover ? 22 : 60
        guard newLogicalSize.width >= minW,
              newLogicalSize.height >= minH,
              let stream = self.stream,
              let cfg = self.currentConfig else {
            return
        }
        let sizeChanged = abs(newLogicalSize.width - self.lastTrackedSize.width) > 2 ||
                          abs(newLogicalSize.height - self.lastTrackedSize.height) > 2
        guard sizeChanged || forceReconfigure else { return }
        self.lastTrackedSize = newLogicalSize
        let reportedW = max(2, Int(newLogicalSize.width * 2.0) & ~1)
        let reportedH = max(2, Int(newLogicalSize.height * 2.0) & ~1)
        self.encodedWidth = UInt16(reportedW)
        self.encodedHeight = UInt16(reportedH)

        let (encW, encH) = effectiveEncodeDimensions(for: newLogicalSize)
        guard encW != Int(self.activeEncoderWidth) || encH != Int(self.activeEncoderHeight) ||
              encW != self.expectedCaptureWidth || encH != self.expectedCaptureHeight || forceReconfigure else { return }

        if isFloatingPopover {
            self.pixelCropRect = nil
            self.croppedPixelBuffer = nil
            self.hasDetectedAlphaTrim = isNativeMenuPopover
            self.resizeDropBudget = sizeChanged ? 6 : 0
        }
        self.expectedCaptureWidth = encW
        self.expectedCaptureHeight = encH
        self.forceNextKeyframe = true
        cfg.width = encW
        cfg.height = encH
        self.invalidateAllEncoders()
        try? self.activateEncoder(width: Int32(encW), height: Int32(encH), fps: fps)
        Task {
            try? await stream.updateConfiguration(cfg)
        }
    }

    func setDynamicResolutionEnabled(_ enabled: Bool) {
        captureQueue.async { [weak self] in
            guard let self, self.dynamicResolutionEnabled != enabled else { return }
            self.dynamicResolutionEnabled = enabled
            self.handleDetectedWindowLogicalSize(self.lastTrackedSize, fps: self.currentFPS, forceReconfigure: true)
        }
    }

    func setNetworkTier(_ tier: StreamNetworkTier) {
        captureQueue.async { [weak self] in
            guard let self, self.networkTier != tier else { return }
            self.networkTier = tier
            let effFPS = self.effectiveTargetFPS(baseFPS: self.currentFPS)
            if let cfg = self.currentConfig {
                cfg.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(effFPS))
            }
            self.handleDetectedWindowLogicalSize(self.lastTrackedSize, fps: effFPS, forceReconfigure: true)
        }
    }

    func setTargetFPS(_ fps: Int) {
        let clamped = max(24, min(60, fps))
        captureQueue.async { [weak self] in
            guard let self, self.currentFPS != clamped else { return }
            self.currentFPS = clamped
            let effFPS = self.effectiveTargetFPS(baseFPS: clamped)
            guard let stream = self.stream, let cfg = self.currentConfig else { return }
            cfg.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(effFPS))
            if let session = self.compressionSession, self.activeEncoderWidth > 0, self.activeEncoderHeight > 0 {
                let targetBitrate = self.computeTargetBitrate(
                    width: self.activeEncoderWidth,
                    height: self.activeEncoderHeight,
                    fps: effFPS
                )
                VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ExpectedFrameRate, value: effFPS as CFNumber)
                VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxKeyFrameInterval, value: (effFPS * 60) as CFNumber)
                VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AverageBitRate, value: targetBitrate as CFNumber)
            }
            Task {
                try? await stream.updateConfiguration(cfg)
            }
        }
    }

    private func computeTargetBitrate(width: Int32, height: Int32, fps: Int) -> Int {
        let pixels = Int(width) * Int(height)
        let fpsFactor = 0.25 + 0.75 * (Double(max(24, min(60, fps))) / 60.0)
        switch networkTier {
        case .lan:
            let base60 = min(10_000_000, max(4_500_000, pixels * 3))
            return max(2_800_000, Int(Double(base60) * fpsFactor))
        case .wanDirect:
            // HEVC over public IPv6 / STUN P2P: ~40% higher compression efficiency, gentle on home broadband upload
            let base45 = min(4_000_000, max(1_800_000, Int(Double(pixels) * 1.45)))
            return max(1_400_000, Int(Double(base45) * fpsFactor))
        case .wanRelay:
            // HEVC over HK / public WSS 443 Relay: tightly capped at 1.0~2.0 Mbps so lightweight cloud relays never queue
            let base30 = min(2_100_000, max(1_100_000, Int(Double(pixels) * 0.95)))
            return max(950_000, min(2_000_000, base30))
        }
    }

    private func invalidateAllEncoders() {
        for session in encoderCache.values {
            VTCompressionSessionInvalidate(session)
        }
        encoderCache.removeAll()
        compressionSession = nil
        activeEncoderWidth = 0
        activeEncoderHeight = 0
    }

    func requestKeyframe() {
        captureQueue.async { [weak self] in
            guard let self else { return }
            self.forceNextKeyframe = true
            // Static windows and right-click context menus stop emitting SCStream frames once painted (.idle).
            // Immediately re-encode the latest captured buffer as an IDR keyframe so newly attached client surfaces
            // render static menus and dialogs instantaneously without waiting for screen damage!
            if let session = self.compressionSession, let buf = self.lastEncodedPixelBuffer {
                self.forceNextKeyframe = false
                let baseSec = (self.lastEncodedPTS.isValid && self.lastEncodedPTS.timescale > 0)
                    ? self.lastEncodedPTS.seconds
                    : CFAbsoluteTimeGetCurrent()
                let nextPTS = CMTime(seconds: baseSec + 0.002, preferredTimescale: 1_000_000)
                self.lastEncodedPTS = nextPTS
                let props = [kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary
                VTCompressionSessionEncodeFrame(
                    session,
                    imageBuffer: buf,
                    presentationTimeStamp: nextPTS,
                    duration: .invalid,
                    frameProperties: props,
                    sourceFrameRefcon: nil,
                    infoFlagsOut: nil
                )
            }
        }
    }

    func stopCapture() async {
        currentConfig = nil
        if let stream {
            try? await stream.stopCapture()
            self.stream = nil
        }
        captureQueue.sync {
            self.lastEncodedPixelBuffer = nil
            self.croppedPixelBuffer = nil
        }
        invalidateAllEncoders()
    }

    private func activateEncoder(width: Int32, height: Int32, fps: Int, forceH264: Bool = false) throws {
        let effFPS = effectiveTargetFPS(baseFPS: fps)
        // Always prefer universally-compatible H.264 for compact floating popovers/context menus so small
        // menu dimensions never hit hardware HEVC minimum-dimension quirks on Apple Silicon or mobile decoders.
        let wantHEVC = !forceH264 && !isFloatingPopover && networkTier.prefersHEVC
        let codecTag = wantHEVC ? "hevc" : "h264"
        let key = "\(codecTag)-\(networkTier.rawValue)-\(width)x\(height)"
        if let cached = encoderCache[key] {
            self.compressionSession = cached
            self.activeEncoderWidth = width
            self.activeEncoderHeight = height
            return
        }

        var session: VTCompressionSession?
        let encoderSpec: [CFString: Any] = [
            kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder: true
        ]
        let preferredCodec: CMVideoCodecType = wantHEVC ? kCMVideoCodecType_HEVC : kCMVideoCodecType_H264
        var usingHEVC = wantHEVC

        var status = VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            width: width,
            height: height,
            codecType: preferredCodec,
            encoderSpecification: encoderSpec as CFDictionary,
            imageBufferAttributes: nil,
            compressedDataAllocator: nil,
            outputCallback: vtOutputCallback,
            refcon: Unmanaged.passUnretained(self).toOpaque(),
            compressionSessionOut: &session
        )
        if status != noErr || session == nil {
            // Graceful fallback to H.264 if HEVC or hardware encoder is unavailable
            usingHEVC = false
            status = VTCompressionSessionCreate(
                allocator: kCFAllocatorDefault,
                width: width,
                height: height,
                codecType: kCMVideoCodecType_H264,
                encoderSpecification: nil,
                imageBufferAttributes: nil,
                compressedDataAllocator: nil,
                outputCallback: vtOutputCallback,
                refcon: Unmanaged.passUnretained(self).toOpaque(),
                compressionSessionOut: &session
            )
        }
        guard status == noErr, let session else {
            throw NSError(domain: "OpenUUEncoder", code: Int(status))
        }

        let targetBitrate = computeTargetBitrate(width: width, height: height, fps: effFPS)

        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxFrameDelayCount, value: 0 as CFNumber)
        if networkTier == .wanRelay && !isFloatingPopover {
            VTSessionSetProperty(session, key: kVTCompressionPropertyKey_PrioritizeEncodingSpeedOverQuality, value: kCFBooleanTrue)
        }
        // Explicitly signal canonical sRGB / ITU-R BT.709 colorimetry in H.264/HEVC SPS VUI so client decoders
        // never guess Rec.709 1.96-gamma or BT.601 on desktop UI content.
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ColorPrimaries, value: kCVImageBufferColorPrimaries_ITU_R_709_2)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_TransferFunction, value: kCVImageBufferTransferFunction_sRGB)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_YCbCrMatrix, value: kCVImageBufferYCbCrMatrix_ITU_R_709_2)
        if usingHEVC {
            VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ProfileLevel, value: kVTProfileLevel_HEVC_Main_AutoLevel)
        } else {
            VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ProfileLevel, value: kVTProfileLevel_H264_High_AutoLevel)
        }
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxKeyFrameInterval, value: (effFPS * 60) as CFNumber)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, value: 60.0 as CFNumber)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ExpectedFrameRate, value: effFPS as CFNumber)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AverageBitRate, value: targetBitrate as CFNumber)
        VTCompressionSessionPrepareToEncodeFrames(session)
        encoderCache[key] = session
        self.compressionSession = session
        self.activeEncoderWidth = width
        self.activeEncoderHeight = height
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen,
              let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer),
              compressionSession != nil else {
            return
        }
        let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]]

        // Skip idle/unchanged frames (unless a keyframe was explicitly requested) to save CPU & LAN bandwidth.
        if !forceNextKeyframe,
           let statusRaw = attachments?.first?[.status] as? Int,
           let status = SCFrameStatus(rawValue: statusRaw),
           status == .idle {
            return
        }

        // Briefly skip pre-resize frames right after a dynamic popover resize (`resizeDropBudget > 0`),
        // but NEVER drop indefinitely on 1x external monitors where SCStream delivers native 1x buffers!
        if isFloatingPopover && resizeDropBudget > 0 && expectedCaptureWidth > 0 && expectedCaptureHeight > 0 {
            let bufW = CVPixelBufferGetWidth(imageBuffer)
            let bufH = CVPixelBufferGetHeight(imageBuffer)
            if abs(bufW - expectedCaptureWidth) > 2 || abs(bufH - expectedCaptureHeight) > 2 {
                resizeDropBudget -= 1
                return
            }
            resizeDropBudget = 0
        }

        // On the first frame of a custom floating popover (e.g. WeChat emoji picker / sticker preview / search dropdown),
        // auto-detect transparent custom-shadow padding via the BGRA alpha channel and crop directly!
        if isFloatingPopover && !hasDetectedAlphaTrim {
            hasDetectedAlphaTrim = true
            detectAndTrimTransparentShadowMargin(imageBuffer)
        }

        let bufferToEncode: CVPixelBuffer
        if let crop = pixelCropRect, let cropped = cropBGRAPixelBuffer(imageBuffer, crop: crop) {
            bufferToEncode = cropped
        } else {
            bufferToEncode = imageBuffer
        }
        Self.tagBufferWithCanonicalSRGB(bufferToEncode)

        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        self.lastEncodedPixelBuffer = bufferToEncode
        self.lastEncodedPTS = pts
        let wasFirstFrame = (self.encodedFrameCount == 0)
        self.encodedFrameCount += 1

        guard var activeSession = compressionSession else { return }
        let wasForcedKeyframe = forceNextKeyframe
        var frameProps: CFDictionary?
        if forceNextKeyframe {
            forceNextKeyframe = false
            frameProps = [kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary
        }
        let encodeStatus = VTCompressionSessionEncodeFrame(
            activeSession,
            imageBuffer: bufferToEncode,
            presentationTimeStamp: pts,
            duration: .invalid,
            frameProperties: frameProps,
            sourceFrameRefcon: nil,
            infoFlagsOut: nil
        )
        if encodeStatus != noErr {
            invalidateAllEncoders()
            let fallbackW = max(128, activeEncoderWidth > 0 ? activeEncoderWidth : Int32(CVPixelBufferGetWidth(bufferToEncode) & ~1))
            let fallbackH = max(128, activeEncoderHeight > 0 ? activeEncoderHeight : Int32(CVPixelBufferGetHeight(bufferToEncode) & ~1))
            if (try? activateEncoder(width: fallbackW, height: fallbackH, fps: currentFPS, forceH264: true)) != nil,
               let retrySession = compressionSession {
                activeSession = retrySession
                let retryProps = (wasForcedKeyframe || wasFirstFrame)
                    ? ([kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary)
                    : nil
                VTCompressionSessionEncodeFrame(
                    activeSession,
                    imageBuffer: bufferToEncode,
                    presentationTimeStamp: pts,
                    duration: .invalid,
                    frameProperties: retryProps,
                    sourceFrameRefcon: nil,
                    infoFlagsOut: nil
                )
            }
        }

        // For static floating popovers/context menus, proactively echo a second frame shortly after Frame #1
        // so mobile decoders with 1-frame DPB latency or async Surface creation always render immediately.
        if isFloatingPopover && wasFirstFrame {
            captureQueue.asyncAfter(deadline: .now() + .milliseconds(75)) { [weak self] in
                guard let self, self.encodedFrameCount == 1 else { return }
                self.requestKeyframe()
            }
        }
    }

    private func detectAndTrimTransparentShadowMargin(_ pixelBuffer: CVPixelBuffer) {
        guard CVPixelBufferGetPixelFormatType(pixelBuffer) == kCVPixelFormatType_32BGRA else {
            return
        }
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else { return }
        let w = CVPixelBufferGetWidth(pixelBuffer)
        let h = CVPixelBufferGetHeight(pixelBuffer)
        let bpr = CVPixelBufferGetBytesPerRow(pixelBuffer)
        guard w > 40, h > 28 else { return }

        let ptr = base.assumingMemoryBound(to: UInt8.self)
        // Use alphaThreshold = 64 so transparent/soft-shadow outer margins (`alpha == 0..60`) are cleanly trimmed,
        // while semi-transparent vibrancy menus (`alpha ~ 170..230`) are never falsely cropped!
        let alphaThreshold: UInt8 = 64
        let midY = h / 2
        let midX = w / 2

        func alphaAt(_ x: Int, _ y: Int) -> UInt8 {
            ptr[y * bpr + x * 4 + 3]
        }

        var leftPx = 0
        while leftPx < w / 3 && alphaAt(leftPx, midY) < alphaThreshold { leftPx += 1 }
        var rightPx = 0
        while rightPx < w / 3 && alphaAt(w - 1 - rightPx, midY) < alphaThreshold { rightPx += 1 }
        var topPx = 0
        while topPx < h / 3 && alphaAt(midX, topPx) < alphaThreshold { topPx += 1 }
        var bottomPx = 0
        while bottomPx < h / 3 && alphaAt(midX, h - 1 - bottomPx) < alphaThreshold { bottomPx += 1 }

        // If there is NO custom outer shadow margin (`< 4px`) AND the interior is translucent (`alpha < 245`),
        // this popover uses macOS `CABackdropLayer` / `NSVisualEffectView` vibrancy — switch `shouldBeOpaque = true`
        // so ScreenCaptureKit composites an opaque system material backdrop!
        if max(leftPx, rightPx, topPx, bottomPx) < 4 {
            if alphaAt(midX, midY) < 245, let stream = self.stream, let cfg = self.currentConfig {
                if #available(macOS 14.0, *), !cfg.shouldBeOpaque {
                    cfg.shouldBeOpaque = true
                    self.forceNextKeyframe = true
                    Task {
                        try? await stream.updateConfiguration(cfg)
                    }
                }
            }
            return
        }

        let cropW = (w - leftPx - rightPx) & ~1
        let cropH = (h - topPx - bottomPx) & ~1
        guard cropW >= 40, cropH >= 24 else { return }

        // Compute true buffer-to-logical ratio directly from `w x h` vs `lastTrackedSize` so 1x and 2x monitors both match!
        let scaleX = lastTrackedSize.width > 1 ? (CGFloat(w) / lastTrackedSize.width) : max(1.0, captureScaleFactor)
        let scaleY = lastTrackedSize.height > 1 ? (CGFloat(h) / lastTrackedSize.height) : max(1.0, captureScaleFactor)
        let croppedLogicalW = CGFloat(cropW) / max(1.0, scaleX)
        let croppedLogicalH = CGFloat(cropH) / max(1.0, scaleY)

        self.pixelCropRect = (x: leftPx, y: topPx, w: cropW, h: cropH)
        self.encodedWidth = UInt16(max(2, Int(croppedLogicalW * 2.0) & ~1))
        self.encodedHeight = UInt16(max(2, Int(croppedLogicalH * 2.0) & ~1))
        self.forceNextKeyframe = true

        onContentInsetDetected?(
            targetWindowID,
            CGPoint(x: CGFloat(leftPx) / max(1.0, scaleX), y: CGFloat(topPx) / max(1.0, scaleY)),
            CGSize(width: croppedLogicalW, height: croppedLogicalH)
        )

        let (encW, encH) = Self.ensureMinimumEncodeDimensions(width: cropW, height: cropH, isPopover: true)
        invalidateAllEncoders()
        try? activateEncoder(width: Int32(encW), height: Int32(encH), fps: currentFPS)
    }

    private func cropBGRAPixelBuffer(_ src: CVPixelBuffer, crop: (x: Int, y: Int, w: Int, h: Int)) -> CVPixelBuffer? {
        guard CVPixelBufferGetPixelFormatType(src) == kCVPixelFormatType_32BGRA else { return nil }
        let srcW = CVPixelBufferGetWidth(src)
        let srcH = CVPixelBufferGetHeight(src)
        guard crop.x + crop.w <= srcW, crop.y + crop.h <= srcH else { return nil }

        if croppedPixelBuffer == nil ||
            CVPixelBufferGetWidth(croppedPixelBuffer!) != crop.w ||
            CVPixelBufferGetHeight(croppedPixelBuffer!) != crop.h {
            var newBuf: CVPixelBuffer?
            let attrs: [CFString: Any] = [
                kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary
            ]
            CVPixelBufferCreate(
                kCFAllocatorDefault,
                crop.w,
                crop.h,
                kCVPixelFormatType_32BGRA,
                attrs as CFDictionary,
                &newBuf
            )
            croppedPixelBuffer = newBuf
        }
        guard let dst = croppedPixelBuffer else { return nil }

        CVPixelBufferLockBaseAddress(src, .readOnly)
        CVPixelBufferLockBaseAddress(dst, [])
        defer {
            CVPixelBufferUnlockBaseAddress(dst, [])
            CVPixelBufferUnlockBaseAddress(src, .readOnly)
        }
        guard let srcBase = CVPixelBufferGetBaseAddress(src),
              let dstBase = CVPixelBufferGetBaseAddress(dst) else { return nil }

        let srcBPR = CVPixelBufferGetBytesPerRow(src)
        let dstBPR = CVPixelBufferGetBytesPerRow(dst)
        let rowBytes = crop.w * 4
        for row in 0..<crop.h {
            let srcPtr = srcBase.advanced(by: (crop.y + row) * srcBPR + crop.x * 4)
            let dstPtr = dstBase.advanced(by: row * dstBPR)
            memcpy(dstPtr, srcPtr, rowBytes)
        }
        CVBufferPropagateAttachments(src, dst)
        return dst
    }

    private static let sRGBColorSpace: CGColorSpace? = CGColorSpace(name: CGColorSpace.sRGB)

    private static func applyCanonicalSRGBStreamConfig(_ config: SCStreamConfiguration, isBGRA: Bool) {
        config.colorSpaceName = CGColorSpace.sRGB
        if !isBGRA {
            config.colorMatrix = kCVImageBufferYCbCrMatrix_ITU_R_709_2
        }
    }

    private static func tagBufferWithCanonicalSRGB(_ pixelBuffer: CVPixelBuffer) {
        let isBGRA = CVPixelBufferGetPixelFormatType(pixelBuffer) == kCVPixelFormatType_32BGRA
        CVBufferSetAttachment(
            pixelBuffer,
            kCVImageBufferColorPrimariesKey,
            kCVImageBufferColorPrimaries_ITU_R_709_2,
            .shouldPropagate
        )
        CVBufferSetAttachment(
            pixelBuffer,
            kCVImageBufferTransferFunctionKey,
            kCVImageBufferTransferFunction_sRGB,
            .shouldPropagate
        )
        if isBGRA {
            if let cs = sRGBColorSpace {
                CVBufferSetAttachment(pixelBuffer, kCVImageBufferCGColorSpaceKey, cs, .shouldPropagate)
            }
        } else {
            CVBufferSetAttachment(
                pixelBuffer,
                kCVImageBufferYCbCrMatrixKey,
                kCVImageBufferYCbCrMatrix_ITU_R_709_2,
                .shouldPropagate
            )
        }
    }

    fileprivate func handleEncodedSampleBuffer(_ sampleBuffer: CMSampleBuffer) {
        guard let dataBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return }

        var isKeyframe = false
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[CFString: Any]],
           let first = attachments.first {
            let notSync = (first[kCMSampleAttachmentKey_NotSync] as? Bool) ?? false
            isKeyframe = !notSync
        }

        var annexB = Data()
        let startCode: [UInt8] = [0x00, 0x00, 0x00, 0x01]
        let formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer)
        let isHEVC = formatDesc.map { CMFormatDescriptionGetMediaSubType($0) == kCMVideoCodecType_HEVC } ?? false

        // Prepend VPS/SPS/PPS (HEVC) or SPS/PPS (H.264) on keyframes so any freshly connected client can decode immediately.
        if isKeyframe, let formatDesc {
            var paramCount: Int = 0
            if isHEVC {
                CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(
                    formatDesc,
                    parameterSetIndex: 0,
                    parameterSetPointerOut: nil,
                    parameterSetSizeOut: nil,
                    parameterSetCountOut: &paramCount,
                    nalUnitHeaderLengthOut: nil
                )
                for idx in 0..<paramCount {
                    var ptr: UnsafePointer<UInt8>?
                    var size: Int = 0
                    if CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(
                        formatDesc,
                        parameterSetIndex: idx,
                        parameterSetPointerOut: &ptr,
                        parameterSetSizeOut: &size,
                        parameterSetCountOut: nil,
                        nalUnitHeaderLengthOut: nil
                    ) == noErr, let ptr {
                        annexB.append(contentsOf: startCode)
                        annexB.append(ptr, count: size)
                    }
                }
            } else {
                CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                    formatDesc,
                    parameterSetIndex: 0,
                    parameterSetPointerOut: nil,
                    parameterSetSizeOut: nil,
                    parameterSetCountOut: &paramCount,
                    nalUnitHeaderLengthOut: nil
                )
                for idx in 0..<paramCount {
                    var ptr: UnsafePointer<UInt8>?
                    var size: Int = 0
                    if CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                        formatDesc,
                        parameterSetIndex: idx,
                        parameterSetPointerOut: &ptr,
                        parameterSetSizeOut: &size,
                        parameterSetCountOut: nil,
                        nalUnitHeaderLengthOut: nil
                    ) == noErr, let ptr {
                        annexB.append(contentsOf: startCode)
                        annexB.append(ptr, count: size)
                    }
                }
            }
        }

        // Convert AVCC/HVCC length-prefixed NALUs into Annex-B stream.
        var totalLength: Int = 0
        var dataPointer: UnsafeMutablePointer<Int8>?
        guard CMBlockBufferGetDataPointer(
            dataBuffer,
            atOffset: 0,
            lengthAtOffsetOut: nil,
            totalLengthOut: &totalLength,
            dataPointerOut: &dataPointer
        ) == kCMBlockBufferNoErr, let dataPointer else { return }

        annexB.reserveCapacity(annexB.count + totalLength + 32)
        var offset = 0
        while offset + 4 <= totalLength {
            var naluLenBE: UInt32 = 0
            memcpy(&naluLenBE, dataPointer.advanced(by: offset), 4)
            let naluLen = Int(UInt32(bigEndian: naluLenBE))
            offset += 4
            guard naluLen > 0, offset + naluLen <= totalLength else { break }
            annexB.append(contentsOf: startCode)
            dataPointer.advanced(by: offset).withMemoryRebound(to: UInt8.self, capacity: naluLen) { u8Ptr in
                annexB.append(u8Ptr, count: naluLen)
            }
            offset += naluLen
        }

        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let ptsUS = pts.isValid && pts.timescale > 0 ? UInt64(max(0, pts.seconds * 1_000_000)) : 0
        let flags: UInt8 = isKeyframe ? 0x01 : 0x00
        let wireCodec: UInt8 = isHEVC ? 2 : 1
        onEncodedFrame?(wireCodec, flags, targetWindowID, ptsUS, encodedWidth, encodedHeight, annexB)
    }
}

private func vtOutputCallback(
    outputCallbackRefCon: UnsafeMutableRawPointer?,
    sourceFrameRefCon: UnsafeMutableRawPointer?,
    status: OSStatus,
    infoFlags: VTEncodeInfoFlags,
    sampleBuffer: CMSampleBuffer?
) {
    guard status == noErr, let outputCallbackRefCon, let sampleBuffer else { return }
    let engine = Unmanaged<ScreenCaptureEngine>.fromOpaque(outputCallbackRefCon).takeUnretainedValue()
    engine.handleEncodedSampleBuffer(sampleBuffer)
}
