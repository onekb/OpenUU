import SwiftUI
import UIKit
import UniformTypeIdentifiers

// MARK: - Remote Workspace Container

struct RemoteWorkspaceContainer: View {
    @ObservedObject var viewModel: MobileSessionViewModel
    let isLandscape: Bool
    let isImmersive: Bool
    let viewportSize: CGSize

    @State private var showKeyboardDock = false
    @State private var imeRequested = false
    @State private var imeRequestSeq: Int = 0
    @State private var isIMEEditing = false
    @State private var imeComposingPreview = ""
    @State private var showSessionSheet = false
    @State private var showLastWindowDialog = false
    @State private var showFileImporter = false

    @State private var tabStripAutoRevealed = false
    @State private var manualTabStripRevealed = false
    @State private var tabRevealTask: Task<Void, Never>?

    private var hostName: String {
        let name = viewModel.phase.hostName
        return name.isEmpty ? "Mac" : name
    }

    private var rttPillText: String {
        if viewModel.linkRttMs > 0 {
            return "\(viewModel.linkRttMs)ms"
        }
        if !viewModel.linkBadge.isEmpty {
            return viewModel.linkBadge.components(separatedBy: " ").first ?? viewModel.linkBadge
        }
        return "在线"
    }

    private var videoAspectRatio: CGFloat {
        let sz = viewModel.currentLogicalSize()
        guard sz.width > 1, sz.height > 1 else { return 16.0 / 10.0 }
        return sz.width / sz.height
    }

    private var dockTabStrip: Bool {
        !isImmersive || viewModel.pinLandscapeTabBar
    }

    private var overlayTabStripVisible: Bool {
        isImmersive && !viewModel.pinLandscapeTabBar && (tabStripAutoRevealed || manualTabStripRevealed)
    }

    private var appSwitcherSheetBinding: Binding<Bool> {
        Binding(
            get: { viewModel.showAppLauncher && viewModel.selectedWindowID != 0 },
            set: { newVal in viewModel.showAppLauncher = newVal }
        )
    }

