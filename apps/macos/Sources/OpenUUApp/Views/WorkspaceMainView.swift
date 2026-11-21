import AppKit
import SwiftUI

struct WorkspaceMainView: View {
    @StateObject private var state = AppState()
    @State private var showingAddDeviceSheet = false
    @State private var editingDevice: ManagedRemoteDevice?

    var body: some View {
        WorkspaceBodyView(
            state: state,
            deviceBook: state.deviceBook,
            showingAddDeviceSheet: $showingAddDeviceSheet,
            editingDevice: $editingDevice
        )
    }
}

private struct WorkspaceBodyView: View {
    @ObservedObject var state: AppState
    @ObservedObject var deviceBook: DeviceBookStore
    @Binding var showingAddDeviceSheet: Bool
    @Binding var editingDevice: ManagedRemoteDevice?

    var body: some View {
        HStack(spacing: 0) {
            sidebarRail

            Divider()

            VStack(spacing: 0) {
                // Top draggable window bar region
                topToolbarHeader
                    .padding(.horizontal, 22)
                    .padding(.top, 14)
                    .padding(.bottom, 10)

                Divider()

                // Active page content
                Group {
                    switch state.selectedTab {
                    case .remoteHome:
                        RemoteControlHomeView(
                            state: state,
                            deviceBook: deviceBook,
                            onAddDevice: { showingAddDeviceSheet = true }
                        )
                    case .deviceList:
                        DeviceBookListView(
                            state: state,
                            deviceBook: deviceBook,
                            onAddDevice: { showingAddDeviceSheet = true },
                            onEditDevice: { dev in editingDevice = dev }
                        )
                    case .securityQuality:
                        SecurityAndQualityView(state: state)
                    case .networkLogs:
                        NetworkAndLogsView(state: state)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                Divider()

                bottomStatusBar
            }
            .background(Color(nsColor: .windowBackgroundColor))
        }
        .frame(minWidth: 880, minHeight: 590)
        .ignoresSafeArea(.container, edges: .top)
        .onAppear {
            state.refreshPermission()
            state.startDiscovery()
        }
        .sheet(isPresented: $showingAddDeviceSheet) {
            DeviceEditorSheet(
                existing: nil,
                onSave: { alias, target, port, pw, group, fav, notes in
                    state.deviceBook.addOrUpdateDevice(
                        alias: alias,
                        target: target,
                        port: port,
                        savedPassword: pw,
                        groupTag: group,
                        isFavorite: fav,
                        notes: notes
                    )
                    state.probeAllSavedDevicesNow()
                }
            )
        }
        .sheet(item: $editingDevice) { dev in
            DeviceEditorSheet(
                existing: dev,
                onSave: { alias, target, port, pw, group, fav, notes in
                    let saved = state.deviceBook.addOrUpdateDevice(
                        id: dev.id,
                        alias: alias,
                        target: target,
                        port: port,
                        savedPassword: pw,
                        groupTag: group,
                        isFavorite: fav,
                        notes: notes
                    )
                    if let sess = state.sessions[dev.id] {
                        sess.alias = saved.alias
                        sess.target = saved.target
                        sess.port = saved.port
                    }
                    state.probeAllSavedDevicesNow()
                }
            )
        }
        .sheet(isPresented: $state.showingPermissionGuideSheet) {
            HostPermissionGuideSheet(state: state)
        }
    }

    // MARK: - Left Sidebar Navigation Rail (ToDesk / UU远程 Style)

    private var sidebarRail: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Space for macOS traffic-light buttons
            Spacer().frame(height: 34)

            HStack(spacing: 10) {
                Image(nsImage: IconCompositor.brandSquircleIcon)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 36, height: 36)
                    .shadow(color: .black.opacity(0.22), radius: 3, y: 1)
                VStack(alignment: .leading, spacing: 1) {
                    Text("OpenUU")
                        .font(.system(size: 14.5, weight: .bold))
                    Text("工作伴侣，永久免费。")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 14)

            ForEach(SidebarTab.allCases) { tab in
                let isSelected = (state.selectedTab == tab)
                Button {
                    state.selectedTab = tab
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: tab.icon)
                            .font(.system(size: 14, weight: .medium))
                            .frame(width: 20)
                        Text(tab.title)
                            .font(.system(size: 13.5, weight: isSelected ? .semibold : .regular))
                        Spacer()
                        if tab == .deviceList && !deviceBook.devices.isEmpty {
                            let badgeText = state.connectedHostCount > 0
                                ? "\(state.connectedHostCount)/\(deviceBook.devices.count)"
                                : "\(deviceBook.devices.count)"
                            Text(badgeText)
                                .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 1.5)
                                .background(
                                    state.connectedHostCount > 0
                                        ? Color.green.opacity(0.22)
                                        : Color.secondary.opacity(0.16)
                                )
                                .foregroundStyle(state.connectedHostCount > 0 ? .green : .secondary)
                                .clipShape(Capsule())
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .contentShape(RoundedRectangle(cornerRadius: 8))
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(isSelected ? Color.accentColor.opacity(0.16) : Color.clear)
                    )
                    .foregroundStyle(isSelected ? Color.accentColor : Color.primary)
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 10)
            }

            Spacer()

