import SwiftUI
import UIKit
import UniformTypeIdentifiers

enum OpenUUTheme {
    static let background = Color(red: 0.035, green: 0.051, blue: 0.086)      // #090D16
    static let surface = Color(red: 0.067, green: 0.094, blue: 0.153)         // #111827
    static let surfaceElevated = Color(red: 0.102, green: 0.137, blue: 0.212) // #1A2336
    static let border = Color(red: 0.145, green: 0.204, blue: 0.310)          // #25344F
    static let emerald = Color(red: 0.063, green: 0.725, blue: 0.506)         // #10B981
    static let indigo = Color(red: 0.388, green: 0.400, blue: 0.945)          // #6366F1
    static let amber = Color(red: 0.961, green: 0.620, blue: 0.043)           // #F59E0B
    static let rose = Color(red: 0.957, green: 0.247, blue: 0.369)            // #F43F5E
    static let textPrimary = Color(red: 0.945, green: 0.961, blue: 0.976)
    static let textSecondary = Color(red: 0.580, green: 0.639, blue: 0.722)
}

struct MobileMainView: View {
    @ObservedObject var viewModel: MobileSessionViewModel

    private var isImmersiveFullscreen: Bool {
        (viewModel.selectedTab == .remote
            && viewModel.phase.isConnected
            && !viewModel.showAppLauncher
            && viewModel.selectedWindowID != 0)
            && (viewModel.isLandscape || viewModel.manualFullscreen)
    }

    var body: some View {
        GeometryReader { geo in
            let isLandscape = geo.size.width > geo.size.height
            let isImmersiveNow = (
                viewModel.selectedTab == .remote
                    && viewModel.phase.isConnected
                    && !viewModel.showAppLauncher
                    && viewModel.selectedWindowID != 0
            ) && (isLandscape || viewModel.manualFullscreen)

            ZStack(alignment: .top) {
                TabView(selection: $viewModel.selectedTab) {
                    ConnectTabView(viewModel: viewModel)
                        .tabItem {
                            Label(MobileTab.connect.title, systemImage: MobileTab.connect.systemImage)
                        }
                        .tag(MobileTab.connect)

                    DeviceBookTabView(viewModel: viewModel)
                        .tabItem {
                            Label(MobileTab.devices.title, systemImage: MobileTab.devices.systemImage)
                        }
                        .tag(MobileTab.devices)

                    RemoteWorkspaceTabView(
                        viewModel: viewModel,
                        isSuppressedForImmersive: isImmersiveNow
                    )
                    .toolbar(isImmersiveNow ? .hidden : .visible, for: .tabBar)
                    .tabItem {
                        Label(MobileTab.remote.title, systemImage: MobileTab.remote.systemImage)
                    }
                    .tag(MobileTab.remote)

                    SettingsLogsTabView(viewModel: viewModel)
                        .tabItem {
                            Label(MobileTab.settings.title, systemImage: MobileTab.settings.systemImage)
                        }
                        .tag(MobileTab.settings)
                }
                .tint(OpenUUTheme.emerald)
                .opacity(isImmersiveNow ? 0 : 1)
                .allowsHitTesting(!isImmersiveNow)

                if isImmersiveNow {
                    RemoteImmersiveWorkspace(
                        viewModel: viewModel,
                        isLandscape: isLandscape,
                        viewportSize: geo.size
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .ignoresSafeArea(.all)
                    .zIndex(50)
                }

                if let banner = viewModel.notificationBanner {
                    RemoteNotificationBannerView(banner: banner, isCompact: isImmersiveNow) {
                        viewModel.dismissNotificationBanner()
                    } onOpenRemote: {
                        viewModel.selectedTab = .remote
                        viewModel.dismissNotificationBanner()
                    }
                    .frame(maxWidth: isImmersiveNow ? 420 : .infinity)
                    .padding(.horizontal, 14)
                    .padding(.top, isImmersiveNow ? 12 : 8)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .zIndex(100)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .statusBarHidden(isImmersiveNow)
            .persistentSystemOverlays(isImmersiveNow ? .hidden : .automatic)
            .animation(.spring(response: 0.32, dampingFraction: 0.85), value: viewModel.notificationBanner)
            .onAppear {
                viewModel.updateViewportGeometry(size: geo.size, isImmersiveFullscreen: isImmersiveNow)
            }
            .onChange(of: geo.size) { _, newSize in
                let landscapeNow = newSize.width > newSize.height
                let immersiveNow = (
                    viewModel.selectedTab == .remote
                        && viewModel.phase.isConnected
                        && !viewModel.showAppLauncher
                        && viewModel.selectedWindowID != 0
                ) && (landscapeNow || viewModel.manualFullscreen)
                viewModel.updateViewportGeometry(size: newSize, isImmersiveFullscreen: immersiveNow)
            }
            .onChange(of: isImmersiveNow) { _, newVal in
                viewModel.updateViewportGeometry(size: geo.size, isImmersiveFullscreen: newVal)
            }
            .sheet(isPresented: $viewModel.showGestureGuide) {
                GestureGuideSheet()
            }
        }
        .ignoresSafeArea(isImmersiveFullscreen ? .all : [.keyboard])
    }
}

// MARK: - Remote Notification Banner

private struct RemoteNotificationBannerView: View {
    let banner: RemoteNotificationBanner
    var isCompact: Bool = false
    let onDismiss: () -> Void
    let onOpenRemote: () -> Void

    var body: some View {
        HStack(spacing: isCompact ? 10 : 12) {
            Image(systemName: "bell.badge.fill")
                .font(isCompact ? .callout : .title3)
                .foregroundStyle(OpenUUTheme.emerald)

            VStack(alignment: .leading, spacing: 2) {
                Text(banner.title)
                    .font((isCompact ? Font.caption : Font.subheadline).weight(.semibold))
                    .foregroundStyle(OpenUUTheme.textPrimary)
                    .lineLimit(1)
                if !banner.subtitle.isEmpty {
                    Text(banner.subtitle)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(OpenUUTheme.emerald)
                        .lineLimit(1)
                }
                if !banner.body.isEmpty && !isCompact {
                    Text(banner.body)
                        .font(.caption)
                        .foregroundStyle(OpenUUTheme.textSecondary)
                        .lineLimit(2)
                }
            }

            Spacer(minLength: 4)

            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(OpenUUTheme.textSecondary)
                    .padding(6)
            }
        }
        .padding(.horizontal, isCompact ? 12 : 14)
        .padding(.vertical, isCompact ? 8 : 10)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(OpenUUTheme.surfaceElevated.opacity(0.96))
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(OpenUUTheme.emerald.opacity(0.55), lineWidth: 1)
                )
        )
        .shadow(color: .black.opacity(0.45), radius: 12, y: 6)
        .onTapGesture(perform: onOpenRemote)
    }
}

// MARK: - Tab 1: Connect