    var body: some View {
        ZStack(alignment: .top) {
            // Keep MobileRemoteCanvasView in the exact same VStack slot across rotation/fullscreen
            // so AVSampleBufferDisplayLayer never drops frames or re-initializes.
            VStack(spacing: 0) {
                if dockTabStrip {
                    WindowTabStrip(
                        normalWindows: viewModel.normalWindows,
                        selectedWindowID: viewModel.selectedWindowID,
                        showAppLauncher: viewModel.showAppLauncher,
                        touchMode: viewModel.touchMode,
                        showKeyboardDock: showKeyboardDock,
                        rttText: rttPillText,
                        showCollapseButton: false,
                        onStepBack: handleStepBack,
                        onCollapse: {},
                        onOpenApps: handleOpenAppsTap,
                        onSelectWindow: { viewModel.selectWindow($0) },
                        onCloseWindow: handleCloseWindowTab,
                        onToggleTouchMode: toggleTouchMode,
                        onToggleKeyboard: toggleKeyboardDockAndIME,
                        onOpenSessionMenu: { showSessionSheet = true }
                    )
                }

                ZStack(alignment: .bottomLeading) {
                    if viewModel.selectedWindowID == 0 {
                        RemoteAppLauncherView(viewModel: viewModel)
                            .simultaneousGesture(
                                DragGesture(minimumDistance: 24, coordinateSpace: .local)
                                    .onEnded { value in
                                        if value.startLocation.x < 34
                                            && value.translation.width > 64
                                            && abs(value.translation.height) < 60 {
                                            handleStepBack()
                                        }
                                    }
                            )
                    } else {
                        MobileRemoteCanvasView(
                            renderer: viewModel.videoRenderer,
                            aspectRatio: videoAspectRatio,
                            touchMode: viewModel.touchMode,
                            videoFitMode: viewModel.videoFitMode,
                            isImmersive: isImmersive,
                            cursorPos: viewModel.cursorPos,
                            cursorKind: viewModel.cursorKind,
                            activePopovers: viewModel.activePopovers,
                            popoverReadyIDs: viewModel.popoverReadyIDs,
                            parentLogicalSize: viewModel.currentLogicalSize(),
                            popoverRenderers: viewModel.popoverRenderers,
                            resetToken: viewModel.canvasResetToken,
                            zoomCommandScale: viewModel.canvasZoomCommandScale,
                            zoomCommandToken: viewModel.canvasZoomCommandToken,
                            onZoomChanged: { scale in
                                viewModel.canvasZoomScale = scale
                            },
                            onCursorPosChanged: { pos in
                                viewModel.cursorPos = pos
                            },
                            onMouseEvent: { nx, ny, type, button, clickCount in
                                viewModel.sendMouseNormalized(
                                    nx: nx,
                                    ny: ny,
                                    type: type,
                                    button: button,
                                    clickCount: clickCount
                                )
                            },
                            onPopoverMouseEvent: { winID, lx, ly, effRelX, effRelY, type, button, clickCount in
                                viewModel.sendPopoverMouseDirect(
                                    popoverWindowID: winID,
                                    lx: lx,
                                    ly: ly,
                                    effectiveRelX: effRelX,
                                    effectiveRelY: effRelY,
                                    type: type,
                                    button: button,
                                    clickCount: clickCount
                                )
                            },
                            onScrollEvent: { nx, ny, dx, dy in
                                viewModel.sendScrollNormalized(nx: nx, ny: ny, deltaX: dx, deltaY: dy)
                            },
                            onPopoverScrollEvent: { winID, lx, ly, dx, dy in
                                viewModel.sendPopoverScrollDirect(
                                    popoverWindowID: winID,
                                    lx: lx,
                                    ly: ly,
                                    deltaX: dx,
                                    deltaY: dy
                                )
                            },
                            onGestureBadgeChanged: { badge in
                                viewModel.gestureFeedbackBadge = badge
                            },
                            onToggleKeyboard: toggleKeyboardDockAndIME,
                            onToggleToolbar: {
                                if isImmersive && !viewModel.pinLandscapeTabBar {
                                    withAnimation(.easeInOut(duration: 0.2)) {
                                        manualTabStripRevealed.toggle()
                                    }
                                } else {
                                    viewModel.manualFullscreen.toggle()
                                }
                            }
                        )
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }

                    if viewModel.selectedWindowID != 0 && showKeyboardDock {
                        DirectRemoteIMEHost(
                            imeRequested: imeRequested,
                            imeRequestSeq: imeRequestSeq,
                            onCommitText: { text in
                                viewModel.handleDirectIMEInput(text)
                            },
                            onBackspace: { isRepeat in
                                viewModel.sendKeyTap(keyCode: MacKeyCodes.delete, isRepeat: isRepeat)
                            },
                            onReturnKey: {
                                viewModel.sendKeyTap(keyCode: MacKeyCodes.returnKey)
                            },
                            onComposingPreview: { preview in
                                imeComposingPreview = preview
                            },
                            onEditingChanged: { editing in
                                isIMEEditing = editing
                                if !editing && imeRequested {
                                    imeRequested = false
                                    imeComposingPreview = ""
                                }
                            }
                        )
                        .frame(width: 1, height: 1)
                        .opacity(0.01)
                        .allowsHitTesting(false)
                    }

                    if let badge = viewModel.gestureFeedbackBadge, viewModel.selectedWindowID != 0 {
                        VStack {
                            GestureFeedbackBadgeView(text: badge)
                                .padding(.top, overlayTabStripVisible ? 48 : 12)
                            Spacer()
                        }
                        .frame(maxWidth: .infinity)
                        .allowsHitTesting(false)
                    }

                    if viewModel.showDebugHUD && viewModel.selectedWindowID != 0 {
                        DebugTelemetryHUDView(viewModel: viewModel)
                            .padding(.leading, isLandscape ? 22 : 10)
                            .padding(.bottom, 10)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                if viewModel.selectedWindowID != 0 && showKeyboardDock {
                    MacKeyboardAndIMEDock(
                        viewModel: viewModel,
                        isIMEActive: isIMEEditing || imeRequested,
                        composingPreview: imeComposingPreview,
                        onToggleIME: toggleSystemIMEOnly,
                        onCloseDock: closeKeyboardDockAndIME
                    )
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            // Fullscreen Auto-Revealed / Manual Overlay WindowTabStrip
            if overlayTabStripVisible {
                WindowTabStrip(
                    normalWindows: viewModel.normalWindows,
                    selectedWindowID: viewModel.selectedWindowID,
                    showAppLauncher: viewModel.showAppLauncher,
                    touchMode: viewModel.touchMode,
                    showKeyboardDock: showKeyboardDock,
                    rttText: rttPillText,
                    showCollapseButton: true,
                    onStepBack: handleStepBack,
                    onCollapse: {
                        withAnimation(.easeOut(duration: 0.18)) {
                            manualTabStripRevealed = false
                            tabStripAutoRevealed = false
                        }
                    },
                    onOpenApps: {
                        manualTabStripRevealed = false
                        tabStripAutoRevealed = false
                        viewModel.showAppLauncher = true
                        viewModel.refreshRemoteApps()
                    },
                    onSelectWindow: { viewModel.selectWindow($0) },
                    onCloseWindow: handleCloseWindowTab,
                    onToggleTouchMode: toggleTouchMode,
                    onToggleKeyboard: {
                        manualTabStripRevealed = false
                        tabStripAutoRevealed = false
                        toggleKeyboardDockAndIME()
                    },
                    onOpenSessionMenu: {
                        manualTabStripRevealed = false
                        showSessionSheet = true
                    }
                )
                .transition(.move(edge: .top).combined(with: .opacity))
                .zIndex(20)
            }

            // Minimal Collapsed Edge Pill in Landscape / Immersive Fullscreen
            if isImmersive && !viewModel.pinLandscapeTabBar && !overlayTabStripVisible {
                HStack {
                    Spacer()
                    collapsedEdgePill
                        .padding(.top, isLandscape ? 8 : 44)
                        .padding(.trailing, isLandscape ? 16 : 10)
                }
                .zIndex(25)
            }

            // Proactive Auto-Focus New Window Notice Pill
            if let notice = viewModel.windowSwitchNotice {
                windowSwitchToast(notice)
                    .padding(.top, (dockTabStrip || overlayTabStripVisible) ? 44 : 10)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .zIndex(30)
            }
        }
        .background(isImmersive ? Color.black : OpenUUTheme.background)
        .animation(.easeOut(duration: 0.2), value: overlayTabStripVisible)
        .animation(.easeOut(duration: 0.2), value: viewModel.windowSwitchNotice)
        .onChange(of: viewModel.proactiveTabRevealTick) { _, tick in
            guard tick > 0, isImmersive, !viewModel.pinLandscapeTabBar else { return }
            tabRevealTask?.cancel()
            withAnimation(.easeOut(duration: 0.2)) {
                tabStripAutoRevealed = true
            }
            tabRevealTask = Task {
                try? await Task.sleep(for: .seconds(4))
                if !Task.isCancelled {
                    await MainActor.run {
                        withAnimation(.easeOut(duration: 0.2)) {
                            tabStripAutoRevealed = false
                        }
                    }
                }
            }
        }
        .onChange(of: isImmersive) { _, immersive in
            if !immersive {
                manualTabStripRevealed = false
                tabStripAutoRevealed = false
            }
        }
        .onDisappear {
            tabRevealTask?.cancel()
        }
        .sheet(isPresented: appSwitcherSheetBinding) {
            RemoteAppSwitcherSheet(viewModel: viewModel)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showSessionSheet) {
            SessionControlSheet(
                viewModel: viewModel,
                hostName: hostName,
                isLandscape: isLandscape,
                viewportSize: viewportSize,
                onPickFile: {
                    showSessionSheet = false
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                        showFileImporter = true
                    }
                },
                onOpenGestureGuide: {
                    showSessionSheet = false
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                        viewModel.showGestureGuide = true
                    }
                }
            )
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
        .confirmationDialog(
            "关闭「\(viewModel.normalWindows.first?.displayTitle ?? "当前窗口")」",
            isPresented: $showLastWindowDialog,
            titleVisibility: .visible
        ) {
            Button("在 Mac 上关闭该窗口 (⌘W)") {
                let targetID = viewModel.normalWindows.first?.window_id ?? viewModel.selectedWindowID
                if targetID != 0 {
                    viewModel.closeRemoteWindowTab(targetID)
                }
            }
            Button("切换其他远程应用") {
                viewModel.showAppLauncher = true
                viewModel.refreshRemoteApps()
            }
            Button("断开与 \(hostName) 的远控连接", role: .destructive) {
                viewModel.disconnect()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("这是当前会话中最后一个打开的窗口，请选择操作。")
        }
        .fileImporter(
            isPresented: $showFileImporter,
            allowedContentTypes: [.item],
            allowsMultipleSelection: false
        ) { result in
            if case .success(let urls) = result, let url = urls.first {
                viewModel.handlePickedFile(url: url)
            }
        }
    }

    // MARK: Actions & Compact Overlays

    private func openKeyboardDockAndIME() {
        withAnimation(.easeInOut(duration: 0.18)) {
            showKeyboardDock = true
        }
        imeRequested = true
        imeRequestSeq += 1
    }

    private func closeKeyboardDockAndIME() {
        imeRequested = false
        isIMEEditing = false
        imeComposingPreview = ""
        withAnimation(.easeInOut(duration: 0.18)) {
            showKeyboardDock = false
        }
    }

    private func toggleKeyboardDockAndIME() {
        if !showKeyboardDock {
            openKeyboardDockAndIME()
        } else {
            closeKeyboardDockAndIME()
        }
    }

    private func toggleSystemIMEOnly() {
        if isIMEEditing || imeRequested {
            imeRequested = false
            isIMEEditing = false
            imeComposingPreview = ""
        } else {
            withAnimation(.easeInOut(duration: 0.18)) {
                showKeyboardDock = true
            }
            imeRequested = true
            imeRequestSeq += 1
        }
    }

    private func handleStepBack() {
        if overlayTabStripVisible {
            withAnimation(.easeOut(duration: 0.18)) {
                manualTabStripRevealed = false
                tabStripAutoRevealed = false
            }
            return
        }
        if isIMEEditing || imeRequested {
            imeRequested = false
            isIMEEditing = false
            imeComposingPreview = ""
            return
        }
        if showKeyboardDock {
            closeKeyboardDockAndIME()
            return
        }
        if viewModel.selectedWindowID != 0 && !viewModel.activePopovers.isEmpty {
            viewModel.dismissActivePopoversViaEsc()
            return
        }
        if viewModel.manualFullscreen {
            viewModel.manualFullscreen = false
            return
        }
        if viewModel.selectedWindowID != 0 && viewModel.canvasZoomScale > 1.02 {
            viewModel.resetZoom()
            return
        }
        if viewModel.canNavigateBackWindow {
            _ = viewModel.navigateBackWindow()
            return
        }
        if viewModel.selectedWindowID != 0 {
            viewModel.enterAppLauncherPage()
            return
        }
        viewModel.selectedTab = .connect
    }

    private func handleOpenAppsTap() {
        if viewModel.selectedWindowID == 0 {
            viewModel.refreshRemoteApps()
        } else {
            viewModel.showAppLauncher.toggle()
            if viewModel.showAppLauncher {
                viewModel.refreshRemoteApps()
            }
        }
    }

    private func handleCloseWindowTab(_ windowID: UInt32) {
        if viewModel.normalWindows.count >= 2 {
            viewModel.closeRemoteWindowTab(windowID)
        } else {
            showLastWindowDialog = true
        }
    }

    private func toggleTouchMode() {
        viewModel.touchMode = (viewModel.touchMode == .directTouch) ? .trackpad : .directTouch
    }

    private var collapsedEdgePill: some View {
        HStack(spacing: 0) {
            Button {
                withAnimation(.easeOut(duration: 0.2)) {
                    manualTabStripRevealed = true
                }
            } label: {
                HStack(spacing: 5) {
                    Circle()
                        .fill(OpenUUTheme.liveDot)
                        .frame(width: 6, height: 6)
                    Text("\(viewModel.normalWindows.count) 窗")
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(OpenUUTheme.textPrimary)
                }
                .padding(.leading, 10)
                .padding(.trailing, 8)
                .frame(height: 28)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Rectangle()
                .fill(OpenUUTheme.hairline)
                .frame(width: 0.5, height: 14)

            Button {
                showSessionSheet = true
            } label: {
                Text("菜单")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(OpenUUTheme.textSecondary)
                    .padding(.leading, 8)
                    .padding(.trailing, 10)
                    .frame(height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .background(
            Capsule().fill(Color(red: 22 / 255, green: 22 / 255, blue: 26 / 255, opacity: 0.80))
        )
        .overlay(
            Capsule().stroke(OpenUUTheme.hairline, lineWidth: 0.5)
        )
    }

    private func windowSwitchToast(_ text: String) -> some View {
        HStack(spacing: 6) {
            Circle()
                .fill(OpenUUTheme.liveDot)
                .frame(width: 6, height: 6)
            Text(text)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(OpenUUTheme.textPrimary)
                .lineLimit(1)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(
            Capsule().fill(Color(red: 22 / 255, green: 22 / 255, blue: 26 / 255, opacity: 0.92))
        )
        .overlay(
            Capsule().stroke(OpenUUTheme.popoverBorder, lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.45), radius: 8, y: 3)
        .allowsHitTesting(false)
    }
}

// MARK: - Browser-Style 38pt Window Tab Strip

private struct WindowTabStrip: View {
    let normalWindows: [WindowTopologyItem]
    let selectedWindowID: UInt32
    let showAppLauncher: Bool
    let touchMode: TouchControlMode
    let showKeyboardDock: Bool
    let rttText: String
    let showCollapseButton: Bool
    let onStepBack: () -> Void
    let onCollapse: () -> Void
    let onOpenApps: () -> Void
    let onSelectWindow: (UInt32) -> Void
    let onCloseWindow: (UInt32) -> Void
    let onToggleTouchMode: () -> Void
    let onToggleKeyboard: () -> Void
    let onOpenSessionMenu: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 5) {
                // Step-by-step Back button
                Button(action: onStepBack) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(OpenUUTheme.textPrimary)
                        .frame(width: 26, height: 26)
                        .background(
                            OpenUUTheme.elevated,
                            in: RoundedRectangle(cornerRadius: 7, style: .continuous)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .stroke(OpenUUTheme.hairline, lineWidth: 0.5)
                        )
                }
                .buttonStyle(.plain)
                .accessibilityLabel("返回上一步")

                // Left [应用] pill
                if selectedWindowID != 0 {
                    Button(action: onOpenApps) {
                        HStack(spacing: 4) {
                            Image(systemName: "square.grid.2x2")
                                .font(.system(size: 11.5, weight: .semibold))
                            Text("应用")
                                .font(.system(size: 11.5, weight: .medium))
                        }
                        .foregroundStyle(showAppLauncher ? OpenUUTheme.background : OpenUUTheme.textPrimary)
                        .padding(.horizontal, 8)
                        .frame(height: 26)
                        .background(
                            showAppLauncher ? OpenUUTheme.primaryCTA : OpenUUTheme.elevated,
                            in: RoundedRectangle(cornerRadius: 7, style: .continuous)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .stroke(showAppLauncher ? OpenUUTheme.primaryCTA : OpenUUTheme.hairline, lineWidth: 0.5)
                        )
                    }
                    .buttonStyle(.plain)
                }

                // Center scrollable browser-style window tabs
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 4) {
                        ForEach(normalWindows) { win in
                            let active = (win.window_id == selectedWindowID)
                            HStack(spacing: 4) {
                                Button {
                                    onSelectWindow(win.window_id)
                                } label: {
                                    Text(win.displayTitle)
                                        .font(.system(size: 11.5, weight: active ? .medium : .regular))
                                        .foregroundStyle(active ? OpenUUTheme.textPrimary : OpenUUTheme.textSecondary)
                                        .lineLimit(1)
                                        .frame(maxWidth: 118, alignment: .leading)
                                }
                                .buttonStyle(.plain)

                                Button {
                                    onCloseWindow(win.window_id)
                                } label: {
                                    Image(systemName: "xmark")
                                        .font(.system(size: 9.5, weight: .bold))
                                        .foregroundStyle(active ? OpenUUTheme.textSecondary : OpenUUTheme.textMuted)
                                        .frame(width: 18, height: 18)
                                        .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("关闭窗口")
                            }
                            .padding(.leading, 8)
                            .padding(.trailing, 4)
                            .frame(height: 26)
                            .background(
                                active ? OpenUUTheme.activeTab : Color.clear,
                                in: RoundedRectangle(cornerRadius: 7, style: .continuous)
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 7, style: .continuous)
                                    .stroke(active ? OpenUUTheme.popoverBorder : Color.clear, lineWidth: 0.5)
                            )
                        }
                    }
                }
                .frame(maxWidth: .infinity)

                // Right compact controls: TouchMode, Keyboard, [● 1ms ▾]
                Button(action: onToggleTouchMode) {
                    HStack(spacing: 3) {
                        Image(systemName: touchMode.systemImage)
                            .font(.system(size: 11, weight: .medium))
                        Text(touchMode.label)
                            .font(.system(size: 11, weight: .medium))
                    }
                    .foregroundStyle(OpenUUTheme.textPrimary)
                    .padding(.horizontal, 7)
                    .frame(height: 26)
                    .background(
                        touchMode == .trackpad ? OpenUUTheme.activeTab : Color.clear,
                        in: RoundedRectangle(cornerRadius: 7, style: .continuous)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .stroke(touchMode == .trackpad ? OpenUUTheme.popoverBorder : OpenUUTheme.hairline, lineWidth: 0.5)
                    )
                }
                .buttonStyle(.plain)

                Button(action: onToggleKeyboard) {
                    Image(systemName: "keyboard")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(showKeyboardDock ? OpenUUTheme.background : OpenUUTheme.textPrimary)
                        .frame(width: 26, height: 26)
                        .background(
                            showKeyboardDock ? OpenUUTheme.primaryCTA : OpenUUTheme.elevated,
                            in: RoundedRectangle(cornerRadius: 7, style: .continuous)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .stroke(showKeyboardDock ? OpenUUTheme.primaryCTA : OpenUUTheme.hairline, lineWidth: 0.5)
                        )
                }
                .buttonStyle(.plain)
                .accessibilityLabel("键盘")

                Button(action: onOpenSessionMenu) {
                    HStack(spacing: 4) {
                        Circle()
                            .fill(OpenUUTheme.liveDot)
                            .frame(width: 6, height: 6)
                        Text(rttText)
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                            .foregroundStyle(OpenUUTheme.textPrimary)
                            .lineLimit(1)
                        Image(systemName: "chevron.down")
                            .font(.system(size: 9.5, weight: .semibold))
                            .foregroundStyle(OpenUUTheme.textSecondary)
                    }
                    .padding(.horizontal, 7)
                    .frame(height: 26)
                    .background(OpenUUTheme.elevated, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .stroke(OpenUUTheme.hairline, lineWidth: 0.5)
                    )
                }
                .buttonStyle(.plain)
                .accessibilityLabel("会话控制菜单")

                if showCollapseButton {
                    Button(action: onCollapse) {
                        Image(systemName: "chevron.up")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(OpenUUTheme.textSecondary)
                            .frame(width: 24, height: 26)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("收起顶部栏")
                }
            }
            .padding(.horizontal, 6)
            .frame(height: 38)
            .background(OpenUUTheme.barBg)

            Rectangle()
                .fill(OpenUUTheme.divider)
                .frame(height: 0.5)
        }
    }
}

// MARK: - App Switcher Sheet & Grid

private struct RemoteAppSwitcherSheet: View {
    @ObservedObject var viewModel: MobileSessionViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("切换远程应用")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(OpenUUTheme.textPrimary)
                Spacer()
                Button("完成") {
                    dismiss()
                }
                .font(.system(size: 13.5, weight: .medium))
                .foregroundStyle(OpenUUTheme.textSecondary)
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 8)

            RemoteAppLauncherView(viewModel: viewModel)
        }
        .background(OpenUUTheme.surface.ignoresSafeArea())
    }
}

private struct RemoteAppLauncherView: View {
    @ObservedObject var viewModel: MobileSessionViewModel
    @State private var searchText = ""