            // Live Global Status Card at bottom of sidebar
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 6) {
                    Circle()
                        .fill(state.isHostRunning ? Color.green : Color.orange.opacity(0.85))
                        .frame(width: 7, height: 7)
                    Text(state.isHostRunning ? "本机被控：已开启" : "本机被控：未开启")
                        .font(.system(size: 11, weight: .medium))
                    Spacer(minLength: 4)
                    if state.isHostRunning {
                        Button("关闭") {
                            state.toggleHostService()
                        }
                        .controlSize(.mini)
                        .buttonStyle(.bordered)
                    } else {
                        Button("开启") {
                            state.toggleHostService()
                        }
                        .controlSize(.mini)
                        .buttonStyle(.borderedProminent)
                    }
                }
                HStack(spacing: 6) {
                    Circle()
                        .fill(state.connectedHostCount > 0 ? Color.blue : Color.gray.opacity(0.5))
                        .frame(width: 7, height: 7)
                    Text("并发远控：\(state.connectedHostCount) 台 · \(state.totalOpenRemoteWindows) 窗")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                if state.connectedHostCount > 0 {
                    Button("全部断开远控") {
                        state.disconnectAllClientSessions()
                    }
                    .controlSize(.mini)
                    .buttonStyle(.bordered)
                    .tint(.red)
                }
            }
            .padding(10)
            .background(Color.primary.opacity(0.045))
            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            .padding(.horizontal, 10)
            .padding(.bottom, 12)
        }
        .frame(width: 198)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.75))
    }

    private var topToolbarHeader: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(state.selectedTab.title)
                    .font(.system(size: 18, weight: .bold))
                Text(headerSubtitle)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if state.selectedTab == .deviceList || state.selectedTab == .remoteHome {
                Button {
                    showingAddDeviceSheet = true
                } label: {
                    Label("添加受控设备", systemImage: "plus.circle.fill")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
    }

    private var headerSubtitle: String {
        switch state.selectedTab {
        case .remoteHome:
            return "局域网与异地自动直连 · 支持单应用无缝窗口与整屏远程桌面"
        case .deviceList:
            return "集中维护所有受控端设备与密码，支持同时连接并操控多台远端 Mac"
        case .securityQuality:
            return "配置编码帧率、虚拟副屏隔离、跨多机剪贴板同步及系统权限"
        case .networkLogs:
            return "配置跨网寻址与中继服务域名，查看实时分级诊断日志"
        }
    }

    private var bottomStatusBar: some View {
        HStack(spacing: 8) {
            Circle()
                .fill((state.isHostRunning || state.connectedHostCount > 0) ? Color.green : Color.gray)
                .frame(width: 7, height: 7)
            Text(state.statusLog)
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer()
            Button("复制诊断日志") {
                state.copyDiagnosticLogs()
            }
            .controlSize(.mini)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 7)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))
    }
}

// ============================================================================
// TAB 1: 远程控制首页 (Dual Hero Cards + Active Multi-Host Dock)
// ============================================================================

struct RemoteControlHomeView: View {
    @ObservedObject var state: AppState
    @ObservedObject var deviceBook: DeviceBookStore
    var onAddDevice: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                // Dual Hero Cards: Left = This Mac (Host), Right = Control Remote Mac (Client)
                HStack(alignment: .top, spacing: 16) {
                    thisDeviceHostCard
                        .frame(maxWidth: .infinity)

                    remoteConnectCard
                        .frame(maxWidth: .infinity)
                }

                // Discovered LAN Devices quick bar
                if !state.discoveredPeers.isEmpty {
                    lanDiscoveryStrip
                }