private struct ConnectTabView: View {
    @ObservedObject var viewModel: MobileSessionViewModel
    @State private var showPinPlaintext = false
    @State private var savedToast: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    brandHeaderCard
                    smartConnectCard
                    discoveredPeersCard
                    if let trusted = viewModel.identity?.trusted_peers, !trusted.isEmpty {
                        trustedPeersQuickCard(trusted)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
            .background(OpenUUTheme.background.ignoresSafeArea())
            .navigationTitle("OpenUU")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private var brandHeaderCard: some View {
        HStack(spacing: 14) {
            Image("BrandIcon")
                .resizable()
                .scaledToFit()
                .frame(width: 50, height: 50)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

            VStack(alignment: .leading, spacing: 4) {
                Text("OpenUU 远控 · 移动客户端")
                    .font(.headline)
                    .foregroundStyle(OpenUUTheme.textPrimary)
                HStack(spacing: 8) {
                    Circle()
                        .fill(statusDotColor)
                        .frame(width: 8, height: 8)
                    Text(statusHeadline)
                        .font(.caption)
                        .foregroundStyle(OpenUUTheme.textSecondary)
                        .lineLimit(1)
                }
            }

            Spacer()

            if let code = viewModel.identity?.formatted_code, !code.isEmpty {
                VStack(alignment: .trailing, spacing: 2) {
                    Text("本机代码")
                        .font(.caption2)
                        .foregroundStyle(OpenUUTheme.textSecondary)
                    Text(code)
                        .font(.caption.monospacedDigit().weight(.semibold))
                        .foregroundStyle(OpenUUTheme.emerald)
                }
            }
        }
        .padding(14)
        .background(cardBackground)
    }

    private var statusDotColor: Color {
        switch viewModel.phase {
        case .connected: return OpenUUTheme.emerald
        case .connecting: return OpenUUTheme.amber
        case .error: return OpenUUTheme.rose
        case .idle: return OpenUUTheme.textSecondary
        }
    }

    private var statusHeadline: String {
        switch viewModel.phase {
        case .connected(let host):
            return viewModel.linkBadge.isEmpty ? "已连接 \(host)" : "已连接 \(host) · \(viewModel.linkBadge)"
        case .connecting(let msg):
            return msg
        case .error(let err):
            return "连接失败: \(err)"
        case .idle:
            return viewModel.statusMessage
        }
    }

    private var smartConnectCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("智能跨网 / 局域网连接", systemImage: "sparkles")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(OpenUUTheme.textPrimary)
                Spacer()
                if viewModel.phase.isConnected {
                    Button("进入视窗") {
                        viewModel.selectedTab = .remote
                    }
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(OpenUUTheme.emerald)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("目标地址（9 位设备码 / openuu:// / IP / 域名）")
                    .font(.caption)
                    .foregroundStyle(OpenUUTheme.textSecondary)
                TextField("例如 839 201 475 或 192.168.1.10", text: $viewModel.targetInput)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .padding(10)
                    .background(OpenUUTheme.surfaceElevated, in: RoundedRectangle(cornerRadius: 10))
                    .foregroundStyle(OpenUUTheme.textPrimary)
            }

            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("端口")
                        .font(.caption)
                        .foregroundStyle(OpenUUTheme.textSecondary)
                    TextField("39481", text: $viewModel.portInput)
                        .keyboardType(.numberPad)
                        .padding(10)
                        .background(OpenUUTheme.surfaceElevated, in: RoundedRectangle(cornerRadius: 10))
                        .foregroundStyle(OpenUUTheme.textPrimary)
                }
                .frame(width: 96)

                VStack(alignment: .leading, spacing: 6) {
                    Text("配对码 / 访问密码（已信任设备可留空）")
                        .font(.caption)
                        .foregroundStyle(OpenUUTheme.textSecondary)
                    HStack {
                        Group {
                            if showPinPlaintext {
                                TextField("6 位 PIN 或密码", text: $viewModel.pinInput)
                            } else {
                                SecureField("6 位 PIN 或密码", text: $viewModel.pinInput)
                            }
                        }
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .foregroundStyle(OpenUUTheme.textPrimary)

                        Button {
                            showPinPlaintext.toggle()
                        } label: {
                            Image(systemName: showPinPlaintext ? "eye.slash" : "eye")
                                .foregroundStyle(OpenUUTheme.textSecondary)
                        }
                    }
                    .padding(10)
                    .background(OpenUUTheme.surfaceElevated, in: RoundedRectangle(cornerRadius: 10))
                }
            }

            HStack(spacing: 10) {
                Button {
                    viewModel.connectFromForm()
                } label: {
                    HStack {
                        if viewModel.phase.isConnecting {
                            ProgressView()
                                .tint(.white)
                                .scaleEffect(0.85)
                        } else {
                            Image(systemName: "bolt.fill")
                        }
                        Text(viewModel.phase.isConnecting ? "正在连接..." : "智能连接")
                            .fontWeight(.semibold)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(
                        LinearGradient(
                            colors: [OpenUUTheme.emerald, OpenUUTheme.indigo],
                            startPoint: .leading,
                            endPoint: .trailing
                        ),
                        in: RoundedRectangle(cornerRadius: 11)
                    )
                    .foregroundStyle(.white)
                }
                .disabled(viewModel.targetInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || viewModel.phase.isConnecting)

                if viewModel.phase.isConnected || viewModel.phase.isConnecting {
                    Button {
                        viewModel.disconnect()
                    } label: {
                        Text("断开")
                            .fontWeight(.semibold)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 12)
                            .background(OpenUUTheme.rose.opacity(0.18), in: RoundedRectangle(cornerRadius: 11))
                            .foregroundStyle(OpenUUTheme.rose)
                    }
                }
            }

            HStack {
                Button {
                    let target = viewModel.targetInput.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !target.isEmpty else { return }
                    let port = UInt16(viewModel.portInput) ?? OpenUUConstants.defaultPort
                    viewModel.deviceBook.addOrUpdateDevice(
                        alias: "",
                        target: target,
                        port: port,
                        savedPassword: viewModel.pinInput.trimmingCharacters(in: .whitespacesAndNewlines)
                    )
                    savedToast = "已保存至设备簿"
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) { savedToast = nil }
                } label: {
                    Label("保存至设备簿", systemImage: "bookmark.fill")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(OpenUUTheme.indigo)
                }
                .disabled(viewModel.targetInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                Spacer()

                if let toast = savedToast {
                    Text(toast)
                        .font(.caption)
                        .foregroundStyle(OpenUUTheme.emerald)
                }
            }
        }
        .padding(14)
        .background(cardBackground)
    }

    private var discoveredPeersCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("局域网发现 (mDNS)", systemImage: "wifi")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(OpenUUTheme.textPrimary)
                Spacer()
                Text("\(viewModel.discoveredPeers.count) 台")
                    .font(.caption)
                    .foregroundStyle(OpenUUTheme.emerald)
            }

            if viewModel.discoveredPeers.isEmpty {
                HStack(spacing: 10) {
                    ProgressView()
                        .tint(OpenUUTheme.emerald)
                        .scaleEffect(0.8)
                    Text("正在扫描局域网内的 Mac 主机 (_openuu._udp)...")
                        .font(.caption)
                        .foregroundStyle(OpenUUTheme.textSecondary)
                }
                .padding(.vertical, 8)
            } else {
                ForEach(viewModel.discoveredPeers) { peer in
                    HStack(spacing: 12) {
                        Image(systemName: "laptopcomputer")
                            .font(.title3)
                            .foregroundStyle(OpenUUTheme.emerald)
                            .frame(width: 34, height: 34)
                            .background(OpenUUTheme.emerald.opacity(0.14), in: RoundedRectangle(cornerRadius: 8))

                        VStack(alignment: .leading, spacing: 2) {
                            Text(peer.device_name)
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(OpenUUTheme.textPrimary)
                            Text(verbatim: "\(peer.preferredIP):\(peer.port)")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(OpenUUTheme.textSecondary)
                        }

                        Spacer()

                        Button("填入") {
                            viewModel.targetInput = peer.preferredIP
                            viewModel.portInput = "\(peer.port)"
                        }
                        .font(.caption.weight(.medium))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(OpenUUTheme.surfaceElevated, in: Capsule())
                        .foregroundStyle(OpenUUTheme.textPrimary)

                        Button("直连") {
                            viewModel.targetInput = peer.preferredIP
                            viewModel.portInput = "\(peer.port)"
                            viewModel.connectDirect(
                                hostIP: peer.preferredIP,
                                port: peer.port,
                                pin: viewModel.pinInput.trimmingCharacters(in: .whitespacesAndNewlines)
                            )
                        }
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(OpenUUTheme.emerald, in: Capsule())
                        .foregroundStyle(.white)
                    }
                    .padding(10)
                    .background(OpenUUTheme.surfaceElevated.opacity(0.65), in: RoundedRectangle(cornerRadius: 10))
                }
            }
        }
        .padding(14)
        .background(cardBackground)
    }

    private func trustedPeersQuickCard(_ peers: [TrustedPeerModel]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("已信任 Mac（免密快连）", systemImage: "checkmark.shield.fill")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(OpenUUTheme.textPrimary)

            ForEach(peers) { peer in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(peer.device_name.isEmpty ? "Mac" : peer.device_name)
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(OpenUUTheme.textPrimary)
                        Text(peer.formattedCode.isEmpty ? peer.device_id : peer.formattedCode)
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(OpenUUTheme.textSecondary)
                    }
                    Spacer()
                    Button("免密连接") {
                        viewModel.targetInput = peer.preferredTarget
                        viewModel.pinInput = ""
                        viewModel.connectSmart(target: peer.preferredTarget, pin: "")
                    }
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(OpenUUTheme.indigo, in: Capsule())
                    .foregroundStyle(.white)
                }
                .padding(10)
                .background(OpenUUTheme.surfaceElevated.opacity(0.65), in: RoundedRectangle(cornerRadius: 10))
            }
        }
        .padding(14)
        .background(cardBackground)
    }

    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: 14, style: .continuous)
            .fill(OpenUUTheme.surface)
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(OpenUUTheme.border, lineWidth: 1)
            )
    }
}

// MARK: - Tab 2: Device Book