    private var filteredApps: [RemoteAppSummary] {
        let regular = viewModel.remoteApps.filter { $0.bundle_id != OpenUUConstants.fullDesktopBundleID }
        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return regular }
        return regular.filter {
            $0.name.lowercased().contains(q) || $0.bundle_id.lowercased().contains(q)
        }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                HStack(spacing: 8) {
                    HStack(spacing: 6) {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 13))
                            .foregroundStyle(OpenUUTheme.textSecondary)
                        TextField("搜索远程 Mac 应用...", text: $searchText)
                            .font(.system(size: 14))
                            .foregroundStyle(OpenUUTheme.textPrimary)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        if !searchText.isEmpty {
                            Button {
                                searchText = ""
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.system(size: 13))
                                    .foregroundStyle(OpenUUTheme.textMuted)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 9)
                    .background(OpenUUTheme.elevated, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .stroke(OpenUUTheme.hairline, lineWidth: 0.5)
                    )

                    Button {
                        viewModel.refreshRemoteApps()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(OpenUUTheme.textPrimary)
                            .frame(width: 38, height: 38)
                            .background(OpenUUTheme.elevated, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 9, style: .continuous)
                                    .stroke(OpenUUTheme.hairline, lineWidth: 0.5)
                            )
                    }
                    .buttonStyle(.plain)
                }

                // Full Desktop Row
                Button {
                    viewModel.openFullDesktop()
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "desktopcomputer")
                            .font(.system(size: 18, weight: .medium))
                            .foregroundStyle(OpenUUTheme.textPrimary)
                            .frame(width: 38, height: 38)
                            .background(OpenUUTheme.keycap, in: RoundedRectangle(cornerRadius: 8, style: .continuous))

                        VStack(alignment: .leading, spacing: 2) {
                            Text("整台桌面")
                                .font(.system(size: 14.5, weight: .semibold))
                                .foregroundStyle(OpenUUTheme.textPrimary)
                            Text("镜像完整 macOS 主显示器画面")
                                .font(.system(size: 12))
                                .foregroundStyle(OpenUUTheme.textSecondary)
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(OpenUUTheme.textMuted)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 11)
                    .background(OpenUUTheme.elevated, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(OpenUUTheme.popoverBorder, lineWidth: 0.5)
                    )
                }
                .buttonStyle(.plain)

                if filteredApps.isEmpty {
                    Text(viewModel.remoteApps.isEmpty ? "正在获取 Mac 运行中的应用..." : "无匹配应用")
                        .font(.system(size: 13))
                        .foregroundStyle(OpenUUTheme.textSecondary)
                        .padding(.vertical, 28)
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 94), spacing: 8)], spacing: 8) {
                        ForEach(filteredApps) { app in
                            Button {
                                viewModel.openRemoteApp(bundleID: app.bundle_id, appName: app.name)
                            } label: {
                                VStack(spacing: 7) {
                                    ZStack(alignment: .topTrailing) {
                                        if let img = viewModel.appIcons[app.bundle_id] {
                                            Image(uiImage: img)
                                                .resizable()
                                                .interpolation(.high)
                                                .scaledToFit()
                                                .frame(width: 46, height: 46)
                                                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                                        } else {
                                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                                .fill(OpenUUTheme.keycap)
                                                .frame(width: 46, height: 46)
                                                .overlay {
                                                    Image(systemName: "app.fill")
                                                        .font(.system(size: 20))
                                                        .foregroundStyle(OpenUUTheme.textSecondary)
                                                }
                                        }

                                        if app.window_count > 1 {
                                            Text("\(app.window_count)")
                                                .font(.system(size: 10, weight: .bold, design: .monospaced))
                                                .foregroundStyle(OpenUUTheme.background)
                                                .padding(.horizontal, 5)
                                                .padding(.vertical, 1.5)
                                                .background(OpenUUTheme.primaryCTA, in: Capsule())
                                                .offset(x: 6, y: -4)
                                        }
                                    }

                                    Text(app.name)
                                        .font(.system(size: 12, weight: .medium))
                                        .foregroundStyle(OpenUUTheme.textPrimary)
                                        .lineLimit(2)
                                        .multilineTextAlignment(.center)
                                }
                                .frame(maxWidth: .infinity, minHeight: 96)
                                .padding(8)
                                .background(OpenUUTheme.surface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                                        .stroke(OpenUUTheme.hairline, lineWidth: 0.5)
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
    }
}

// MARK: - Session Control Sheet

private struct SessionControlSheet: View {
    @ObservedObject var viewModel: MobileSessionViewModel
    let hostName: String
    let isLandscape: Bool
    let viewportSize: CGSize
    let onPickFile: () -> Void
    let onOpenGestureGuide: () -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                // Header
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(hostName)
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(OpenUUTheme.textPrimary)
                        if !viewModel.linkBadge.isEmpty {
                            Text(viewModel.linkBadge)
                                .font(.system(size: 11.5, design: .monospaced))
                                .foregroundStyle(OpenUUTheme.textSecondary)
                        }
                    }
                    Spacer()
                    Circle()
                        .fill(OpenUUTheme.liveDot)
                        .frame(width: 8, height: 8)
                }

                // Segmented Pickers: Touch Mode & Video Fit Mode
                VStack(spacing: 10) {
                    Picker("操控模式", selection: $viewModel.touchMode) {
                        Text("直触").tag(TouchControlMode.directTouch)
                        Text("触控板").tag(TouchControlMode.trackpad)
                    }
                    .pickerStyle(.segmented)

                    Picker("画面比例", selection: $viewModel.videoFitMode) {
                        Text("适应屏幕").tag(VideoFitMode.fit)
                        Text("铺满全屏").tag(VideoFitMode.fill)
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: viewModel.videoFitMode) { _, mode in
                        viewModel.videoRenderer.setVideoFitMode(mode)
                    }
                }

                // Zoom Stepper Row
                HStack {
                    Text("画面缩放")
                        .font(.system(size: 13.5))
                        .foregroundStyle(OpenUUTheme.textPrimary)
                    Spacer()
                    HStack(spacing: 0) {
                        Button {
                            viewModel.zoomOut()
                        } label: {
                            Image(systemName: "minus")
                                .font(.system(size: 12, weight: .bold))
                                .frame(width: 34, height: 30)
                        }
                        .disabled(viewModel.canvasZoomScale <= 1.01)

                        Button {
                            viewModel.resetZoom()
                        } label: {
                            Text("\(Int((viewModel.canvasZoomScale * 100).rounded()))%")
                                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                                .frame(minWidth: 46, minHeight: 30)
                        }

                        Button {
                            viewModel.zoomIn()
                        } label: {
                            Image(systemName: "plus")
                                .font(.system(size: 12, weight: .bold))
                                .frame(width: 34, height: 30)
                        }
                        .disabled(viewModel.canvasZoomScale >= 4.99)
                    }
                    .foregroundStyle(OpenUUTheme.textPrimary)
                    .background(OpenUUTheme.keycap, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(OpenUUTheme.hairline, lineWidth: 0.5)
                    )
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .background(OpenUUTheme.elevated, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(OpenUUTheme.hairline, lineWidth: 0.5)
                )

                // Toggles Card
                VStack(spacing: 0) {
                    sheetToggleRow("接收远程电脑声音", isOn: $viewModel.remoteAudioEnabled)
                    sheetDivider
                    sheetToggleRow("远控时被控 Mac 静音", isOn: $viewModel.muteHostAudio)
                        .disabled(!viewModel.remoteAudioEnabled)
                    sheetDivider
                    sheetToggleRow("固定顶部窗口栏", isOn: $viewModel.pinLandscapeTabBar)
                    if !isLandscape && viewModel.selectedWindowID != 0 {
                        sheetDivider
                        sheetToggleRow("沉浸全屏模式", isOn: $viewModel.manualFullscreen)
                    }
                    sheetDivider
                    sheetToggleRow("帧率诊断 HUD", isOn: $viewModel.showDebugHUD)
                }
                .background(OpenUUTheme.elevated, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(OpenUUTheme.hairline, lineWidth: 0.5)
                )

                // Actions Card
                VStack(spacing: 0) {
                    sheetActionRow(icon: "arrow.up.doc", title: "发送文件", action: onPickFile)
                    sheetDivider
                    sheetActionRow(icon: "doc.on.clipboard", title: "同步剪贴板") {
                        viewModel.pushLocalClipboardToHost(silent: false)
                        dismiss()
                    }
                    if viewModel.selectedWindowID != 0 {
                        sheetDivider
                        sheetActionRow(icon: "arrow.up.left.and.arrow.down.right", title: "调整远程窗口适应屏幕") {
                            let w = Float(min(max(viewportSize.width, 480), 1920))
                            let h = Float(min(max(viewportSize.height, 360), 1440))
                            viewModel.resizeActiveWindow(width: w, height: h)
                            dismiss()
                        }
                        sheetDivider
                        sheetActionRow(icon: "arrow.clockwise", title: "刷新视频关键帧") {
                            viewModel.requestKeyframeNow()
                            dismiss()
                        }
                    }
                    sheetDivider
                    sheetActionRow(icon: "questionmark.circle", title: "手势操作说明", action: onOpenGestureGuide)
                    sheetDivider
                    sheetActionRow(icon: "chevron.left", title: "返回主机列表") {
                        dismiss()
                        viewModel.selectedTab = .connect
                    }
                }
                .background(OpenUUTheme.elevated, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(OpenUUTheme.hairline, lineWidth: 0.5)
                )

                // Destructive Disconnect
                Button {
                    dismiss()
                    viewModel.disconnect()
                } label: {
                    HStack(spacing: 7) {
                        Image(systemName: "power")
                            .font(.system(size: 13.5, weight: .semibold))
                        Text("断开远控连接")
                            .font(.system(size: 14, weight: .semibold))
                    }
                    .foregroundStyle(OpenUUTheme.destructive)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 13)
                    .background(OpenUUTheme.dangerSurface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(OpenUUTheme.dangerBorder, lineWidth: 0.5)
                    )
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 16)
            .padding(.top, 16)
            .padding(.bottom, 26)
        }
        .background(OpenUUTheme.surface.ignoresSafeArea())
    }

    private var sheetDivider: some View {
        Rectangle()
            .fill(OpenUUTheme.divider)
            .frame(height: 0.5)
            .padding(.leading, 12)
    }

    private func sheetToggleRow(_ title: String, isOn: Binding<Bool>) -> some View {
        Toggle(title, isOn: isOn)
            .font(.system(size: 13.5))
            .foregroundStyle(OpenUUTheme.textPrimary)
            .tint(OpenUUTheme.liveDot)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
    }

    private func sheetActionRow(icon: String, title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(OpenUUTheme.textSecondary)
                    .frame(width: 20)
                Text(title)
                    .font(.system(size: 13.5))
                    .foregroundStyle(OpenUUTheme.textPrimary)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 11)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Direct System IME Responder & Multi-Row Simulated Mac Keyboard