                // Active Multi-Host Concurrent Control Dock
                if !state.connectedSessions.isEmpty {
                    activeMultiHostDock
                } else if !deviceBook.devices.isEmpty {
                    quickRecentDevicesStrip
                }
            }
            .padding(22)
        }
    }

    private var thisDeviceHostCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("允许控制本机", systemImage: "macwindow.on.rectangle")
                    .font(.system(size: 14.5, weight: .semibold))
                Spacer()
                Button {
                    state.toggleHostService()
                } label: {
                    if state.isHostRunning {
                        HStack(spacing: 5) {
                            Circle()
                                .fill(Color.green)
                                .frame(width: 7, height: 7)
                            Text("被控运行中 · 点击关闭")
                                .font(.system(size: 11.5, weight: .semibold))
                                .foregroundStyle(.green)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Color.green.opacity(0.14))
                        .overlay(
                            Capsule().strokeBorder(Color.green.opacity(0.35), lineWidth: 1)
                        )
                        .clipShape(Capsule())
                    } else {
                        HStack(spacing: 5) {
                            Image(systemName: "power")
                                .font(.system(size: 11, weight: .bold))
                            Text("点击开启被控")
                                .font(.system(size: 12, weight: .semibold))
                        }
                        .foregroundStyle(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 5)
                        .background(Color.accentColor)
                        .clipShape(Capsule())
                        .shadow(color: Color.accentColor.opacity(0.28), radius: 4, y: 1)
                    }
                }
                .buttonStyle(.plain)
            }

            Divider()

            VStack(alignment: .leading, spacing: 5) {
                Text("本机设备代码")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack(spacing: 10) {
                    Text(state.myFormattedDeviceCode)
                        .font(.system(size: 25, weight: .bold, design: .monospaced))
                        .foregroundStyle(.primary)
                        .textSelection(.enabled)
                    Button {
                        state.copyMyDeviceCode()
                    } label: {
                        Image(systemName: "doc.on.doc")
                            .help("复制本机 9 位设备代码")
                    }
                    .buttonStyle(.borderless)
                }
            }

            VStack(alignment: .leading, spacing: 5) {
                Text("本机访问密码（验证码）")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    if state.isHostPasswordRevealed {
                        TextField("密码", text: $state.hostPIN)
                            .font(.system(size: 16, weight: .semibold, design: .monospaced))
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 136)
                            .disabled(state.isHostRunning)
                    } else {
                        Text(String(repeating: "•", count: max(6, state.hostPIN.count)))
                            .font(.system(size: 18, weight: .bold, design: .monospaced))
                            .frame(width: 136, alignment: .leading)
                    }

                    Button {
                        state.isHostPasswordRevealed.toggle()
                    } label: {
                        Image(systemName: state.isHostPasswordRevealed ? "eye.slash" : "eye")
                    }
                    .buttonStyle(.borderless)
                    .help("显示/隐藏密码")

                    if !state.isHostRunning {
                        Menu {
                            Button("刷新 6 位数字验证码") { state.regenerateHostPIN(strong: false) }
                            Button("生成 8 位高强度密码（跨网推荐）") { state.regenerateHostPIN(strong: true) }
                        } label: {
                            Image(systemName: "arrow.clockwise")
                        }
                        .menuStyle(.borderlessButton)
                        .frame(width: 26)
                        .help("更换本机访问密码")
                    }
                }
            }

            if state.isHostRunning {
                HStack(spacing: 8) {
                    Button {
                        state.copyInvitationBundle()
                    } label: {
                        Label("复制代码与密码", systemImage: "square.and.arrow.up")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.green)
                    .controlSize(.large)

                    Button {
                        state.copyMyHostTicket()
                    } label: {
                        Label("直连串", systemImage: "link")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    .help("未部署寻址服务器时，复制 openuu:// 连接串发给对方即可跨网穿透连接")

                    Button {
                        state.toggleHostService()
                    } label: {
                        Text("关闭")
                    }
                    .buttonStyle(.bordered)
                    .tint(.red)
                    .controlSize(.large)
                    .help("停止本机被控服务")
                }
            } else {
                HStack(spacing: 10) {
                    Button {
                        state.requestStartHost()
                    } label: {
                        Label("点击开启被控", systemImage: "power.circle.fill")
                            .font(.system(size: 13.5, weight: .semibold))
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)

                    Button {
                        state.copyInvitationBundle()
                    } label: {
                        Label("复制邀请", systemImage: "square.and.arrow.up")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    .help("复制本机设备代码与访问密码发送给伙伴")
                }
            }

            if !state.hasAllHostPermissions {
                Button {
                    state.openPermissionGuide(startHostWhenReady: !state.isHostRunning)
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "exclamationmark.shield.fill")
                            .font(.caption)
                            .foregroundStyle(.orange)
                        Text("\(state.missingHostPermissionSummary) · 点击引导前往系统设置开启")
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(.orange)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                    }
                }
                .buttonStyle(.plain)
            } else {
                HStack(spacing: 6) {
                    Image(systemName: state.isHostRunning ? "checkmark.shield.fill" : "info.circle")
                        .font(.caption)
                        .foregroundStyle(state.isHostRunning ? .green : .secondary)
                    Text(state.isHostRunning ? state.coordStatusText : "开启后支持异地与局域网设备连入（输错5次自动封禁防爆破）")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    if !state.hostLinkBadge.isEmpty {
                        Text("· \(state.hostLinkBadge)")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.blue)
                    }
                }
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
                .shadow(color: .black.opacity(0.05), radius: 6, y: 2)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(
                    state.isHostRunning ? Color.green.opacity(0.42) : Color.primary.opacity(0.08),
                    lineWidth: state.isHostRunning ? 1.4 : 1
                )
        )
    }

    private var remoteConnectCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("远程控制伙伴设备", systemImage: "paperplane.fill")
                    .font(.system(size: 14.5, weight: .semibold))
                Spacer()
                if !deviceBook.devices.isEmpty {
                    Menu {
                        ForEach(deviceBook.devices) { dev in
                            Button("\(dev.alias) (\(dev.formattedTarget))") {
                                state.quickConnectTarget = DeviceCodeFormatter.formatInput(dev.target)
                                state.quickConnectPort = "\(dev.port)"
                                state.quickConnectPassword = dev.savedPassword
                            }
                        }
                    } label: {
                        Label("从设备簿选择", systemImage: "clock.arrow.circlepath")
                            .font(.caption)
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 5) {
                Text("伙伴设备代码 / 跨网连接串 / IP或域名")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                SmartTargetTextField(
                    placeholder: "例如：601 550 599 或 openuu://… 或 192.168.1.10",
                    text: $state.quickConnectTarget,
                    fontSize: 14.5,
                    onSubmit: {
                        state.connectFromQuickInput(autoOpenDesktop: false)
                    }
                )
            }

            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("访问密码（已保存或已信任免填）")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextField("首次连接请输入对方密码", text: $state.quickConnectPassword)
                        .font(.system(size: 13.5, design: .monospaced))
                        .textFieldStyle(.roundedBorder)
                }

                VStack(alignment: .leading, spacing: 5) {
                    Text("直连端口")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextField("39481", text: $state.quickConnectPort)
                        .font(.system(size: 13.5, design: .monospaced))
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 74)
                }
            }

            HStack(spacing: 10) {
                Button {
                    state.connectFromQuickInput(autoOpenDesktop: false)
                } label: {
                    Label("连接并挑应用", systemImage: "macwindow.badge.plus")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)

                Button {
                    state.connectFromQuickInput(autoOpenDesktop: true)
                } label: {
                    Label("直开远程桌面", systemImage: "display")
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .help("连上后立即弹出对方整台 Mac 桌面窗口")
            }

            Text("连接成功后将自动收录至「设备列表」，支持多台受控机同时在线操控。")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
                .shadow(color: .black.opacity(0.05), radius: 6, y: 2)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
        )
    }

    private var lanDiscoveryStrip: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("同局域网在线设备（<2ms 极速直连）", systemImage: "bolt.horizontal.circle.fill")
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(state.discoveredPeers) { peer in
                        HStack(spacing: 8) {
                            Image(systemName: "desktopcomputer")
                                .foregroundStyle(.green)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(peer.device_name)
                                    .font(.system(size: 12.5, weight: .semibold))
                                Text(peer.preferredIP)
                                    .font(.system(size: 10.5, design: .monospaced))
                                    .foregroundStyle(.secondary)
                            }
                            Button("连接") {
                                state.connectDiscoveredPeer(peer, autoOpenDesktop: false)
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.mini)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(Color(nsColor: .controlBackgroundColor))
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .strokeBorder(Color.green.opacity(0.3), lineWidth: 1)
                        )
                    }
                }
            }
        }
    }

    private var activeMultiHostDock: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("当前并行操控中的设备 (\(state.connectedSessions.count))", systemImage: "rectangle.connected.to.line.below")
                    .font(.system(size: 13.5, weight: .bold))
                Spacer()
                Button("进入设备列表管理全部窗口 ➔") {
                    state.selectedTab = .deviceList
                }
                .buttonStyle(.link)
                .font(.caption)
            }

            ForEach(state.connectedSessions) { sess in
                ActiveSessionQuickPanel(session: sess, onDisconnect: {
                    state.disconnectSession(id: sess.id)
                })
            }
        }
    }

    private var quickRecentDevicesStrip: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("常用受控设备（免输一键连）", systemImage: "star.circle.fill")
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Button("管理全部 (\(deviceBook.devices.count))") {
                    state.selectedTab = .deviceList
                }
                .buttonStyle(.link)
                .font(.caption)
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(deviceBook.devices.prefix(6)) { dev in
                        let presence = deviceBook.presenceByID[dev.id] ?? .offline
                        HStack(spacing: 8) {
                            Circle()
                                .fill(presence.isOnline ? Color.green : Color.gray.opacity(0.45))
                                .frame(width: 8, height: 8)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(dev.alias)
                                    .font(.system(size: 12.5, weight: .semibold))
                                Text(dev.formattedTarget)
                                    .font(.system(size: 10.5, design: .monospaced))
                                    .foregroundStyle(.secondary)
                            }
                            Button("一键连") {
                                state.connectDevice(dev, autoOpenDesktop: false)
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.mini)
                            Button("桌面") {
                                state.connectDevice(dev, autoOpenDesktop: true)
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.mini)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(Color(nsColor: .controlBackgroundColor))
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
                        )
                    }
                }
            }
        }
    }
}

