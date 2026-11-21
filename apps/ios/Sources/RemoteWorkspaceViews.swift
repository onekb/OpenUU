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
    @State private var showSessionSheet = false
    @State private var showLastWindowDialog = false
    @State private var showFileImporter = false
    @State private var imeText = ""

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
                        onCollapse: {},
                        onOpenApps: handleOpenAppsTap,
                        onSelectWindow: { viewModel.selectWindow($0) },
                        onCloseWindow: handleCloseWindowTab,
                        onToggleTouchMode: toggleTouchMode,
                        onToggleKeyboard: {
                            withAnimation(.easeInOut(duration: 0.18)) {
                                showKeyboardDock.toggle()
                            }
                        },
                        onOpenSessionMenu: { showSessionSheet = true }
                    )
                }

                ZStack(alignment: .bottomLeading) {
                    if viewModel.selectedWindowID == 0 {
                        RemoteAppLauncherView(viewModel: viewModel)
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
                            onScrollEvent: { nx, ny, dx, dy in
                                viewModel.sendScrollNormalized(nx: nx, ny: ny, deltaX: dx, deltaY: dy)
                            },
                            onGestureBadgeChanged: { badge in
                                viewModel.gestureFeedbackBadge = badge
                            },
                            onToggleKeyboard: {
                                withAnimation(.easeInOut(duration: 0.18)) {
                                    showKeyboardDock.toggle()
                                }
                            },
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
                        imeText: $imeText
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
                        withAnimation(.easeInOut(duration: 0.18)) {
                            showKeyboardDock.toggle()
                        }
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
                // Left [应用] pill
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

// MARK: - Keyboard & Mac Shortcut Dock

private struct MacKeyboardAndIMEDock: View {
    @ObservedObject var viewModel: MobileSessionViewModel
    @Binding var imeText: String

    var body: some View {
        VStack(spacing: 0) {
            Rectangle()
                .fill(OpenUUTheme.divider)
                .frame(height: 0.5)

            HStack(spacing: 8) {
                TextField("输入中英文发送至 Mac...", text: $imeText)
                    .font(.system(size: 14))
                    .foregroundStyle(OpenUUTheme.textPrimary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(OpenUUTheme.elevated, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(OpenUUTheme.hairline, lineWidth: 0.5)
                    )
                    .submitLabel(.send)
                    .onSubmit(commitText)

                let canSend = !imeText.isEmpty
                Button("发送", action: commitText)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(canSend ? OpenUUTheme.background : OpenUUTheme.textMuted)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(
                        canSend ? OpenUUTheme.primaryCTA : OpenUUTheme.hairline,
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                    )
                    .buttonStyle(.plain)
                    .disabled(!canSend)
            }
            .padding(.horizontal, 10)
            .padding(.top, 7)
            .padding(.bottom, 5)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 5) {
                    modifierKey("⌘", bit: MacModifiers.command)
                    modifierKey("⌥", bit: MacModifiers.option)
                    modifierKey("⌃", bit: MacModifiers.control)
                    modifierKey("⇧", bit: MacModifiers.shift)

                    Rectangle().fill(OpenUUTheme.hairline).frame(width: 0.5, height: 18)

                    tapKey("Esc", code: MacKeyCodes.escape)
                    tapKey("Tab", code: MacKeyCodes.tab)
                    tapKey("Space", code: MacKeyCodes.space)
                    tapKey("⌫", code: MacKeyCodes.delete)
                    tapKey("⏎", code: MacKeyCodes.returnKey)
                    tapKey("←", code: MacKeyCodes.left)
                    tapKey("↑", code: MacKeyCodes.up)
                    tapKey("↓", code: MacKeyCodes.down)
                    tapKey("→", code: MacKeyCodes.right)

                    Rectangle().fill(OpenUUTheme.hairline).frame(width: 0.5, height: 18)

                    comboKey("⌘C", code: MacKeyCodes.c, mods: MacModifiers.command)
                    comboKey("⌘V", code: MacKeyCodes.v, mods: MacModifiers.command)
                    comboKey("⌘W", code: MacKeyCodes.w, mods: MacModifiers.command)
                    comboKey("⌘Z", code: MacKeyCodes.z, mods: MacModifiers.command)
                    comboKey("⌘Space", code: MacKeyCodes.space, mods: MacModifiers.command)
                    comboKey("⌘Q", code: MacKeyCodes.q, mods: MacModifiers.command)
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 7)
            }
        }
        .background(OpenUUTheme.barBg)
    }

    private func commitText() {
        guard !imeText.isEmpty else { return }
        viewModel.sendTextCommit(imeText)
        imeText = ""
    }

    private func modifierKey(_ label: String, bit: UInt32) -> some View {
        let active = (viewModel.stickyModifiers & bit) != 0
        return Button {
            viewModel.toggleStickyModifier(bit)
        } label: {
            Text(label)
                .font(.system(size: 12.5, weight: .bold))
                .foregroundStyle(active ? OpenUUTheme.background : OpenUUTheme.textPrimary)
                .frame(minWidth: 34, minHeight: 30)
                .background(
                    active ? OpenUUTheme.primaryCTA : OpenUUTheme.keycap,
                    in: RoundedRectangle(cornerRadius: 6, style: .continuous)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .stroke(active ? OpenUUTheme.primaryCTA : OpenUUTheme.hairline, lineWidth: 0.5)
                )
        }
        .buttonStyle(.plain)
    }

    private func tapKey(_ label: String, code: UInt32) -> some View {
        Button {
            viewModel.sendKeyTap(keyCode: code)
        } label: {
            Text(label)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(OpenUUTheme.textPrimary)
                .padding(.horizontal, 9)
                .frame(minHeight: 30)
                .background(OpenUUTheme.keycap, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .stroke(OpenUUTheme.hairline, lineWidth: 0.5)
                )
        }
        .buttonStyle(.plain)
    }

    private func comboKey(_ label: String, code: UInt32, mods: UInt32) -> some View {
        Button {
            viewModel.sendKeyTap(keyCode: code, explicitModifiers: mods)
        } label: {
            Text(label)
                .font(.system(size: 11.5, weight: .semibold, design: .monospaced))
                .foregroundStyle(OpenUUTheme.textPrimary)
                .padding(.horizontal, 9)
                .frame(minHeight: 30)
                .background(OpenUUTheme.elevated, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .stroke(OpenUUTheme.popoverBorder, lineWidth: 0.5)
                )
        }
        .buttonStyle(.plain)
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