private struct DirectRemoteIMEHost: UIViewRepresentable {
    let imeRequested: Bool
    let imeRequestSeq: Int
    let onCommitText: (String) -> Void
    let onBackspace: (Bool) -> Void
    let onReturnKey: () -> Void
    let onComposingPreview: (String) -> Void
    let onEditingChanged: (Bool) -> Void

    func makeUIView(context: Context) -> DirectRemoteIMETextField {
        let tf = DirectRemoteIMETextField()
        applyCallbacks(to: tf)
        return tf
    }

    func updateUIView(_ uiView: DirectRemoteIMETextField, context: Context) {
        applyCallbacks(to: uiView)
        if imeRequested {
            if uiView.lastShownSeq != imeRequestSeq {
                uiView.lastShownSeq = imeRequestSeq
                uiView.wasRequested = true
                DispatchQueue.main.async {
                    if !uiView.isFirstResponder {
                        _ = uiView.becomeFirstResponder()
                    }
                    uiView.ensureCursorAtEndIfIdle()
                }
            }
        } else if uiView.wasRequested || uiView.isFirstResponder {
            uiView.wasRequested = false
            DispatchQueue.main.async {
                if uiView.isFirstResponder {
                    _ = uiView.resignFirstResponder()
                }
            }
        }
    }