private struct ActiveSessionQuickPanel: View {
    @ObservedObject var session: RemotePeerSession
    var onDisconnect: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Circle()
                    .fill(session.phase.isConnected ? Color.green : Color.orange)
                    .frame(width: 9, height: 9)
                Text(session.alias)
                    .font(.system(size: 14, weight: .bold))
                if !session.linkBadge.isEmpty {
                    Text(session.linkBadge)
                        .font(.system(size: 11, weight: .semibold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(Color.green.opacity(0.15))
                        .foregroundStyle(.green)
                        .clipShape(Capsule())
                }
                Text("已打开 \(session.openWindowCount) 个窗口")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    session.isAudioMuted.toggle()
                } label: {
                    Label(
                        session.isAudioMuted ? "已静音" : "远端声音",
                        systemImage: session.isAudioMuted ? "speaker.slash.fill" : "speaker.wave.2.fill"
                    )
                }
                .controlSize(.small)
                .help("开关本机接收远端电脑的声音")
                .disabled(!session.phase.isConnected)

                Toggle("被控端静音", isOn: $session.muteHostSpeakers)
                    .toggleStyle(.checkbox)
                    .controlSize(.small)
                    .help("开启后远控播放声音时被控端电脑扬声器自动静音，断开后自动恢复")
                    .disabled(!session.phase.isConnected || session.isAudioMuted)

                Button("刷新应用") {
                    session.refreshApps()
                }
                .controlSize(.small)
                .disabled(!session.phase.isConnected)
                Button("整屏桌面") {
                    session.openFullDesktop()
                }
                .controlSize(.small)
                .disabled(!session.phase.isConnected)
                Button("断开") {
                    onDisconnect()
                }
                .controlSize(.small)
                .buttonStyle(.bordered)
                .tint(.red)
            }

            if session.phase.isConnecting {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(session.statusMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else if !session.remoteApps.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(session.remoteApps) { app in
                            Button {
                                session.openApp(app)
                            } label: {
                                HStack(spacing: 6) {
                                    if let icon = session.compositedIcons[app.bundle_id] {
                                        Image(nsImage: icon)
                                            .resizable()
                                            .frame(width: 22, height: 22)
                                    } else {
                                        Image(systemName: "app.fill")
                                    }
                                    Text(app.name)
                                        .font(.system(size: 12, weight: .medium))
                                }
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .background(Color.accentColor.opacity(0.1))
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
        .padding(14)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.green.opacity(0.32), lineWidth: 1)
        )
    }
}

// ============================================================================
// TAB 2: 设备列表 (Multi-Host Device Book + Concurrent App Launcher)
// ============================================================================

struct DeviceBookListView: View {
    private static let defaultDrawerHeight: CGFloat = 215
    private static let collapsedDrawerHeight: CGFloat = 41
    private static let minTopContentHeight: CGFloat = 100
    private static let resizeHandleHeight: CGFloat = 8

    @ObservedObject var state: AppState
    @ObservedObject var deviceBook: DeviceBookStore
    var onAddDevice: () -> Void
    var onEditDevice: (ManagedRemoteDevice) -> Void

    @State private var searchText: String = ""
    @State private var selectedFilter: String = "全部"
    @AppStorage("openuu.client.multiHostDrawerHeight") private var drawerHeight: Double = 215
    @AppStorage("openuu.client.multiHostDrawerLastExpandedHeight") private var lastExpandedDrawerHeight: Double = 215
    @State private var dragStartHeight: CGFloat?

    private var filterOptions: [String] {
        var base = ["全部", "星标", "已连接"]
        let customGroups = Set(deviceBook.devices.map(\.groupTag)).union(DeviceBookStore.defaultGroups)
        for g in ["常用", "办公", "家里", "服务器"] where customGroups.contains(g) {
            base.append(g)
        }
        for g in customGroups.sorted() where !base.contains(g) && !g.isEmpty {
            base.append(g)
        }
        return base
    }

    private var filteredDevices: [ManagedRemoteDevice] {
        deviceBook.devices.filter { dev in
            let matchesGroup: Bool = switch selectedFilter {
            case "全部": true
            case "星标": dev.isFavorite
            case "已连接": state.sessions[dev.id]?.phase.isConnected == true
            default: dev.groupTag == selectedFilter
            }
            guard matchesGroup else { return false }
            let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if q.isEmpty { return true }
            let qNoSpace = String(q.filter { !$0.isWhitespace })
            return dev.alias.lowercased().contains(q) ||
                   dev.target.lowercased().contains(q) ||
                   dev.target.lowercased().contains(qNoSpace) ||
                   dev.formattedTarget.lowercased().contains(q) ||
                   dev.notes.lowercased().contains(q) ||
                   dev.groupTag.lowercased().contains(q)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Search & Group Filter Bar
            HStack(spacing: 10) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                    TextField("搜索备注名 / 设备码 / IP...", text: $searchText)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12.5))
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .frame(width: 220)
                .background(Color(nsColor: .controlBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.1), lineWidth: 1))

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(filterOptions, id: \.self) { opt in
                            let active = (selectedFilter == opt)
                            Button {
                                selectedFilter = opt
                            } label: {
                                Text(opt)
                                    .font(.system(size: 12, weight: active ? .semibold : .regular))
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 5)
                                    .background(active ? Color.accentColor : Color.primary.opacity(0.06))
                                    .foregroundStyle(active ? Color.white : Color.primary)
                                    .clipShape(Capsule())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                Spacer()

                Button {
                    state.probeAllSavedDevicesNow()
                } label: {
                    Label("刷新在线状态", systemImage: "arrow.clockwise")
                }
                .controlSize(.small)
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 12)

            Divider()