private struct DeviceBookTabView: View {
    @ObservedObject var viewModel: MobileSessionViewModel
    @ObservedObject var store: DeviceBookStore
    @State private var searchText = ""
    @State private var editingDevice: ManagedRemoteDevice?
    @State private var showingAddSheet = false

    init(viewModel: MobileSessionViewModel) {
        self.viewModel = viewModel
        self.store = viewModel.deviceBook
    }

    private var filteredDevices: [ManagedRemoteDevice] {
        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return store.devices }
        return store.devices.filter {
            $0.alias.lowercased().contains(q)
                || $0.target.lowercased().contains(q)
                || $0.notes.lowercased().contains(q)
        }
    }

    var body: some View {
        NavigationStack {
            Group {
                if filteredDevices.isEmpty {
                    ContentUnavailableView {
                        Label("暂无保存的 Mac", systemImage: "desktopcomputer")
                    } description: {
                        Text("点击右上角 + 添加常用远程 Mac，支持保存密码、星标置顶与实时在线探测。")
                    }
                } else {
                    List {
                        ForEach(filteredDevices) { dev in
                            deviceRow(dev)
                                .listRowBackground(OpenUUTheme.surface)
                                .listRowSeparatorTint(OpenUUTheme.border)
                                .swipeActions(edge: .trailing) {
                                    Button(role: .destructive) {
                                        store.removeDevice(id: dev.id)
                                    } label: {
                                        Label("删除", systemImage: "trash")
                                    }
                                    Button {
                                        editingDevice = dev
                                    } label: {
                                        Label("编辑", systemImage: "pencil")
                                    }
                                    .tint(OpenUUTheme.indigo)
                                }
                        }
                    }
                    .listStyle(.insetGrouped)
                    .scrollContentBackground(.hidden)
                }
            }
            .background(OpenUUTheme.background.ignoresSafeArea())
            .navigationTitle("设备簿")
            .searchable(text: $searchText, prompt: "搜索设备名称、地址或备注")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        viewModel.probeDeviceBookOnline()
                    } label: {
                        Label("探测在线", systemImage: "antenna.radiowaves.left.and.right")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showingAddSheet = true
                    } label: {
                        Image(systemName: "plus")
                    }
                }
            }
            .onAppear {
                viewModel.probeDeviceBookOnline()
            }
            .sheet(isPresented: $showingAddSheet) {
                DeviceEditorSheet(existing: nil) { alias, target, port, password, isFav, notes in
                    store.addOrUpdateDevice(
                        alias: alias,
                        target: target,
                        port: port,
                        savedPassword: password,
                        isFavorite: isFav,
                        notes: notes
                    )
                    viewModel.probeDeviceBookOnline()
                }
            }
            .sheet(item: $editingDevice) { dev in
                DeviceEditorSheet(existing: dev) { alias, target, port, password, isFav, notes in
                    store.addOrUpdateDevice(
                        id: dev.id,
                        alias: alias,
                        target: target,
                        port: port,
                        savedPassword: password,
                        isFavorite: isFav,
                        notes: notes
                    )
                    viewModel.probeDeviceBookOnline()
                }
            }
        }
    }

    private func deviceRow(_ dev: ManagedRemoteDevice) -> some View {
        let state = store.presenceByID[dev.id] ?? .offline
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Button {
                    store.toggleFavorite(id: dev.id)
                } label: {
                    Image(systemName: dev.isFavorite ? "star.fill" : "star")
                        .foregroundStyle(dev.isFavorite ? OpenUUTheme.amber : OpenUUTheme.textSecondary)
                }
                .buttonStyle(.plain)

                VStack(alignment: .leading, spacing: 2) {
                    Text(dev.alias)
                        .font(.headline)
                        .foregroundStyle(OpenUUTheme.textPrimary)
                    Text(dev.formattedTarget)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(OpenUUTheme.textSecondary)
                }

                Spacer()

                presenceBadge(state)
            }

            if !dev.notes.isEmpty {
                Text(dev.notes)
                    .font(.caption)
                    .foregroundStyle(OpenUUTheme.textSecondary)
            }

            HStack(spacing: 10) {
                Button {
                    viewModel.targetInput = dev.target
                    viewModel.portInput = "\(dev.port)"
                    viewModel.pinInput = dev.savedPassword
                    viewModel.connectSmart(target: dev.target, port: dev.port, pin: dev.savedPassword)
                } label: {
                    Label("连接应用", systemImage: "macwindow")
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(OpenUUTheme.emerald, in: Capsule())
                        .foregroundStyle(.white)
                }
                .buttonStyle(.plain)

                Button {
                    viewModel.targetInput = dev.target
                    viewModel.portInput = "\(dev.port)"
                    viewModel.pinInput = dev.savedPassword
                    viewModel.connectSmart(
                        target: dev.target,
                        port: dev.port,
                        pin: dev.savedPassword,
                        autoOpenDesktop: true
                    )
                } label: {
                    Label("整台桌面", systemImage: "display")
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(OpenUUTheme.indigo, in: Capsule())
                        .foregroundStyle(.white)
                }
                .buttonStyle(.plain)

                Spacer()
            }
        }
        .padding(.vertical, 4)
    }

    private func presenceBadge(_ state: DeviceOnlineState) -> some View {
        let color: Color = {
            switch state {
            case .lanOnline: return OpenUUTheme.emerald
            case .wanOnline: return OpenUUTheme.indigo
            case .offline: return OpenUUTheme.textSecondary
            }
        }()
        return HStack(spacing: 5) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(state.label)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(color)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(color.opacity(0.14), in: Capsule())
    }
}

private struct DeviceEditorSheet: View {
    @Environment(\.dismiss) private var dismiss
    let existing: ManagedRemoteDevice?
    let onSave: (String, String, UInt16, String, Bool, String) -> Void

    @State private var alias: String
    @State private var target: String
    @State private var port: String
    @State private var password: String
    @State private var isFavorite: Bool
    @State private var notes: String

    init(
        existing: ManagedRemoteDevice?,
        onSave: @escaping (String, String, UInt16, String, Bool, String) -> Void
    ) {
        self.existing = existing
        self.onSave = onSave
        _alias = State(initialValue: existing?.alias ?? "")
        _target = State(initialValue: existing?.target ?? "")
        _port = State(initialValue: "\(existing?.port ?? OpenUUConstants.defaultPort)")
        _password = State(initialValue: existing?.savedPassword ?? "")
        _isFavorite = State(initialValue: existing?.isFavorite ?? false)
        _notes = State(initialValue: existing?.notes ?? "")
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("主机信息") {
                    TextField("别名（如 办公室 MacBook Pro）", text: $alias)
                    TextField("目标地址（9 位设备码 / IP / 域名）", text: $target)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("端口", text: $port)
                        .keyboardType(.numberPad)
                    SecureField("保存密码 / PIN（可选）", text: $password)
                }
                Section("偏好") {
                    Toggle("星标置顶", isOn: $isFavorite)
                    TextField("备注", text: $notes)
                }
            }
            .navigationTitle(existing == nil ? "添加远程 Mac" : "编辑设备")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        let p = UInt16(port) ?? OpenUUConstants.defaultPort
                        onSave(alias, target, p, password, isFavorite, notes)
                        dismiss()
                    }
                    .disabled(target.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }
}

// MARK: - Tab 3: Remote Workspace

private struct RemoteWorkspaceTabView: View {
    @ObservedObject var viewModel: MobileSessionViewModel
    let isSuppressedForImmersive: Bool
    @State private var appSearchText = ""
    @State private var imeText = ""
    @State private var showShortcutBar = true
    @State private var showTopBar = true
    @State private var showFileImporter = false

    private var videoAspectRatio: CGFloat {
        let sz = viewModel.currentLogicalSize()
        guard sz.width > 1, sz.height > 1 else { return 16.0 / 10.0 }
        return sz.width / sz.height
    }