    static func dismantleUIView(_ uiView: DirectRemoteIMETextField, coordinator: ()) {
        if uiView.isFirstResponder {
            _ = uiView.resignFirstResponder()
        }
    }

    private func applyCallbacks(to tf: DirectRemoteIMETextField) {
        tf.onCommitText = onCommitText
        tf.onBackspace = onBackspace
        tf.onReturnKey = onReturnKey
        tf.onComposingPreview = onComposingPreview
        tf.onEditingStateChanged = onEditingChanged
    }
}

private final class DirectRemoteIMETextField: UITextField, UITextFieldDelegate {
    private static let sentinel = "\u{200B}\u{200B}\u{200B}\u{200B}"

    var onCommitText: ((String) -> Void)?
    var onBackspace: ((Bool) -> Void)?
    var onReturnKey: (() -> Void)?
    var onComposingPreview: ((String) -> Void)?
    var onEditingStateChanged: ((Bool) -> Void)?

    var lastShownSeq: Int = -1
    var wasRequested: Bool = false
    private var internalMutation: Bool = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        delegate = self
        backgroundColor = .clear
        textColor = .clear
        tintColor = .clear
        autocapitalizationType = .none
        autocorrectionType = .default
        spellCheckingType = .no
        smartQuotesType = .no
        smartDashesType = .no
        smartInsertDeleteType = .no
        returnKeyType = .default
        inputAssistantItem.leadingBarButtonGroups = []
        inputAssistantItem.trailingBarButtonGroups = []
        resetToSentinel()
        addTarget(self, action: #selector(handleEditingChanged), for: .editingChanged)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func deleteBackward() {
        if markedTextRange != nil {
            super.deleteBackward()
            emitMarkedPreview()
            return
        }
        resetToSentinel()
        onBackspace?(false)
    }

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        if markedTextRange != nil {
            return true
        }
        resetToSentinel()
        onReturnKey?()
        return false
    }

    func textFieldDidBeginEditing(_ textField: UITextField) {
        ensureCursorAtEndIfIdle()
        onEditingStateChanged?(true)
    }

    func textFieldDidEndEditing(_ textField: UITextField) {
        onComposingPreview?("")
        onEditingStateChanged?(false)
    }

    func resetToSentinel() {
        internalMutation = true
        defer { internalMutation = false }
        text = Self.sentinel
        let end = endOfDocument
        selectedTextRange = textRange(from: end, to: end)
    }

    func ensureCursorAtEndIfIdle() {
        guard markedTextRange == nil else { return }
        internalMutation = true
        defer { internalMutation = false }
        if (text ?? "").isEmpty {
            text = Self.sentinel
        }
        let end = endOfDocument
        selectedTextRange = textRange(from: end, to: end)
    }

    private func emitMarkedPreview() {
        if let range = markedTextRange {
            let raw = (text(in: range) ?? "").replacingOccurrences(of: "\u{200B}", with: "")
            onComposingPreview?(raw)
        } else {
            onComposingPreview?("")
        }
    }

    @objc private func handleEditingChanged() {
        guard !internalMutation else { return }
        if markedTextRange != nil {
            emitMarkedPreview()
            return
        }
        onComposingPreview?("")

        let raw = text ?? ""
        var sentinelCount = 0
        var committed = ""
        for ch in raw {
            if ch == "\u{200B}" {
                sentinelCount += 1
            } else {
                committed.append(ch)
            }
        }

        if !committed.isEmpty {
            resetToSentinel()
            onCommitText?(committed)
        } else if sentinelCount < 4 {
            let deletes = min(max(4 - sentinelCount, 1), 8)
            resetToSentinel()
            for idx in 0..<deletes {
                onBackspace?(idx > 0 || deletes > 1)
            }
        } else if raw != Self.sentinel {
            resetToSentinel()
        }
    }
}