            // Split Region: Device Grid + Resizable Bottom Multi-Host Concurrent App Launcher
            GeometryReader { geo in
                let maxDrawerHeight = max(
                    Self.collapsedDrawerHeight,
                    geo.size.height - Self.minTopContentHeight - Self.resizeHandleHeight
                )
                let effectiveDrawerHeight = min(
                    max(CGFloat(drawerHeight), Self.collapsedDrawerHeight),
                    maxDrawerHeight
                )
                let isCollapsed = effectiveDrawerHeight <= Self.collapsedDrawerHeight + 6

                VStack(spacing: 0) {
                    // Device Grid
                    Group {
                        if filteredDevices.isEmpty {
                            VStack(spacing: 12) {
                                Spacer()
                                Image(systemName: "laptopcomputer.badge.plus")
                                    .font(.system(size: 40))
                                    .foregroundStyle(.secondary.opacity(0.6))
                                Text(deviceBook.devices.isEmpty ? "尚未添加受控设备" : "没有匹配的设备")
                                    .font(.headline)
                                Text("将家里、公司或服务器的 Mac 添加到设备列表，保存备注名与密码后即可随时一键并发操控。")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .multilineTextAlignment(.center)
                                    .frame(maxWidth: 380)
                                Button {
                                    onAddDevice()
                                } label: {
                                    Label("添加第一台受控设备", systemImage: "plus")
                                }
                                .buttonStyle(.borderedProminent)
                                Spacer()
                            }
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                        } else {
                            ScrollView {
                                LazyVGrid(columns: [GridItem(.adaptive(minimum: 285, maximum: 420), spacing: 14)], spacing: 14) {
                                    ForEach(filteredDevices) { dev in
                                        ManagedDeviceCardView(
                                            device: dev,
                                            session: state.sessions[dev.id],
                                            onlineState: deviceBook.presenceByID[dev.id] ?? .offline,
                                            isSelectedSession: state.selectedSessionID == dev.id,
                                            onConnectApps: {
                                                state.connectDevice(dev, autoOpenDesktop: false)
                                            },
                                            onConnectDesktop: {
                                                if let s = state.sessions[dev.id], s.phase.isConnected {
                                                    s.openFullDesktop()
                                                } else {
                                                    state.connectDevice(dev, autoOpenDesktop: true)
                                                }
                                            },
                                            onSelectSession: {
                                                state.selectedSessionID = dev.id
                                            },
                                            onDisconnect: {
                                                state.disconnectSession(id: dev.id)
                                            },
                                            onToggleStar: {
                                                deviceBook.toggleFavorite(id: dev.id)
                                            },
                                            onEdit: {
                                                onEditDevice(dev)
                                            },
                                            onDelete: {
                                                state.deleteManagedDevice(dev)
                                            }
                                        )
                                    }
                                }
                                .padding(20)
                            }
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                    }
                    .clipped()

                    // Bottom Docked Multi-Host Concurrent App Launcher
                    if !state.connectedSessions.isEmpty {
                        DrawerResizeHandle(
                            height: Self.resizeHandleHeight,
                            onDragChanged: { deltaY in
                                let start = dragStartHeight ?? effectiveDrawerHeight
                                if dragStartHeight == nil {
                                    dragStartHeight = start
                                }
                                let updated = min(
                                    max(start - deltaY, Self.collapsedDrawerHeight),
                                    maxDrawerHeight
                                )
                                drawerHeight = Double(updated)
                                if updated > Self.collapsedDrawerHeight + 24 {
                                    lastExpandedDrawerHeight = Double(updated)
                                }
                            },
                            onDragEnded: {
                                dragStartHeight = nil
                            },
                            onDoubleClick: {
                                withAnimation(.easeInOut(duration: 0.18)) {
                                    let target = min(Self.defaultDrawerHeight, maxDrawerHeight)
                                    drawerHeight = Double(target)
                                    lastExpandedDrawerHeight = Double(target)
                                }
                            }
                        )

                        MultiHostAppDrawerView(
                            state: state,
                            isCollapsed: isCollapsed,
                            onToggleCollapse: {
                                withAnimation(.easeInOut(duration: 0.18)) {
                                    if isCollapsed {
                                        let restored = min(
                                            max(CGFloat(lastExpandedDrawerHeight), 140),
                                            maxDrawerHeight
                                        )
                                        drawerHeight = Double(restored)
                                    } else {
                                        lastExpandedDrawerHeight = Double(effectiveDrawerHeight)
                                        drawerHeight = Double(Self.collapsedDrawerHeight)
                                    }
                                }
                            },
                            onHeaderDragChanged: { deltaY in
                                let start = dragStartHeight ?? effectiveDrawerHeight
                                if dragStartHeight == nil {
                                    dragStartHeight = start
                                }
                                let updated = min(
                                    max(start - deltaY, Self.collapsedDrawerHeight),
                                    maxDrawerHeight
                                )
                                drawerHeight = Double(updated)
                                if updated > Self.collapsedDrawerHeight + 24 {
                                    lastExpandedDrawerHeight = Double(updated)
                                }
                            },
                            onHeaderDragEnded: {
                                dragStartHeight = nil
                            }
                        )
                        .frame(height: effectiveDrawerHeight)
                        .clipped()
                    }
                }
            }
        }
    }
}

private struct ManagedDeviceCardView: View {
    let device: ManagedRemoteDevice
    var session: RemotePeerSession?
    let onlineState: DeviceOnlineState
    let isSelectedSession: Bool
    var onConnectApps: () -> Void
    var onConnectDesktop: () -> Void
    var onSelectSession: () -> Void
    var onDisconnect: () -> Void
    var onToggleStar: () -> Void
    var onEdit: () -> Void
    var onDelete: () -> Void