    var body: some View {
        VStack(spacing: 0) {
            if showTopBar {
                remoteTopToolbar
            }

            if !viewModel.phase.isConnected {
                disconnectedPlaceholder
            } else if viewModel.showAppLauncher || viewModel.selectedWindowID == 0 {
                appLauncherView
            } else if isSuppressedForImmersive {
                Color.black
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .transition(.identity)
            } else {
                activeRemoteStreamView
                    .transition(.identity)
            }
        }
        .animation(nil, value: isSuppressedForImmersive)
        .background(OpenUUTheme.background.ignoresSafeArea())
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

    private var remoteTopToolbar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                HStack(spacing: 6) {
                    Circle()
                        .fill(viewModel.phase.isConnected ? OpenUUTheme.emerald : OpenUUTheme.textSecondary)
                        .frame(width: 8, height: 8)
                    Text(viewModel.phase.isConnected ? viewModel.phase.hostName : "未连接")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(OpenUUTheme.textPrimary)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(OpenUUTheme.surfaceElevated, in: Capsule())

                if !viewModel.linkBadge.isEmpty {
                    Text(viewModel.linkBadge)
                        .font(.caption2.monospacedDigit().weight(.semibold))
                        .foregroundStyle(OpenUUTheme.emerald)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(OpenUUTheme.emerald.opacity(0.14), in: Capsule())
                }

                if viewModel.phase.isConnected {
                    toolbarPill(
                        title: viewModel.showAppLauncher ? "返回画面" : "应用",
                        icon: "square.grid.2x2.fill",
                        active: viewModel.showAppLauncher
                    ) {
                        if viewModel.showAppLauncher && viewModel.selectedWindowID != 0 {
                            viewModel.showAppLauncher = false
                        } else {
                            viewModel.showAppLauncher = true
                            viewModel.refreshRemoteApps()
                        }
                    }

                    toolbarPill(
                        title: viewModel.touchMode.label,
                        icon: viewModel.touchMode.systemImage,
                        active: viewModel.touchMode == .trackpad
                    ) {
                        viewModel.touchMode = (viewModel.touchMode == .directTouch) ? .trackpad : .directTouch
                    }

                    if !viewModel.showAppLauncher && viewModel.selectedWindowID != 0 {
                        toolbarPill(
                            title: "全屏/横屏",
                            icon: "arrow.up.left.and.arrow.down.right",
                            active: viewModel.manualFullscreen
                        ) {
                            viewModel.manualFullscreen = true
                            viewModel.requestOrientation(landscape: true)
                        }

                        toolbarPill(
                            title: viewModel.videoFitMode.label,
                            icon: viewModel.videoFitMode.systemImage,
                            active: viewModel.videoFitMode == .fill
                        ) {
                            viewModel.toggleVideoFitMode()
                        }
                    }

                    toolbarPill(title: "手势", icon: "questionmark.circle", active: false) {
                        viewModel.showGestureGuide = true
                    }

                    toolbarPill(title: "传文件", icon: "doc.badge.arrow.up", active: false) {
                        showFileImporter = true
                    }

                    toolbarPill(title: "同步剪贴板", icon: "doc.on.clipboard", active: false) {
                        viewModel.pushLocalClipboardToHost(silent: false)
                    }

                    toolbarPill(title: "关键帧", icon: "arrow.clockwise", active: false) {
                        viewModel.requestKeyframeNow()
                    }

                    toolbarPill(title: "HUD", icon: "gauge.with.dots.needle.67percent", active: viewModel.showDebugHUD) {
                        viewModel.showDebugHUD.toggle()
                    }

                    if viewModel.canvasZoomScale > 1.05 {
                        toolbarPill(
                            title: String(format: "%.1fx 复位", viewModel.canvasZoomScale),
                            icon: "arrow.down.right.and.arrow.up.left",
                            active: true
                        ) {
                            viewModel.resetZoom()
                        }
                    }

                    Button {
                        viewModel.disconnect()
                    } label: {
                        Image(systemName: "power")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(OpenUUTheme.rose)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(OpenUUTheme.rose.opacity(0.16), in: Capsule())
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .background(OpenUUTheme.surface)
        .overlay(alignment: .bottom) {
            Rectangle().fill(OpenUUTheme.border).frame(height: 0.5)
        }
    }

    private func toolbarPill(title: String, icon: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .font(.caption.weight(.medium))
                .foregroundStyle(active ? .white : OpenUUTheme.textPrimary)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(active ? OpenUUTheme.emerald : OpenUUTheme.surfaceElevated, in: Capsule())
        }
    }

    private var disconnectedPlaceholder: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "macwindow.badge.plus")
                .font(.system(size: 52))
                .foregroundStyle(OpenUUTheme.indigo)
            Text("尚未连接到远程 Mac")
                .font(.headline)
                .foregroundStyle(OpenUUTheme.textPrimary)
            Text("请在「连接」或「设备簿」中选择一台 Mac 建立加密 QUIC 会话。")
                .font(.subheadline)
                .foregroundStyle(OpenUUTheme.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Button("前往连接") {
                viewModel.selectedTab = .connect
            }
            .font(.subheadline.weight(.semibold))
            .padding(.horizontal, 22)
            .padding(.vertical, 10)
            .background(OpenUUTheme.emerald, in: Capsule())
            .foregroundStyle(.white)
            Spacer()
        }
    }

    // MARK: App Launcher Grid