private enum IOSSimKeyPage: String, CaseIterable, Identifiable {
    case main = "常用按键"
    case combos = "组合键"
    case fkeys = "F1-F12"

    var id: String { rawValue }
}

private struct IOSSimComboDef: Identifiable {
    let keyHint: String
    let subtitle: String
    let keyCode: UInt32
    let modifiers: UInt32
    var id: String { keyHint }
}

private let IOSSimComboRows: [[IOSSimComboDef]] = [
    [
        IOSSimComboDef(keyHint: "⌘A", subtitle: "全选", keyCode: MacKeyCodes.a, modifiers: MacModifiers.command),
        IOSSimComboDef(keyHint: "⌘S", subtitle: "保存", keyCode: MacKeyCodes.s, modifiers: MacModifiers.command),
        IOSSimComboDef(keyHint: "⌘F", subtitle: "查找", keyCode: MacKeyCodes.f, modifiers: MacModifiers.command),
        IOSSimComboDef(keyHint: "⌘R", subtitle: "刷新", keyCode: MacKeyCodes.r, modifiers: MacModifiers.command),
    ],
    [
        IOSSimComboDef(keyHint: "⌘T", subtitle: "新标签", keyCode: MacKeyCodes.t, modifiers: MacModifiers.command),
        IOSSimComboDef(keyHint: "⌘W", subtitle: "关窗口", keyCode: MacKeyCodes.w, modifiers: MacModifiers.command),
        IOSSimComboDef(keyHint: "⌘N", subtitle: "新建", keyCode: MacKeyCodes.n, modifiers: MacModifiers.command),
        IOSSimComboDef(keyHint: "⌘Space", subtitle: "搜索", keyCode: MacKeyCodes.space, modifiers: MacModifiers.command),
    ],
    [
        IOSSimComboDef(keyHint: "⌘Tab", subtitle: "切应用", keyCode: MacKeyCodes.tab, modifiers: MacModifiers.command),
        IOSSimComboDef(keyHint: "⌃←", subtitle: "左桌面", keyCode: MacKeyCodes.left, modifiers: MacModifiers.control),
        IOSSimComboDef(keyHint: "⌃→", subtitle: "右桌面", keyCode: MacKeyCodes.right, modifiers: MacModifiers.control),
        IOSSimComboDef(keyHint: "⌃↑", subtitle: "调度中心", keyCode: MacKeyCodes.up, modifiers: MacModifiers.control),
    ],
]

private struct MacKeyboardAndIMEDock: View {
    @ObservedObject var viewModel: MobileSessionViewModel
    let isIMEActive: Bool
    let composingPreview: String
    let onToggleIME: () -> Void
    let onCloseDock: () -> Void

    @AppStorage("openuu.simKeyboardExpanded") private var isExpanded: Bool = true
    @State private var activePage: IOSSimKeyPage = .main