    private var isConnected: Bool { session?.phase.isConnected == true }
    private var isConnecting: Bool { session?.phase.isConnecting == true }

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack(alignment: .top, spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(isConnected ? Color.green.opacity(0.16) : Color.accentColor.opacity(0.1))
                        .frame(width: 38, height: 38)
                    Image(systemName: "desktopcomputer")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(isConnected ? Color.green : Color.accentColor)
                }

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(device.alias)
                            .font(.system(size: 14.5, weight: .bold))
                            .lineLimit(1)
                        Text(device.groupTag)
                            .font(.system(size: 10, weight: .medium))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1.5)
                            .background(Color.secondary.opacity(0.14))
                            .clipShape(Capsule())
                    }
                    Text(device.formattedTarget)
                        .font(.system(size: 11.5, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer()

                Button {
                    onToggleStar()
                } label: {
                    Image(systemName: device.isFavorite ? "star.fill" : "star")
                        .foregroundStyle(device.isFavorite ? Color.yellow : Color.secondary.opacity(0.5))
                }
                .buttonStyle(.plain)

                Menu {
                    Button("编辑备注与保存密码", action: onEdit)
                    Button("复制设备地址/代码") {
                        let pb = NSPasteboard.general
                        pb.clearContents()
                        pb.setString(device.target, forType: .string)
                    }
                    Divider()
                    Button("从设备列表删除", role: .destructive, action: onDelete)
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .foregroundStyle(.secondary)
                }
                .menuStyle(.borderlessButton)
                .frame(width: 20)
            }

            // Status & Notes row
            HStack(spacing: 6) {
                if isConnected {
                    Circle().fill(Color.green).frame(width: 7, height: 7)
                    Text("操控中 · \(session?.linkBadge ?? "已连接")")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.green)
                } else if isConnecting {
                    ProgressView().controlSize(.mini)
                    Text("正在连接穿透中...")
                        .font(.system(size: 11))
                        .foregroundStyle(.orange)
                } else {
                    Circle()
                        .fill(onlineState.isOnline ? Color.green : Color.gray.opacity(0.45))
                        .frame(width: 7, height: 7)
                    Text(onlineState.label)
                        .font(.system(size: 11))
                        .foregroundStyle(onlineState.isOnline ? .green : .secondary)
                }
                if !device.savedPassword.isEmpty && !isConnected {
                    Text("· 已记住密码")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if !device.notes.isEmpty {
                    Text(device.notes)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            // Action Buttons
            HStack(spacing: 8) {
                if isConnected {
                    Button {
                        onSelectSession()
                    } label: {
                        Label("挑应用 (\(session?.remoteApps.count ?? 0))", systemImage: "square.grid.2x2")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)

                    Button("远程桌面", action: onConnectDesktop)
                        .buttonStyle(.bordered)
                        .controlSize(.small)

                    Button("断开", action: onDisconnect)
                        .buttonStyle(.bordered)
                        .tint(.red)
                        .controlSize(.small)
                } else {
                    Button {
                        onConnectApps()
                    } label: {
                        Label(isConnecting ? "重连" : "一键连接", systemImage: "bolt.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)

                    Button {
                        onConnectDesktop()
                    } label: {
                        Label("远程桌面", systemImage: "display")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                    Button("编辑", action: onEdit)
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(
                    isConnected
                        ? (isSelectedSession ? Color.accentColor : Color.green.opacity(0.45))
                        : Color.primary.opacity(0.08),
                    lineWidth: isSelectedSession && isConnected ? 1.8 : 1
                )
        )
    }
}

private struct DrawerResizeHandle: View {
    let height: CGFloat
    var onDragChanged: (CGFloat) -> Void
    var onDragEnded: () -> Void
    var onDoubleClick: () -> Void

    @State private var isHovering = false
    @State private var isDragging = false

    private var isActive: Bool { isHovering || isDragging }

    var body: some View {
        ZStack {
            Color(nsColor: .controlBackgroundColor)
                .opacity(isActive ? 0.95 : 0.75)

            VStack(spacing: 0) {
                Rectangle()
                    .fill(isActive ? Color.accentColor.opacity(0.65) : Color(nsColor: .separatorColor))
                    .frame(height: 1)
                Spacer(minLength: 0)
            }

            Capsule()
                .fill(isActive ? Color.accentColor.opacity(0.85) : Color.secondary.opacity(0.35))
                .frame(width: 36, height: 3.5)
        }
        .frame(maxWidth: .infinity)
        .frame(height: height)
        .contentShape(Rectangle())
        .background(VerticalResizeCursorOverlay())
        .onHover { hovering in
            isHovering = hovering
        }
        .onTapGesture(count: 2) {
            onDoubleClick()
        }
        .gesture(
            DragGesture(minimumDistance: 1, coordinateSpace: .global)
                .onChanged { value in
                    isDragging = true
                    NSCursor.resizeUpDown.set()
                    onDragChanged(value.translation.height)
                }
                .onEnded { _ in
                    isDragging = false
                    if !isHovering {
                        NSCursor.arrow.set()
                    }
                    onDragEnded()
                }
        )
        .help("上下拖拽自由调节并行操控工作台高度（双击恢复默认高度）")
    }
}

private struct VerticalResizeCursorOverlay: NSViewRepresentable {
    func makeNSView(context: Context) -> ResizeCursorNSView {
        ResizeCursorNSView()
    }

    func updateNSView(_ nsView: ResizeCursorNSView, context: Context) {
        nsView.window?.invalidateCursorRects(for: nsView)
    }

    final class ResizeCursorNSView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? {
            nil
        }

        override func resetCursorRects() {
            addCursorRect(bounds, cursor: .resizeUpDown)
        }
    }
}

private struct MultiHostAppDrawerView: View {
    @ObservedObject var state: AppState
    var isCollapsed: Bool = false
    var onToggleCollapse: (() -> Void)?
    var onHeaderDragChanged: ((CGFloat) -> Void)?
    var onHeaderDragEnded: (() -> Void)?

    private var activeSession: RemotePeerSession? {
        if let sel = state.selectedSessionID, let s = state.sessions[sel],
           (s.phase.isConnected || s.phase.isConnecting) {
            return s
        }
        return state.connectedSessions.first
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Multi-Host Switcher Tab Bar
            HStack(spacing: 8) {
                Text("并行操控工作台:")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 2)
                    .contentShape(Rectangle())
                    .background(VerticalResizeCursorOverlay())
                    .gesture(
                        DragGesture(minimumDistance: 2, coordinateSpace: .global)
                            .onChanged { value in
                                NSCursor.resizeUpDown.set()
                                onHeaderDragChanged?(value.translation.height)
                            }
                            .onEnded { _ in
                                onHeaderDragEnded?()
                            }
                    )
                    .help("上下拖拽调节工作台高度")

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(state.connectedSessions) { sess in
                            let selected = (activeSession?.id == sess.id)
                            Button {
                                state.selectedSessionID = sess.id
                            } label: {
                                HStack(spacing: 5) {
                                    Circle()
                                        .fill(sess.phase.isConnected ? Color.green : Color.orange)
                                        .frame(width: 7, height: 7)
                                    Text(sess.alias)
                                        .font(.system(size: 12, weight: selected ? .bold : .medium))
                                    if !sess.linkBadge.isEmpty {
                                        Text(sess.linkBadge)
                                            .font(.system(size: 10))
                                            .foregroundStyle(selected ? .white.opacity(0.9) : .secondary)
                                    }
                                }
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .background(selected ? Color.accentColor : Color.primary.opacity(0.07))
                                .foregroundStyle(selected ? Color.white : Color.primary)
                                .clipShape(Capsule())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                Spacer()

                if let active = activeSession, !isCollapsed {
                    Button("刷新应用列表") {
                        active.refreshApps()
                    }
                    .controlSize(.mini)
                }

                if let onToggleCollapse {
                    Button {
                        onToggleCollapse()
                    } label: {
                        Image(systemName: isCollapsed ? "chevron.up" : "chevron.down")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: 22, height: 20)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(isCollapsed ? "展开并行操控工作台" : "收起并行操控工作台")
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 8)
            .fixedSize(horizontal: false, vertical: true)
            .background(Color(nsColor: .controlBackgroundColor).opacity(0.8))

            if !isCollapsed {
                Divider()

                if let active = activeSession {
                    SessionAppGridContent(session: active)
                        .frame(maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
                        .clipped()
                }
            }
        }
    }
}

private struct SessionAppGridContent: View {
    @ObservedObject var session: RemotePeerSession

    var body: some View {
        if session.phase.isConnecting {
            HStack(spacing: 10) {
                Spacer()
                ProgressView()
                Text("正在连接 \(session.alias)：\(session.statusMessage)")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .frame(maxHeight: .infinity)
        } else if session.remoteApps.isEmpty {
            HStack {
                Spacer()
                Text("正在加载 \(session.alias) 上的可共享应用列表（请确保被控端已授权屏幕录制权限）...")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .frame(maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 220, maximum: 300), spacing: 10)], spacing: 10) {
                    ForEach(session.remoteApps) { app in
                        HStack(spacing: 10) {
                            if let icon = session.compositedIcons[app.bundle_id] {
                                Image(nsImage: icon)
                                    .resizable()
                                    .frame(width: 28, height: 28)
                            } else {
                                Image(systemName: "app.dashed")
                                    .font(.title3)
                            }
                            VStack(alignment: .leading, spacing: 1) {
                                Text(app.name)
                                    .font(.system(size: 12.5, weight: .semibold))
                                    .lineLimit(1)
                                Text("\(app.window_count) 个窗口")
                                    .font(.system(size: 10.5))
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("打开") {
                                session.openApp(app)
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.mini)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .background(Color(nsColor: .controlBackgroundColor))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.07), lineWidth: 1))
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 10)
            }
        }
    }
}

// ============================================================================
// Add / Edit Managed Remote Device Modal Sheet
// ============================================================================

struct DeviceEditorSheet: View {
    let existing: ManagedRemoteDevice?
    var onSave: (_ alias: String, _ target: String, _ port: UInt16, _ password: String, _ group: String, _ isFav: Bool, _ notes: String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var alias: String
    @State private var target: String
    @State private var portText: String
    @State private var savedPassword: String
    @State private var groupTag: String
    @State private var isFavorite: Bool
    @State private var notes: String

    init(
        existing: ManagedRemoteDevice?,
        onSave: @escaping (_ alias: String, _ target: String, _ port: UInt16, _ password: String, _ group: String, _ isFav: Bool, _ notes: String) -> Void
    ) {
        self.existing = existing
        self.onSave = onSave
        _alias = State(initialValue: existing?.alias ?? "")
        _target = State(initialValue: DeviceCodeFormatter.formatInput(existing?.target ?? ""))
        _portText = State(initialValue: "\(existing?.port ?? 39481)")
        _savedPassword = State(initialValue: existing?.savedPassword ?? "")
        _groupTag = State(initialValue: existing?.groupTag ?? "常用")
        _isFavorite = State(initialValue: existing?.isFavorite ?? false)
        _notes = State(initialValue: existing?.notes ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(existing == nil ? "添加受控端设备" : "编辑受控端设备")
                .font(.system(size: 16, weight: .bold))

            VStack(alignment: .leading, spacing: 6) {
                Text("设备备注名称")
                    .font(.caption).foregroundStyle(.secondary)
                TextField("例如：家里 Mac mini / 公司 MacBook Pro / 工作室主机", text: $alias)
                    .textFieldStyle(.roundedBorder)
            }

            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("设备代码 / openuu://直连串 / IP或域名")
                        .font(.caption).foregroundStyle(.secondary)
                    SmartTargetTextField(
                        placeholder: "例如：601 550 599 或 192.168.1.20",
                        text: $target,
                        fontSize: 13
                    )
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("端口")
                        .font(.caption).foregroundStyle(.secondary)
                    TextField("39481", text: $portText)
                        .font(.system(size: 13, design: .monospaced))
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 72)
                }
            }

            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("保存访问密码（保存后一键免输连接）")
                        .font(.caption).foregroundStyle(.secondary)
                    TextField("输入被控端访问密码 / PIN", text: $savedPassword)
                        .font(.system(size: 13, design: .monospaced))
                        .textFieldStyle(.roundedBorder)
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("所属分组")
                        .font(.caption).foregroundStyle(.secondary)
                    Picker("", selection: $groupTag) {
                        ForEach(DeviceBookStore.defaultGroups, id: \.self) { g in
                            Text(g).tag(g)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 100)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("备注说明（可选）")
                    .font(.caption).foregroundStyle(.secondary)
                TextField("例如：主力微信挂机 / 编译服务器", text: $notes)
                    .textFieldStyle(.roundedBorder)
            }

            Toggle("星标置顶到常用列表首位", isOn: $isFavorite)
                .toggleStyle(.checkbox)

            Divider()

            HStack {
                Spacer()
                Button("取消") {
                    dismiss()
                }
                Button("保存设备") {
                    let p = UInt16(portText) ?? 39481
                    let cleanTarget = DeviceCodeFormatter.sanitizeForUse(target)
                    onSave(alias, cleanTarget, p, savedPassword, groupTag, isFavorite, notes)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(DeviceCodeFormatter.sanitizeForUse(target).isEmpty)
            }
        }
        .padding(22)
        .frame(width: 460)
    }
}

// ============================================================================
// Host System Permissions Check & Onboarding Guide Sheet
// ============================================================================

private struct HostPermissionGuideSheet: View {
    @ObservedObject var state: AppState
    @State private var isChecking = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color.accentColor.opacity(0.14))
                        .frame(width: 44, height: 44)
                    Image(systemName: "lock.shield.fill")
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                }

                VStack(alignment: .leading, spacing: 3) {
                    Text("开启被控需要授予系统权限")
                        .font(.system(size: 16, weight: .bold))
                    Text("请前往 macOS「系统设置 ➔ 隐私与安全性」开启以下权限，全部就绪后将自动启动被控服务。")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            VStack(spacing: 10) {
                permissionCard(
                    granted: state.hasEffectiveScreenRecordingPermission,
                    icon: "rectangle.dashed.badge.record",
                    title: "屏幕录制权限",
                    subtitle: "用于捕获你共享的单个应用窗口或整屏桌面画面",
                    actionTitle: "去系统设置开启",
                    onOpenSettings: {
                        state.openScreenRecordingSettings()
                    }
                )

                permissionCard(
                    granted: state.hasAccessibilityPermission,
                    icon: "cursorarrow.click.2",
                    title: "辅助功能权限",
                    subtitle: "用于接收控制端的鼠标点击、滚轮、快捷键与中文输入法",
                    actionTitle: "去系统设置开启",
                    onOpenSettings: {
                        state.openAccessibilitySettings()
                    }
                )
            }

            if !state.permissionCheckFeedback.isEmpty {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .font(.system(size: 13))
                        .padding(.top, 1)
                    Text(state.permissionCheckFeedback)
                        .font(.system(size: 12))
                        .foregroundStyle(.primary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
                .padding(10)
                .background(Color.orange.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            } else {
                HStack(spacing: 6) {
                    Image(systemName: "info.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("提示：首次勾选「屏幕录制」后，若系统提示退出并重开，重启 OpenUU 即可立即生效。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Divider()

            HStack(spacing: 10) {
                Button("取消") {
                    state.dismissPermissionGuide()
                }

                if !state.hasEffectiveScreenRecordingPermission && !state.permissionCheckFeedback.isEmpty {
                    Button("重启应用生效") {
                        state.relaunchApplication()
                    }
                    .buttonStyle(.bordered)
                }

                Spacer()

                if !state.hasAllHostPermissions {
                    Button("打开待开启项设置") {
                        state.openNextMissingPermissionSettings()
                    }
                    .buttonStyle(.bordered)
                }

                Button {
                    isChecking = true
                    Task { @MainActor in
                        await state.recheckPermissionsAndStartIfReady()
                        isChecking = false
                    }
                } label: {
                    HStack(spacing: 6) {
                        if isChecking {
                            ProgressView().controlSize(.small)
                        }
                        Text(state.pendingStartHostAfterPermission ? "我已开启，立即启动被控" : "重新检测权限")
                    }
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(22)
        .frame(width: 500)
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else { break }
                await state.pollPermissionsInGuideSheet(checkScreenCaptureKit: false)
            }
        }
    }

    private func permissionCard(
        granted: Bool,
        icon: String,
        title: String,
        subtitle: String,
        actionTitle: String,
        onOpenSettings: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 12) {
            Image(systemName: granted ? "checkmark.circle.fill" : icon)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(granted ? Color.green : Color.orange)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(title)
                        .font(.system(size: 13.5, weight: .semibold))
                    Text(granted ? "已开启" : "未开启")
                        .font(.system(size: 10.5, weight: .semibold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1.5)
                        .background(granted ? Color.green.opacity(0.16) : Color.orange.opacity(0.16))
                        .foregroundStyle(granted ? Color.green : Color.orange)
                        .clipShape(Capsule())
                }
                Text(subtitle)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if granted {
                Image(systemName: "checkmark")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.green)
                    .padding(.trailing, 6)
            } else {
                Button(actionTitle, action: onOpenSettings)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
            }
        }
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(
                    granted ? Color.green.opacity(0.35) : Color.orange.opacity(0.32),
                    lineWidth: 1
                )
        )
    }
}

// ============================================================================
// Smart Target TextField (Auto-spaces 9-digit device codes every 3 digits)
// ============================================================================

struct SmartTargetTextField: NSViewRepresentable {
    let placeholder: String
    @Binding var text: String
    var fontSize: CGFloat = 14.5
    var onSubmit: (() -> Void)? = nil

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> NSTextField {
        let tf = NSTextField()
        tf.placeholderString = placeholder
        tf.bezelStyle = .roundedBezel
        tf.isBordered = true
        tf.isBezeled = true
        tf.drawsBackground = true
        tf.usesSingleLineMode = true
        tf.lineBreakMode = .byTruncatingTail
        tf.font = .monospacedSystemFont(ofSize: fontSize, weight: .regular)
        let initialFormatted = DeviceCodeFormatter.formatInput(text)
        tf.stringValue = initialFormatted
        context.coordinator.lastFormattedText = initialFormatted
        tf.delegate = context.coordinator
        return tf
    }

    func updateNSView(_ nsView: NSTextField, context: Context) {
        context.coordinator.parent = self
        nsView.placeholderString = placeholder
        if let editor = nsView.currentEditor() as? NSTextView, editor.hasMarkedText() {
            return
        }
        let formatted = DeviceCodeFormatter.formatInput(text)
        if nsView.stringValue != formatted {
            nsView.stringValue = formatted
            context.coordinator.lastFormattedText = formatted
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: SmartTargetTextField
        var lastFormattedText: String = ""
        private var isApplyingFormat = false

        init(parent: SmartTargetTextField) {
            self.parent = parent
        }

        func controlTextDidChange(_ obj: Notification) {
            guard !isApplyingFormat,
                  let field = obj.object as? NSTextField else { return }

            let editor = (obj.userInfo?["NSFieldEditor"] as? NSTextView)
                ?? (field.currentEditor() as? NSTextView)
            if let editor, editor.hasMarkedText() {
                return
            }

            let raw = field.stringValue
            let cursor = editor?.selectedRange().location ?? (raw as NSString).length
            let (formatted, newCursor) = DeviceCodeFormatter.formatInputWithCursor(
                raw,
                cursorUTF16Offset: cursor,
                previousFormatted: lastFormattedText
            )

            lastFormattedText = formatted
            if formatted != raw {
                isApplyingFormat = true
                field.stringValue = formatted
                if let editor {
                    let clamped = min(max(0, newCursor), (formatted as NSString).length)
                    editor.selectedRange = NSRange(location: clamped, length: 0)
                }
                isApplyingFormat = false
            }

            if parent.text != formatted {
                parent.text = formatted
            }
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            if commandSelector == #selector(NSResponder.insertNewline(_:)) {
                if let onSubmit = parent.onSubmit {
                    onSubmit()
                    return true
                }
            }
            return false
        }
    }
}