    private var filteredApps: [RemoteAppSummary] {
        let regular = viewModel.remoteApps.filter { $0.bundle_id != OpenUUConstants.fullDesktopBundleID }
        let q = appSearchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return regular }
        return regular.filter {
            $0.name.lowercased().contains(q) || $0.bundle_id.lowercased().contains(q)
        }
    }

    private var appLauncherView: some View {
        ScrollView {
            VStack(spacing: 14) {
                // Featured Full Desktop Card
                Button {
                    viewModel.openFullDesktop()
                } label: {
                    HStack(spacing: 14) {
                        Image(systemName: "desktopcomputer")
                            .font(.title.weight(.semibold))
                            .foregroundStyle(.white)
                            .frame(width: 52, height: 52)
                            .background(.white.opacity(0.18), in: RoundedRectangle(cornerRadius: 12))

                        VStack(alignment: .leading, spacing: 4) {
                            Text("整台桌面")
                                .font(.headline)
                                .foregroundStyle(.white)
                            Text("全屏控制整台远程 Mac 桌面 (__openuu_full_desktop__)")
                                .font(.caption)
                                .foregroundStyle(.white.opacity(0.85))
                                .lineLimit(2)
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.subheadline.weight(.bold))
                            .foregroundStyle(.white.opacity(0.85))
                    }
                    .padding(16)
                    .background(
                        LinearGradient(
                            colors: [OpenUUTheme.emerald, OpenUUTheme.indigo],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        in: RoundedRectangle(cornerRadius: 16, style: .continuous)
                    )
                }

                // Search bar + Refresh
                HStack(spacing: 8) {
                    HStack {
                        Image(systemName: "magnifyingglass")
                            .foregroundStyle(OpenUUTheme.textSecondary)
                        TextField("搜索远程 Mac 应用...", text: $appSearchText)
                            .foregroundStyle(OpenUUTheme.textPrimary)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }
                    .padding(10)
                    .background(OpenUUTheme.surface, in: RoundedRectangle(cornerRadius: 10))

                    Button {
                        viewModel.refreshRemoteApps()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .foregroundStyle(OpenUUTheme.emerald)
                            .padding(10)
                            .background(OpenUUTheme.surface, in: RoundedRectangle(cornerRadius: 10))
                    }
                }

                // Adaptive App Grid
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 104), spacing: 12)], spacing: 12) {
                    ForEach(filteredApps) { app in
                        Button {
                            viewModel.openRemoteApp(bundleID: app.bundle_id, appName: app.name)
                        } label: {
                            VStack(spacing: 8) {
                                ZStack(alignment: .topTrailing) {
                                    if let img = viewModel.appIcons[app.bundle_id] {
                                        Image(uiImage: img)
                                            .resizable()
                                            .interpolation(.high)
                                            .scaledToFit()
                                            .frame(width: 52, height: 52)
                                            .clipShape(RoundedRectangle(cornerRadius: 12))
                                    } else {
                                        RoundedRectangle(cornerRadius: 12)
                                            .fill(OpenUUTheme.surfaceElevated)
                                            .frame(width: 52, height: 52)
                                            .overlay {
                                                Image(systemName: "app.fill")
                                                    .font(.title2)
                                                    .foregroundStyle(OpenUUTheme.indigo)
                                            }
                                    }

                                    if app.window_count > 1 {
                                        Text("\(app.window_count)")
                                            .font(.caption2.weight(.bold))
                                            .foregroundStyle(.white)
                                            .padding(.horizontal, 5)
                                            .padding(.vertical, 2)
                                            .background(OpenUUTheme.emerald, in: Capsule())
                                            .offset(x: 6, y: -4)
                                    }
                                }

                                Text(app.name)
                                    .font(.caption.weight(.medium))
                                    .foregroundStyle(OpenUUTheme.textPrimary)
                                    .lineLimit(2)
                                    .multilineTextAlignment(.center)
                            }
                            .frame(maxWidth: .infinity, minHeight: 104)
                            .padding(10)
                            .background(
                                RoundedRectangle(cornerRadius: 14, style: .continuous)
                                    .fill(OpenUUTheme.surface)
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                                            .stroke(OpenUUTheme.border, lineWidth: 1)
                                    )
                            )
                        }
                    }
                }
            }
            .padding(14)
        }
    }

    // MARK: Active Remote Stream & Input Controls

    private var activeRemoteStreamView: some View {
        VStack(spacing: 0) {
            if !viewModel.remoteWindows.isEmpty {
                windowSwitcherBar
            }

            ZStack(alignment: .bottomLeading) {
                MobileRemoteCanvasView(
                    renderer: viewModel.videoRenderer,
                    aspectRatio: videoAspectRatio,
                    touchMode: viewModel.touchMode,
                    videoFitMode: viewModel.videoFitMode,
                    isImmersive: false,
                    cursorPos: viewModel.cursorPos,
                    cursorKind: viewModel.cursorKind,
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
                            showShortcutBar.toggle()
                        }
                    },
                    onToggleToolbar: {
                        withAnimation(.easeInOut(duration: 0.18)) {
                            showTopBar.toggle()
                        }
                    }
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                if let badge = viewModel.gestureFeedbackBadge {
                    VStack {
                        GestureFeedbackBadgeView(text: badge)
                            .padding(.top, 10)
                        Spacer()
                    }
                    .frame(maxWidth: .infinity)
                    .allowsHitTesting(false)
                }

                if viewModel.showDebugHUD {
                    DebugTelemetryHUDView(viewModel: viewModel)
                        .padding(10)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            imeTextCommitBar

            if showShortcutBar {
                macShortcutBar
            }
        }
    }

    private var windowSwitcherBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(viewModel.remoteWindows) { win in
                    let isSelected = (win.window_id == viewModel.selectedWindowID)
                    HStack(spacing: 6) {
                        Button {
                            viewModel.selectRemoteWindow(win.window_id)
                        } label: {
                            Text(win.title.isEmpty ? "窗口 #\(win.window_id)" : win.title)
                                .font(.caption.weight(isSelected ? .semibold : .regular))
                                .foregroundStyle(isSelected ? .white : OpenUUTheme.textSecondary)
                                .lineLimit(1)
                        }

                        Button {
                            viewModel.stopRemoteWindow(win.window_id)
                        } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(isSelected ? .white.opacity(0.85) : OpenUUTheme.textSecondary)
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(
                        isSelected ? OpenUUTheme.emerald : OpenUUTheme.surfaceElevated,
                        in: Capsule()
                    )
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
        }
        .background(OpenUUTheme.surface.opacity(0.9))
    }

    private var imeTextCommitBar: some View {
        HStack(spacing: 8) {
            Button {
                withAnimation(.easeInOut(duration: 0.18)) {
                    showShortcutBar.toggle()
                }
            } label: {
                Image(systemName: showShortcutBar ? "keyboard.chevron.compact.down" : "keyboard")
                    .font(.subheadline)
                    .foregroundStyle(showShortcutBar ? OpenUUTheme.emerald : OpenUUTheme.textSecondary)
                    .padding(8)
                    .background(OpenUUTheme.surfaceElevated, in: RoundedRectangle(cornerRadius: 8))
            }

            TextField("输入中英文发送至 Mac...", text: $imeText)
                .font(.subheadline)
                .foregroundStyle(OpenUUTheme.textPrimary)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(OpenUUTheme.surfaceElevated, in: RoundedRectangle(cornerRadius: 8))
                .submitLabel(.send)
                .onSubmit {
                    commitIMEText()
                }

            Button("发送") {
                commitIMEText()
            }
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(OpenUUTheme.emerald, in: RoundedRectangle(cornerRadius: 8))
            .foregroundStyle(.white)
            .disabled(imeText.isEmpty)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(OpenUUTheme.surface)
        .overlay(alignment: .top) {
            Rectangle().fill(OpenUUTheme.border).frame(height: 0.5)
        }
    }

    private func commitIMEText() {
        guard !imeText.isEmpty else { return }
        viewModel.sendTextCommit(imeText)
        imeText = ""
    }

    private var macShortcutBar: some View {
        MacShortcutStripView(viewModel: viewModel)
    }
}

// MARK: - Shared Remote Subviews (HUD, Gesture Badge, Mac Shortcut Strip)

private struct GestureFeedbackBadgeView: View {
    let text: String

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(OpenUUTheme.emerald)
                .frame(width: 7, height: 7)
            Text(text)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(
            Capsule()
                .fill(Color.black.opacity(0.76))
                .overlay(
                    Capsule().stroke(OpenUUTheme.emerald.opacity(0.55), lineWidth: 1)
                )
        )
        .shadow(color: .black.opacity(0.35), radius: 8, y: 3)
    }
}

private struct DebugTelemetryHUDView: View {
    @ObservedObject var viewModel: MobileSessionViewModel

    var body: some View {
        let t = viewModel.videoTelemetry
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                Text(t.codecName)
                    .font(.caption2.monospaced().weight(.bold))
                    .foregroundStyle(OpenUUTheme.emerald)
                Text("\(t.fps) FPS")
                    .font(.caption2.monospacedDigit().weight(.bold))
                    .foregroundStyle(.white)
                Text(String(format: "%.2f Mbps", t.bitrateMbps))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(OpenUUTheme.indigo)
            }
            Text("\(t.encodedWidth)×\(t.encodedHeight) · frames=\(t.decodedFrames) · win=\(viewModel.selectedWindowID)")
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(.white.opacity(0.85))
            if !viewModel.linkBadge.isEmpty {
                Text(viewModel.linkBadge)
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(OpenUUTheme.emerald.opacity(0.9))
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.black.opacity(0.74))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(OpenUUTheme.emerald.opacity(0.45), lineWidth: 1)
                )
        )
        .allowsHitTesting(false)
    }
}

private struct MacShortcutStripView: View {
    @ObservedObject var viewModel: MobileSessionViewModel
    var translucent: Bool = false

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                modifierKey("⌘", bit: MacModifiers.command)
                modifierKey("⌥", bit: MacModifiers.option)
                modifierKey("⌃", bit: MacModifiers.control)
                modifierKey("⇧", bit: MacModifiers.shift)

                Divider().frame(height: 20).overlay(OpenUUTheme.border)

                tapKey("Esc", code: MacKeyCodes.escape)
                tapKey("Tab", code: MacKeyCodes.tab)
                tapKey("Space", code: MacKeyCodes.space)
                tapKey("⌫", code: MacKeyCodes.delete)
                tapKey("⏎", code: MacKeyCodes.returnKey)
                tapKey("←", code: MacKeyCodes.left)
                tapKey("↑", code: MacKeyCodes.up)
                tapKey("↓", code: MacKeyCodes.down)
                tapKey("→", code: MacKeyCodes.right)

                Divider().frame(height: 20).overlay(OpenUUTheme.border)

                comboKey("⌘C", code: MacKeyCodes.c, mods: MacModifiers.command)
                comboKey("⌘V", code: MacKeyCodes.v, mods: MacModifiers.command)
                comboKey("⌘W", code: MacKeyCodes.w, mods: MacModifiers.command)
                comboKey("⌘Space", code: MacKeyCodes.space, mods: MacModifiers.command)
                comboKey("⌘Z", code: MacKeyCodes.z, mods: MacModifiers.command)
                comboKey("⌘Q", code: MacKeyCodes.q, mods: MacModifiers.command)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
        }
        .background(translucent ? Color.clear : OpenUUTheme.surface)
    }

    private func modifierKey(_ label: String, bit: UInt32) -> some View {
        let active = (viewModel.stickyModifiers & bit) != 0
        return Button {
            viewModel.toggleStickyModifier(bit)
        } label: {
            Text(label)
                .font(.caption.weight(.bold))
                .foregroundStyle(active ? .white : OpenUUTheme.textPrimary)
                .frame(minWidth: 34, minHeight: 30)
                .background(
                    active ? OpenUUTheme.emerald : OpenUUTheme.surfaceElevated.opacity(translucent ? 0.85 : 1),
                    in: RoundedRectangle(cornerRadius: 7)
                )
        }
    }

    private func tapKey(_ label: String, code: UInt32) -> some View {
        Button {
            viewModel.sendKeyTap(keyCode: code)
        } label: {
            Text(label)
                .font(.caption.weight(.medium))
                .foregroundStyle(OpenUUTheme.textPrimary)
                .padding(.horizontal, 10)
                .frame(minHeight: 30)
                .background(
                    OpenUUTheme.surfaceElevated.opacity(translucent ? 0.85 : 1),
                    in: RoundedRectangle(cornerRadius: 7)
                )
        }
    }

    private func comboKey(_ label: String, code: UInt32, mods: UInt32) -> some View {
        Button {
            viewModel.sendKeyTap(keyCode: code, explicitModifiers: mods)
        } label: {
            Text(label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(OpenUUTheme.indigo)
                .padding(.horizontal, 10)
                .frame(minHeight: 30)
                .background(OpenUUTheme.indigo.opacity(0.22), in: RoundedRectangle(cornerRadius: 7))
        }
    }
}