    var body: some View {
        VStack(spacing: 0) {
            Rectangle()
                .fill(OpenUUTheme.divider)
                .frame(height: 0.5)

            if !isExpanded && !composingPreview.isEmpty {
                HStack {
                    Text("拼音: \(composingPreview)")
                        .font(.system(size: 11.5, weight: .medium, design: .monospaced))
                        .foregroundStyle(OpenUUTheme.liveDot)
                        .lineLimit(1)
                    Spacer()
                }
                .padding(.horizontal, 8)
                .padding(.top, 4)
            }

            if !isExpanded {
                // Collapsed single-row bar (even full-width tap targets, no horizontal scroll)
                HStack(spacing: 4) {
                    IOSSimKeyCap(label: "Esc", height: 36) { rep in
                        viewModel.sendKeyTap(keyCode: MacKeyCodes.escape, isRepeat: rep)
                    }
                    IOSSimKeyCap(label: "Tab", height: 36) { rep in
                        viewModel.sendKeyTap(keyCode: MacKeyCodes.tab, isRepeat: rep)
                    }
                    IOSSimKeyCap(
                        label: "⌘",
                        active: (viewModel.stickyModifiers & MacModifiers.command) != 0,
                        height: 36
                    ) { _ in
                        viewModel.toggleStickyModifier(MacModifiers.command)
                    }
                    IOSSimKeyCap(
                        label: "⌃",
                        active: (viewModel.stickyModifiers & MacModifiers.control) != 0,
                        height: 36
                    ) { _ in
                        viewModel.toggleStickyModifier(MacModifiers.control)
                    }
                    IOSSimKeyCap(
                        label: "⌥",
                        active: (viewModel.stickyModifiers & MacModifiers.option) != 0,
                        height: 36
                    ) { _ in
                        viewModel.toggleStickyModifier(MacModifiers.option)
                    }
                    IOSSimKeyCap(
                        label: "⇧",
                        active: (viewModel.stickyModifiers & MacModifiers.shift) != 0,
                        height: 36
                    ) { _ in
                        viewModel.toggleStickyModifier(MacModifiers.shift)
                    }
                    IOSSimKeyCap(label: "⌫", repeatable: true, height: 36) { rep in
                        viewModel.sendKeyTap(keyCode: MacKeyCodes.delete, isRepeat: rep)
                    }

                    Button(action: onToggleIME) {
                        Image(systemName: isIMEActive ? "keyboard.chevron.compact.down" : "keyboard")
                            .font(.system(size: 13.5, weight: .semibold))
                            .foregroundStyle(isIMEActive ? OpenUUTheme.background : OpenUUTheme.textPrimary)
                            .frame(maxWidth: .infinity)
                            .frame(height: 36)
                            .background(
                                isIMEActive ? OpenUUTheme.primaryCTA : OpenUUTheme.elevated,
                                in: RoundedRectangle(cornerRadius: 7, style: .continuous)
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 7, style: .continuous)
                                    .stroke(isIMEActive ? OpenUUTheme.primaryCTA : OpenUUTheme.popoverBorder, lineWidth: 0.5)
                            )
                    }
                    .buttonStyle(.plain)

                    Button {
                        withAnimation(.easeOut(duration: 0.16)) {
                            isExpanded = true
                        }
                    } label: {
                        HStack(spacing: 2) {
                            Text("展开")
                                .font(.system(size: 11.5, weight: .medium))
                            Image(systemName: "chevron.up")
                                .font(.system(size: 10, weight: .bold))
                        }
                        .foregroundStyle(OpenUUTheme.textPrimary)
                        .padding(.horizontal, 6)
                        .frame(height: 36)
                        .background(OpenUUTheme.elevated, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .stroke(OpenUUTheme.popoverBorder, lineWidth: 0.5)
                        )
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 5)
            } else {
                // Expanded multi-row Mac auxiliary keyboard
                VStack(spacing: 5) {
                    // Header control bar
                    HStack(spacing: 5) {
                        ForEach(IOSSimKeyPage.allCases) { page in
                            let selected = (activePage == page)
                            Button {
                                activePage = page
                            } label: {
                                Text(page.rawValue)
                                    .font(.system(size: 11.5, weight: selected ? .semibold : .regular))
                                    .foregroundStyle(selected ? OpenUUTheme.textPrimary : OpenUUTheme.textSecondary)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 4.5)
                                    .background(
                                        selected ? OpenUUTheme.activeTab : Color.clear,
                                        in: RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    )
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                                            .stroke(selected ? OpenUUTheme.popoverBorder : OpenUUTheme.hairline, lineWidth: 0.5)
                                    )
                            }
                            .buttonStyle(.plain)
                        }

                        if !composingPreview.isEmpty {
                            Text(composingPreview)
                                .font(.system(size: 11, weight: .medium, design: .monospaced))
                                .foregroundStyle(OpenUUTheme.liveDot)
                                .lineLimit(1)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        } else {
                            Spacer(minLength: 2)
                        }

                        Button(action: onToggleIME) {
                            HStack(spacing: 3) {
                                Image(systemName: isIMEActive ? "keyboard.chevron.compact.down" : "keyboard")
                                    .font(.system(size: 11.5, weight: .semibold))
                                Text(isIMEActive ? "收输入法" : "输入法")
                                    .font(.system(size: 11, weight: .medium))
                            }
                            .foregroundStyle(isIMEActive ? OpenUUTheme.background : OpenUUTheme.textPrimary)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4.5)
                            .background(
                                isIMEActive ? OpenUUTheme.primaryCTA : OpenUUTheme.elevated,
                                in: RoundedRectangle(cornerRadius: 6, style: .continuous)
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .stroke(isIMEActive ? OpenUUTheme.primaryCTA : OpenUUTheme.popoverBorder, lineWidth: 0.5)
                            )
                        }
                        .buttonStyle(.plain)

                        Button {
                            withAnimation(.easeOut(duration: 0.16)) {
                                isExpanded = false
                            }
                        } label: {
                            HStack(spacing: 2) {
                                Text("收起")
                                    .font(.system(size: 11, weight: .medium))
                                Image(systemName: "chevron.down")
                                    .font(.system(size: 9.5, weight: .bold))
                            }
                            .foregroundStyle(OpenUUTheme.textPrimary)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 4.5)
                            .background(OpenUUTheme.elevated, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .stroke(OpenUUTheme.hairline, lineWidth: 0.5)
                            )
                        }
                        .buttonStyle(.plain)

                        Button(action: onCloseDock) {
                            Image(systemName: "xmark")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundStyle(OpenUUTheme.textSecondary)
                                .frame(width: 26, height: 26)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }

                    switch activePage {
                    case .main:
                        // Row 1: Esc | Tab | Space | ⌫ | ⌦ | ⏎
                        GeometryReader { geo in
                            let spacing: CGFloat = 5
                            let totalSpacing = spacing * 5
                            let avail = max(geo.size.width - totalSpacing, 60)
                            let unit = avail / 7.15
                            HStack(spacing: spacing) {
                                IOSSimKeyCap(label: "Esc") { rep in
                                    viewModel.sendKeyTap(keyCode: MacKeyCodes.escape, isRepeat: rep)
                                }
                                .frame(width: unit * 1.0)

                                IOSSimKeyCap(label: "Tab") { rep in
                                    viewModel.sendKeyTap(keyCode: MacKeyCodes.tab, isRepeat: rep)
                                }
                                .frame(width: unit * 1.0)

                                IOSSimKeyCap(label: "Space 空格", repeatable: true) { rep in
                                    viewModel.sendKeyTap(keyCode: MacKeyCodes.space, isRepeat: rep)
                                }
                                .frame(width: unit * 1.85)

                                IOSSimKeyCap(label: "⌫", repeatable: true) { rep in
                                    viewModel.sendKeyTap(keyCode: MacKeyCodes.delete, isRepeat: rep)
                                }
                                .frame(width: unit * 1.1)

                                IOSSimKeyCap(label: "⌦", repeatable: true) { rep in
                                    viewModel.sendKeyTap(keyCode: MacKeyCodes.forwardDelete, isRepeat: rep)
                                }
                                .frame(width: unit * 0.95)

                                IOSSimKeyCap(label: "⏎ 回车", emphasized: true) { rep in
                                    viewModel.sendKeyTap(keyCode: MacKeyCodes.returnKey, isRepeat: rep)
                                }
                                .frame(width: unit * 1.25)
                            }
                        }
                        .frame(height: 39)

                        // Row 2: ⌘ | ⌃ | ⌥ | ⇧ | Home | PgUp | ↑ | End (8 equal columns)
                        HStack(spacing: 5) {
                            IOSSimKeyCap(
                                label: "⌘",
                                subtitle: "Cmd",
                                active: (viewModel.stickyModifiers & MacModifiers.command) != 0
                            ) { _ in
                                viewModel.toggleStickyModifier(MacModifiers.command)
                            }
                            IOSSimKeyCap(
                                label: "⌃",
                                subtitle: "Ctrl",
                                active: (viewModel.stickyModifiers & MacModifiers.control) != 0
                            ) { _ in
                                viewModel.toggleStickyModifier(MacModifiers.control)
                            }
                            IOSSimKeyCap(
                                label: "⌥",
                                subtitle: "Opt",
                                active: (viewModel.stickyModifiers & MacModifiers.option) != 0
                            ) { _ in
                                viewModel.toggleStickyModifier(MacModifiers.option)
                            }
                            IOSSimKeyCap(
                                label: "⇧",
                                subtitle: "Shift",
                                active: (viewModel.stickyModifiers & MacModifiers.shift) != 0
                            ) { _ in
                                viewModel.toggleStickyModifier(MacModifiers.shift)
                            }
                            IOSSimKeyCap(label: "Home") { rep in
                                viewModel.sendKeyTap(keyCode: MacKeyCodes.home, isRepeat: rep)
                            }
                            IOSSimKeyCap(label: "PgUp", repeatable: true) { rep in
                                viewModel.sendKeyTap(keyCode: MacKeyCodes.pageUp, isRepeat: rep)
                            }
                            IOSSimKeyCap(label: "↑", emphasized: true, repeatable: true) { rep in
                                viewModel.sendKeyTap(keyCode: MacKeyCodes.up, isRepeat: rep)
                            }
                            IOSSimKeyCap(label: "End") { rep in
                                viewModel.sendKeyTap(keyCode: MacKeyCodes.end, isRepeat: rep)
                            }
                        }

                        // Row 3: ⌘C | ⌘V | ⌘X | ⌘Z | PgDn | ← | ↓ | → (Inverted-T arrows aligned with ↑ above!)
                        HStack(spacing: 5) {
                            IOSSimKeyCap(label: "⌘C", subtitle: "复制") { _ in
                                viewModel.sendKeyTap(keyCode: MacKeyCodes.c, explicitModifiers: MacModifiers.command)
                            }
                            IOSSimKeyCap(label: "⌘V", subtitle: "粘贴") { _ in
                                viewModel.sendKeyTap(keyCode: MacKeyCodes.v, explicitModifiers: MacModifiers.command)
                            }
                            IOSSimKeyCap(label: "⌘X", subtitle: "剪切") { _ in
                                viewModel.sendKeyTap(keyCode: MacKeyCodes.x, explicitModifiers: MacModifiers.command)
                            }
                            IOSSimKeyCap(label: "⌘Z", subtitle: "撤销") { _ in
                                viewModel.sendKeyTap(keyCode: MacKeyCodes.z, explicitModifiers: MacModifiers.command)
                            }
                            IOSSimKeyCap(label: "PgDn", repeatable: true) { rep in
                                viewModel.sendKeyTap(keyCode: MacKeyCodes.pageDown, isRepeat: rep)
                            }
                            IOSSimKeyCap(label: "←", emphasized: true, repeatable: true) { rep in
                                viewModel.sendKeyTap(keyCode: MacKeyCodes.left, isRepeat: rep)
                            }
                            IOSSimKeyCap(label: "↓", emphasized: true, repeatable: true) { rep in
                                viewModel.sendKeyTap(keyCode: MacKeyCodes.down, isRepeat: rep)
                            }
                            IOSSimKeyCap(label: "→", emphasized: true, repeatable: true) { rep in
                                viewModel.sendKeyTap(keyCode: MacKeyCodes.right, isRepeat: rep)
                            }
                        }

                    case .combos:
                        ForEach(Array(IOSSimComboRows.enumerated()), id: \.offset) { _, row in
                            HStack(spacing: 5) {
                                ForEach(row) { item in
                                    IOSSimKeyCap(label: item.keyHint, subtitle: item.subtitle) { _ in
                                        viewModel.sendKeyTap(keyCode: item.keyCode, explicitModifiers: item.modifiers)
                                    }
                                }
                            }
                        }

                    case .fkeys:
                        let row1: [(String, UInt32)] = [
                            ("F1", MacKeyCodes.f1), ("F2", MacKeyCodes.f2), ("F3", MacKeyCodes.f3),
                            ("F4", MacKeyCodes.f4), ("F5", MacKeyCodes.f5), ("F6", MacKeyCodes.f6),
                        ]
                        let row2: [(String, UInt32)] = [
                            ("F7", MacKeyCodes.f7), ("F8", MacKeyCodes.f8), ("F9", MacKeyCodes.f9),
                            ("F10", MacKeyCodes.f10), ("F11", MacKeyCodes.f11), ("F12", MacKeyCodes.f12),
                        ]
                        HStack(spacing: 5) {
                            ForEach(row1, id: \.0) { lbl, code in
                                IOSSimKeyCap(label: lbl) { _ in
                                    viewModel.sendKeyTap(keyCode: code)
                                }
                            }
                        }
                        HStack(spacing: 5) {
                            ForEach(row2, id: \.0) { lbl, code in
                                IOSSimKeyCap(label: lbl) { _ in
                                    viewModel.sendKeyTap(keyCode: code)
                                }
                            }
                        }
                        HStack(spacing: 5) {
                            IOSSimKeyCap(label: "⌘[", subtitle: "后退") { _ in
                                viewModel.sendKeyTap(keyCode: MacKeyCodes.leftBracket, explicitModifiers: MacModifiers.command)
                            }
                            IOSSimKeyCap(label: "⌘]", subtitle: "前进") { _ in
                                viewModel.sendKeyTap(keyCode: MacKeyCodes.rightBracket, explicitModifiers: MacModifiers.command)
                            }
                            IOSSimKeyCap(label: "⌘⇧Z", subtitle: "重做") { _ in
                                viewModel.sendKeyTap(
                                    keyCode: MacKeyCodes.z,
                                    explicitModifiers: MacModifiers.command | MacModifiers.shift
                                )
                            }
                            IOSSimKeyCap(label: "⌘Q", subtitle: "退出应用") { _ in
                                viewModel.sendKeyTap(keyCode: MacKeyCodes.q, explicitModifiers: MacModifiers.command)
                            }
                        }
                    }
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 6)
            }
        }
        .background(OpenUUTheme.barBg)
    }
}