// MARK: - Auto-Immersive Landscape / Fullscreen Workspace

private struct RemoteImmersiveWorkspace: View {
    @ObservedObject var viewModel: MobileSessionViewModel
    let isLandscape: Bool
    let viewportSize: CGSize

    @State private var isHudExpanded: Bool = false
    @State private var showKeyboardDock: Bool = false
    @State private var imeText: String = ""
    @State private var showFileImporter: Bool = false

    // Draggable Floating Pill position (in viewportSize coordinates; nil = default top-trailing)
    @State private var pillPosition: CGPoint?
    @State private var dragStartPosition: CGPoint?

    private var videoAspectRatio: CGFloat {
        let sz = viewModel.currentLogicalSize()
        guard sz.width > 1, sz.height > 1 else { return 16.0 / 10.0 }
        return sz.width / sz.height
    }

    private var defaultPillPosition: CGPoint {
        let w = max(viewportSize.width, 320)
        return CGPoint(x: w - 60, y: isLandscape ? 30 : 58)
    }

    private var activePillPosition: CGPoint {
        let raw = pillPosition ?? defaultPillPosition
        let minX: CGFloat = 46
        let maxX: CGFloat = max(minX, viewportSize.width - 46)
        let minY: CGFloat = 24
        let maxY: CGFloat = max(minY, viewportSize.height - 28)
        return CGPoint(
            x: min(max(raw.x, minX), maxX),
            y: min(max(raw.y, minY), maxY)
        )
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea(.all)

            // 100% Full-bleed Hardware Video Canvas
            MobileRemoteCanvasView(
                renderer: viewModel.videoRenderer,
                aspectRatio: videoAspectRatio,
                touchMode: viewModel.touchMode,
                videoFitMode: viewModel.videoFitMode,
                isImmersive: true,
                cursorPos: viewModel.cursorPos,
                cursorKind: viewModel.cursorKind,
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
                    withAnimation(.spring(response: 0.28, dampingFraction: 0.85)) {
                        showKeyboardDock.toggle()
                    }
                },
                onToggleToolbar: {
                    withAnimation(.spring(response: 0.28, dampingFraction: 0.85)) {
                        isHudExpanded.toggle()
                    }
                }
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .ignoresSafeArea(.all)

            // Bottom-leading Debug Telemetry HUD (when enabled)
            if viewModel.showDebugHUD {
                VStack {
                    Spacer()
                    HStack {
                        DebugTelemetryHUDView(viewModel: viewModel)
                            .padding(.leading, isLandscape ? 26 : 12)
                            .padding(.bottom, showKeyboardDock ? 104 : 14)
                        Spacer()
                    }
                }
                .allowsHitTesting(false)
            }

            // Center-top Gesture Feedback Badge
            if let badge = viewModel.gestureFeedbackBadge {
                VStack {
                    GestureFeedbackBadgeView(text: badge)
                        .padding(.top, isHudExpanded ? 88 : 16)
                    Spacer()
                }
                .allowsHitTesting(false)
                .transition(.opacity.combined(with: .scale(scale: 0.92)))
            }

            // Expanded Translucent Floating HUD Bar
            if isHudExpanded {
                VStack(spacing: 0) {
                    floatingHudBar
                        .padding(.horizontal, isLandscape ? 28 : 12)
                        .padding(.top, isLandscape ? 12 : 44)
                    Spacer()
                }
                .transition(.move(edge: .top).combined(with: .opacity))
                .zIndex(20)
            }

            // Bottom Floating Keyboard & Mac Shortcut Dock
            if showKeyboardDock {
                VStack(spacing: 0) {
                    Spacer()
                    floatingKeyboardDock
                        .padding(.horizontal, isLandscape ? 24 : 8)
                        .padding(.bottom, isLandscape ? 10 : 18)
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .zIndex(25)
            }

            // Collapsed Draggable Semi-Transparent Floating Control Pill (0.65 opacity)
            if !isHudExpanded {
                floatingControlPill
                    .position(activePillPosition)
                    .gesture(
                        DragGesture(minimumDistance: 4)
                            .onChanged { value in
                                if dragStartPosition == nil {
                                    dragStartPosition = activePillPosition
                                }
                                guard let start = dragStartPosition else { return }
                                pillPosition = CGPoint(
                                    x: start.x + value.translation.width,
                                    y: start.y + value.translation.height
                                )
                            }
                            .onEnded { _ in
                                dragStartPosition = nil
                            }
                    )
                    .zIndex(30)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .ignoresSafeArea(.all)
        .onChange(of: viewportSize) { _, _ in
            // Re-anchor pill to default top-trailing on orientation change
            pillPosition = nil
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

    private var floatingControlPill: some View {
        Button {
            withAnimation(.spring(response: 0.28, dampingFraction: 0.85)) {
                isHudExpanded = true
            }
        } label: {
            HStack(spacing: 6) {
                Image("BrandIcon")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 18, height: 18)
                    .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                if viewModel.canvasZoomScale > 1.05 {
                    Text("\(Int((viewModel.canvasZoomScale * 100).rounded()))%")
                        .font(.caption2.monospacedDigit().weight(.semibold))
                        .foregroundStyle(.white)
                } else {
                    Image(systemName: "slider.horizontal.3")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.92))
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                Capsule()
                    .fill(Color.black.opacity(0.75))
                    .overlay(
                        Capsule().stroke(OpenUUTheme.emerald.opacity(0.55), lineWidth: 1)
                    )
            )
            .shadow(color: .black.opacity(0.45), radius: 8, y: 3)
        }
        .opacity(0.65)
        .accessibilityLabel("展开悬浮控制栏")
    }

    private var floatingHudBar: some View {
        VStack(spacing: 6) {
            // Row 1: Window Switcher Pills + App Launcher + Collapse
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 7) {
                    hudChip(
                        title: "应用台",
                        icon: "square.grid.2x2.fill",
                        active: false
                    ) {
                        viewModel.manualFullscreen = false
                        viewModel.showAppLauncher = true
                        viewModel.refreshRemoteApps()
                    }

                    ForEach(viewModel.remoteWindows) { win in
                        let isSelected = (win.window_id == viewModel.selectedWindowID)
                        HStack(spacing: 5) {
                            Button {
                                viewModel.selectRemoteWindow(win.window_id)
                            } label: {
                                Text(win.title.isEmpty ? "窗口 #\(win.window_id)" : win.title)
                                    .font(.caption2.weight(isSelected ? .semibold : .regular))
                                    .foregroundStyle(isSelected ? .white : OpenUUTheme.textPrimary)
                                    .lineLimit(1)
                            }

                            Button {
                                viewModel.stopRemoteWindow(win.window_id)
                            } label: {
                                Image(systemName: "xmark")
                                    .font(.system(size: 9, weight: .bold))
                                    .foregroundStyle(isSelected ? .white.opacity(0.85) : OpenUUTheme.textSecondary)
                            }
                        }
                        .padding(.horizontal, 9)
                        .padding(.vertical, 5)
                        .background(
                            isSelected ? OpenUUTheme.emerald : OpenUUTheme.surfaceElevated.opacity(0.85),
                            in: Capsule()
                        )
                    }

                    Divider().frame(height: 18).overlay(Color.white.opacity(0.2))

                    // Direct / Trackpad Toggle
                    hudChip(
                        title: viewModel.touchMode.label,
                        icon: viewModel.touchMode.systemImage,
                        active: viewModel.touchMode == .trackpad
                    ) {
                        viewModel.touchMode = (viewModel.touchMode == .directTouch) ? .trackpad : .directTouch
                    }

                    // Fit / Fill Video Scaling Toggle
                    hudChip(
                        title: viewModel.videoFitMode.label,
                        icon: viewModel.videoFitMode.systemImage,
                        active: viewModel.videoFitMode == .fill
                    ) {
                        viewModel.toggleVideoFitMode()
                    }

                    // Zoom - / 100% / +
                    HStack(spacing: 2) {
                        Button {
                            viewModel.zoomOut()
                        } label: {
                            Image(systemName: "minus")
                                .font(.caption2.weight(.bold))
                                .frame(width: 24, height: 24)
                        }
                        .disabled(viewModel.canvasZoomScale <= 1.01)

                        Button {
                            viewModel.resetZoom()
                        } label: {
                            Text("\(Int((viewModel.canvasZoomScale * 100).rounded()))%")
                                .font(.caption2.monospacedDigit().weight(.semibold))
                                .padding(.horizontal, 5)
                                .frame(height: 24)
                        }

                        Button {
                            viewModel.zoomIn()
                        } label: {
                            Image(systemName: "plus")
                                .font(.caption2.weight(.bold))
                                .frame(width: 24, height: 24)
                        }
                        .disabled(viewModel.canvasZoomScale >= 4.99)
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 4)
                    .background(OpenUUTheme.surfaceElevated.opacity(0.85), in: Capsule())

                    // Keyboard / Shortcut Dock Toggle
                    hudChip(
                        title: "键盘",
                        icon: "keyboard",
                        active: showKeyboardDock
                    ) {
                        withAnimation(.spring(response: 0.25, dampingFraction: 0.85)) {
                            showKeyboardDock.toggle()
                        }
                    }

                    // File transfer / Clipboard / HUD
                    hudIconChip(icon: "doc.badge.arrow.up", active: false) {
                        showFileImporter = true
                    }

                    hudIconChip(icon: "doc.on.clipboard", active: false) {
                        viewModel.pushLocalClipboardToHost(silent: false)
                    }

                    hudIconChip(icon: "gauge.with.dots.needle.67percent", active: viewModel.showDebugHUD) {
                        viewModel.showDebugHUD.toggle()
                    }

                    // Gesture Guide (?)
                    hudChip(title: "手势", icon: "questionmark.circle", active: false) {
                        viewModel.showGestureGuide = true
                    }

                    // Landscape / Portrait Orientation Helper
                    hudChip(
                        title: isLandscape ? "竖屏" : "横屏",
                        icon: "rotate.right",
                        active: false
                    ) {
                        viewModel.requestOrientation(landscape: !isLandscape)
                    }

                    // Exit Fullscreen
                    Button {
                        viewModel.manualFullscreen = false
                        if isLandscape {
                            viewModel.requestOrientation(landscape: false)
                        }
                    } label: {
                        Label("退出全屏", systemImage: "arrow.down.right.and.arrow.up.left")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 9)
                            .padding(.vertical, 5)
                            .background(OpenUUTheme.rose.opacity(0.85), in: Capsule())
                    }

                    // Collapse HUD back to floating pill
                    Button {
                        withAnimation(.spring(response: 0.25, dampingFraction: 0.85)) {
                            isHudExpanded = false
                        }
                    } label: {
                        Image(systemName: "chevron.up.circle.fill")
                            .font(.callout)
                            .foregroundStyle(.white.opacity(0.85))
                            .padding(.horizontal, 4)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(Color.black.opacity(0.45))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(Color.white.opacity(0.16), lineWidth: 1)
                )
        )
        .shadow(color: .black.opacity(0.5), radius: 14, y: 6)
    }

    private var floatingKeyboardDock: some View {
        VStack(spacing: 4) {
            HStack(spacing: 8) {
                TextField("输入中英文发送至 Mac...", text: $imeText)
                    .font(.subheadline)
                    .foregroundStyle(OpenUUTheme.textPrimary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(OpenUUTheme.surfaceElevated.opacity(0.9), in: RoundedRectangle(cornerRadius: 8))
                    .submitLabel(.send)
                    .onSubmit {
                        commitFloatingIME()
                    }

                Button("发送") {
                    commitFloatingIME()
                }
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(OpenUUTheme.emerald, in: RoundedRectangle(cornerRadius: 8))
                .foregroundStyle(.white)
                .disabled(imeText.isEmpty)

                Button {
                    withAnimation(.spring(response: 0.25, dampingFraction: 0.85)) {
                        showKeyboardDock = false
                    }
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title3)
                        .foregroundStyle(OpenUUTheme.textSecondary)
                }
            }
            .padding(.horizontal, 10)
            .padding(.top, 8)

            MacShortcutStripView(viewModel: viewModel, translucent: true)
        }
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(Color.black.opacity(0.55))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(Color.white.opacity(0.14), lineWidth: 1)
                )
        )
        .shadow(color: .black.opacity(0.5), radius: 14, y: 4)
    }

    private func commitFloatingIME() {
        guard !imeText.isEmpty else { return }
        viewModel.sendTextCommit(imeText)
        imeText = ""
    }

    private func hudChip(title: String, icon: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .font(.caption2.weight(.medium))
                .foregroundStyle(active ? .white : OpenUUTheme.textPrimary)
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .background(
                    active ? OpenUUTheme.emerald : OpenUUTheme.surfaceElevated.opacity(0.85),
                    in: Capsule()
                )
        }
    }

    private func hudIconChip(icon: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(active ? .white : OpenUUTheme.textPrimary)
                .frame(width: 28, height: 24)
                .background(
                    active ? OpenUUTheme.emerald : OpenUUTheme.surfaceElevated.opacity(0.85),
                    in: Capsule()
                )
        }
    }
}

// MARK: - Gesture Guide Sheet

private struct GestureGuideSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section("单指操作（直触 & 触控板通用）") {
                    gestureRow(icon: "hand.tap.fill", title: "单指轻点", detail: "左键单击")
                    gestureRow(icon: "hand.tap", title: "单指双击", detail: "左键双击")
                    gestureRow(icon: "hand.point.up.left.and.text.fill", title: "长按 0.3 秒后移动", detail: "左键拖拽（缩放画面下也可精准拖拽！）")
                    gestureRow(icon: "contextualmenu.and.cursorarrow", title: "长按 0.3 秒静止抬起", detail: "右键单击（带震动反馈）")
                    gestureRow(icon: "cursorarrow.click.2", title: "双击按住后滑动", detail: "macOS 触控板风格左键拖拽（直触与触控板通用）")
                    gestureRow(icon: "hand.draw.fill", title: "单指滑动", detail: "直触：未缩放时直接左键拖拽，放大后平移视野；触控板：移动光标并在边缘自动跟随平移")
                }
                .listRowBackground(OpenUUTheme.surface)

                Section("双指操作") {
                    gestureRow(icon: "hand.raised.fingers.spread.fill", title: "双指轻点", detail: "右键单击（直触 & 触控板通用）")
                    gestureRow(icon: "hand.point.up.braille.fill", title: "按住一指 + 轻点第二指", detail: "单手/双手快捷右键单击")
                    gestureRow(icon: "arrow.up.left.and.arrow.down.right", title: "双指捏合", detail: "缩放显示画面（1.0x – 5.0x，自动防滚轮误触）")
                    gestureRow(icon: "arrow.up.and.down.and.arrow.left.and.right", title: "双指平行滑动", detail: "平滑滚轮滚动（上下 / 左右）")
                }
                .listRowBackground(OpenUUTheme.surface)

                Section("三指快捷手势") {
                    gestureRow(icon: "keyboard", title: "三指轻点", detail: "呼出 / 收起键盘与 Mac 快捷键栏")
                    gestureRow(icon: "menubar.rectangle", title: "三指上下滑", detail: "展开 / 收起悬浮工具栏")
                }
                .listRowBackground(OpenUUTheme.surface)

                Section("横屏自动沉浸全屏") {
                    gestureRow(icon: "iphone.landscape", title: "横屏自动全屏", detail: "横握手机自动隐藏底栏、状态栏与系统指示条，硬件解码画面 100% 铺满")
                    gestureRow(icon: "capsule.fill", title: "悬浮控制胶囊", detail: "可任意拖拽；轻点展开窗口切换、适应/铺满缩放、100%-500% 放大、键盘与横竖屏切换")
                }
                .listRowBackground(OpenUUTheme.surface)
            }
            .scrollContentBackground(.hidden)
            .background(OpenUUTheme.background.ignoresSafeArea())
            .navigationTitle("远控手势指南")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("知道了") { dismiss() }
                        .foregroundStyle(OpenUUTheme.emerald)
                }
            }
        }
    }

    private func gestureRow(icon: String, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.body.weight(.semibold))
                .foregroundStyle(OpenUUTheme.emerald)
                .frame(width: 26, height: 26)
                .background(OpenUUTheme.emerald.opacity(0.14), in: RoundedRectangle(cornerRadius: 7))

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(OpenUUTheme.textPrimary)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(OpenUUTheme.textSecondary)
            }
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Tab 4: Settings & Logs