private struct IOSSimKeyCap: View {
    let label: String
    var subtitle: String? = nil
    var active: Bool = false
    var emphasized: Bool = false
    var repeatable: Bool = false
    var height: CGFloat = 39
    let onTrigger: (_ isRepeat: Bool) -> Void

    @State private var isPressed = false
    @State private var repeatTask: Task<Void, Never>?

    var body: some View {
        let bgColor: Color = active
            ? OpenUUTheme.primaryCTA
            : (isPressed ? Color(red: 58 / 255, green: 58 / 255, blue: 68 / 255) : (emphasized ? OpenUUTheme.elevated : OpenUUTheme.keycap))
        let borderColor: Color = active
            ? OpenUUTheme.primaryCTA
            : (emphasized ? OpenUUTheme.popoverBorder : OpenUUTheme.hairline)
        let fgColor: Color = active ? OpenUUTheme.background : OpenUUTheme.textPrimary
        let subColor: Color = active ? OpenUUTheme.background.opacity(0.72) : OpenUUTheme.textSecondary

        VStack(spacing: 1) {
            Text(label)
                .font(.system(size: subtitle == nil ? 12 : 11.5, weight: subtitle == nil ? .medium : .semibold))
                .foregroundStyle(fgColor)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
            if let subtitle {
                Text(subtitle)
                    .font(.system(size: 9))
                    .foregroundStyle(subColor)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: height)
        .background(bgColor, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .stroke(borderColor, lineWidth: 0.5)
        )
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in
                    guard !isPressed else { return }
                    isPressed = true
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    onTrigger(false)
                    if repeatable {
                        repeatTask?.cancel()
                        repeatTask = Task { @MainActor in
                            try? await Task.sleep(for: .milliseconds(360))
                            while !Task.isCancelled {
                                onTrigger(true)
                                try? await Task.sleep(for: .milliseconds(62))
                            }
                        }
                    }
                }
                .onEnded { _ in
                    isPressed = false
                    repeatTask?.cancel()
                    repeatTask = nil
                }
        )
        .onDisappear {
            isPressed = false
            repeatTask?.cancel()
            repeatTask = nil
        }
    }
}

// MARK: - HUD & Gesture Badge

private struct GestureFeedbackBadgeView: View {
    let text: String

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(OpenUUTheme.liveDot)
                .frame(width: 6, height: 6)
            Text(text)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(OpenUUTheme.textPrimary)
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 5)
        .background(
            Capsule().fill(Color.black.opacity(0.80))
        )
        .overlay(
            Capsule().stroke(OpenUUTheme.hairline, lineWidth: 0.5)
        )
    }
}

private struct DebugTelemetryHUDView: View {
    @ObservedObject var viewModel: MobileSessionViewModel

    var body: some View {
        let t = viewModel.videoTelemetry
        VStack(alignment: .leading, spacing: 2.5) {
            HStack(spacing: 8) {
                Text(t.codecName)
                    .font(.system(size: 10.5, weight: .bold, design: .monospaced))
                    .foregroundStyle(OpenUUTheme.liveDot)
                Text("\(t.fps) FPS")
                    .font(.system(size: 10.5, weight: .bold, design: .monospaced))
                    .foregroundStyle(OpenUUTheme.textPrimary)
                Text(String(format: "%.2f Mbps", t.bitrateMbps))
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(OpenUUTheme.textSecondary)
            }
            Text("\(t.encodedWidth)×\(t.encodedHeight) · f=\(t.decodedFrames) · win=\(viewModel.selectedWindowID) · pop=\(viewModel.activePopovers.count)")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(OpenUUTheme.textSecondary)
            if !viewModel.linkBadge.isEmpty {
                Text(viewModel.linkBadge)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(OpenUUTheme.textPrimary)
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.black.opacity(0.78))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(OpenUUTheme.hairline, lineWidth: 0.5)
                )
        )
        .allowsHitTesting(false)
    }
}