private struct SettingsLogsTabView: View {
    @ObservedObject var viewModel: MobileSessionViewModel
    @State private var coordURL = OpenUUConstants.defaultCoordURL
    @State private var relayURL = OpenUUConstants.defaultRelayURL
    @State private var relayToken = ""
    @State private var enablePublicFallback = true
    @State private var allowInsecureTLS = false
    @State private var wanSaveMessage: String?
    @State private var copiedDeployPrompt = false

    private static let githubRepoURL = "https://github.com/onekb/OpenUU"
    private static let selfHostAIPrompt = """
    请帮我部署一套私有的 OpenUU 跨网寻址（Coord）与打洞中继（Relay）服务器。
    开源仓库地址：https://github.com/onekb/OpenUU （请先拉取或阅读仓库下的 deploy/ 目录与 README.md）。

    部署要求：
    1. 云服务器方案请参考 `deploy/docker-compose.yml`、`deploy/Dockerfile.coord` 与 `deploy/Caddyfile`；零暴露公网 IP 方案请参考 `deploy/cloudflare-worker` 与 `deploy/cloudflare-relay-worker`（Cloudflare Workers + D1 + Tunnel）。
    2. 先向我确认服务器 SSH 信息与解析好的 Coord / Relay 二级域名（或是否采用纯 IP 自签证书 / Cloudflare 方案）。
    3. 自动完成容器构建启动、HTTPS 证书签发、端口放行（TCP 80/443，UDP 443/3478/7842）及中继鉴权 Bearer Token 配置，并验证 `/health` 接口返回正常。
    4. 部署完成后，直接输出需要填入 OpenUU「网络与日志」页面的三项配置：设备码寻址 (Coord URL)、打洞与中继 (Relay URL)、中继鉴权 Token。
    """

    var body: some View {
        NavigationStack {
            Form {
                Section("本机身份") {
                    if let id = viewModel.identity {
                        LabeledContent("设备名称", value: id.device_name)
                        LabeledContent("9 位设备码") {
                            HStack(spacing: 8) {
                                Text(id.formatted_code)
                                    .font(.callout.monospacedDigit().weight(.semibold))
                                    .foregroundStyle(OpenUUTheme.emerald)
                                Button {
                                    UIPasteboard.general.string = id.device_code
                                } label: {
                                    Image(systemName: "doc.on.doc")
                                        .font(.caption)
                                }
                            }
                        }
                        LabeledContent("信令状态", value: id.coord_status.isEmpty ? "就绪" : id.coord_status)
                    } else {
                        Text("正在读取身份信息...")
                            .foregroundStyle(OpenUUTheme.textSecondary)
                    }
                }
                .listRowBackground(OpenUUTheme.surface)

                Section("WAN 跨网与中继配置") {
                    TextField("信令服务 Coord URL", text: $coordURL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("中继服务 Relay URL", text: $relayURL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField("中继鉴权 Token（可选）", text: $relayToken)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Toggle("允许公共节点兜底 (Public Fallback)", isOn: $enablePublicFallback)
                    Toggle("允许自签证书 TLS (局域网/测试)", isOn: $allowInsecureTLS)

                    HStack {
                        Button("保存 WAN 配置") {
                            let cfg = WanConfigModel(
                                coord_url: coordURL.trimmingCharacters(in: .whitespacesAndNewlines),
                                relay_url: relayURL.trimmingCharacters(in: .whitespacesAndNewlines),
                                relay_auth_token: relayToken.trimmingCharacters(in: .whitespacesAndNewlines),
                                enable_public_fallback: enablePublicFallback,
                                allow_insecure_tls: allowInsecureTLS
                            )
                            viewModel.saveWanConfig(cfg)
                            wanSaveMessage = "已保存"
                            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { wanSaveMessage = nil }
                        }
                        .foregroundStyle(OpenUUTheme.emerald)

                        Spacer()
                        if let msg = wanSaveMessage {
                            Text(msg)
                                .font(.caption)
                                .foregroundStyle(OpenUUTheme.emerald)
                        }
                    }
                }
                .listRowBackground(OpenUUTheme.surface)

                Section("自建专属机房（发给 AI 自动部署）") {
                    Text("点击下方提示词即可自动复制并打开 GitHub 仓库，把提示词发给你的 AI 助手即可一键部署专属寻址与中继机房：")
                        .font(.caption)
                        .foregroundStyle(OpenUUTheme.textSecondary)

                    Button {
                        UIPasteboard.general.string = Self.selfHostAIPrompt
                        copiedDeployPrompt = true
                        if let url = URL(string: Self.githubRepoURL) {
                            UIApplication.shared.open(url)
                        }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                            copiedDeployPrompt = false
                        }
                    } label: {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(Self.selfHostAIPrompt)
                                .font(.system(size: 11.5, design: .monospaced))
                                .foregroundStyle(OpenUUTheme.textPrimary)
                                .multilineTextAlignment(.leading)
                            HStack {
                                Label(
                                    copiedDeployPrompt ? "已复制提示词并打开 GitHub" : "点击复制提示词并打开 GitHub 仓库",
                                    systemImage: copiedDeployPrompt ? "checkmark.circle.fill" : "arrow.up.right.square.fill"
                                )
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(OpenUUTheme.emerald)
                                Spacer()
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }
                .listRowBackground(OpenUUTheme.surface)

                Section("远控偏好") {
                    Picker("默认操控模式", selection: $viewModel.touchMode) {
                        ForEach(TouchControlMode.allCases) { mode in
                            Text(mode.label).tag(mode)
                        }
                    }
                    Picker("画面缩放模式", selection: $viewModel.videoFitMode) {
                        ForEach(VideoFitMode.allCases) { mode in
                            Text(mode.fullLabel).tag(mode)
                        }
                    }
                    .onChange(of: viewModel.videoFitMode) { _, newMode in
                        viewModel.videoRenderer.setVideoFitMode(newMode)
                    }
                    Toggle("显示性能调试 HUD (FPS / 码率)", isOn: $viewModel.showDebugHUD)
                    Button {
                        viewModel.showGestureGuide = true
                    } label: {
                        Label("查看远控手势指南", systemImage: "hand.draw.fill")
                            .foregroundStyle(OpenUUTheme.emerald)
                    }
                }
                .listRowBackground(OpenUUTheme.surface)

                if let trusted = viewModel.identity?.trusted_peers, !trusted.isEmpty {
                    Section("已信任主机 (\(trusted.count))") {
                        ForEach(trusted) { peer in
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(peer.device_name.isEmpty ? "Mac" : peer.device_name)
                                        .font(.subheadline.weight(.medium))
                                    Text(peer.formattedCode.isEmpty ? peer.device_id : peer.formattedCode)
                                        .font(.caption.monospacedDigit())
                                        .foregroundStyle(OpenUUTheme.textSecondary)
                                }
                                Spacer()
                                Button("撤销", role: .destructive) {
                                    viewModel.removeTrustedPeer(deviceID: peer.device_id)
                                }
                                .font(.caption)
                            }
                        }
                    }
                    .listRowBackground(OpenUUTheme.surface)
                }

                Section {
                    if viewModel.logs.isEmpty {
                        Text("暂无运行日志")
                            .font(.caption)
                            .foregroundStyle(OpenUUTheme.textSecondary)
                    } else {
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 4) {
                                ForEach(Array(viewModel.logs.reversed().enumerated()), id: \.offset) { _, line in
                                    Text(line)
                                        .font(.system(size: 11, design: .monospaced))
                                        .foregroundStyle(OpenUUTheme.textSecondary)
                                        .textSelection(.enabled)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .frame(maxHeight: 240)
                    }
                } header: {
                    HStack {
                        Text("实时日志 (\(viewModel.logs.count))")
                        Spacer()
                        Button("复制") {
                            UIPasteboard.general.string = viewModel.logs.joined(separator: "\n")
                        }
                        .font(.caption)
                        Button("清空") {
                            viewModel.clearLogs()
                        }
                        .font(.caption)
                        .foregroundStyle(OpenUUTheme.rose)
                    }
                }
                .listRowBackground(OpenUUTheme.surface)
            }
            .scrollContentBackground(.hidden)
            .background(OpenUUTheme.background.ignoresSafeArea())
            .navigationTitle("设置与日志")
            .onAppear {
                let cfg = viewModel.wanConfig
                coordURL = cfg.coord_url
                relayURL = cfg.relay_url
                relayToken = cfg.relay_auth_token ?? ""
                enablePublicFallback = cfg.enable_public_fallback
                allowInsecureTLS = cfg.allow_insecure_tls
            }
        }
    }
}
