import SwiftUI
import UIKit

// MARK: - Obsidian-Zinc Theme Tokens

enum OpenUUTheme {
    static let background    = Color(red: 9.0 / 255.0, green: 9.0 / 255.0, blue: 11.0 / 255.0)       // #09090B
    static let barBg         = Color(red: 17.0 / 255.0, green: 17.0 / 255.0, blue: 20.0 / 255.0)     // #111114
    static let surface       = Color(red: 18.0 / 255.0, green: 18.0 / 255.0, blue: 21.0 / 255.0)     // #121215
    static let elevated      = Color(red: 26.0 / 255.0, green: 26.0 / 255.0, blue: 32.0 / 255.0)     // #1A1A20
    static let activeTab     = Color(red: 30.0 / 255.0, green: 30.0 / 255.0, blue: 36.0 / 255.0)     // #1E1E24
    static let keycap        = Color(red: 34.0 / 255.0, green: 34.0 / 255.0, blue: 40.0 / 255.0)     // #222228
    static let hairline      = Color(red: 39.0 / 255.0, green: 39.0 / 255.0, blue: 46.0 / 255.0)     // #27272E
    static let divider       = Color(red: 35.0 / 255.0, green: 35.0 / 255.0, blue: 41.0 / 255.0)     // #232329
    static let popoverBorder = Color(red: 63.0 / 255.0, green: 63.0 / 255.0, blue: 70.0 / 255.0)     // #3F3F46
    static let primaryCTA    = Color(red: 244.0 / 255.0, green: 244.0 / 255.0, blue: 246.0 / 255.0)  // #F4F4F6
    static let textPrimary   = Color(red: 244.0 / 255.0, green: 244.0 / 255.0, blue: 246.0 / 255.0)  // #F4F4F6
    static let textSecondary = Color(red: 142.0 / 255.0, green: 142.0 / 255.0, blue: 152.0 / 255.0)  // #8E8E98
    static let textMuted     = Color(red: 99.0 / 255.0, green: 99.0 / 255.0, blue: 110.0 / 255.0)    // #63636E
    static let liveDot       = Color(red: 48.0 / 255.0, green: 209.0 / 255.0, blue: 88.0 / 255.0)    // #30D158
    static let offlineDot    = Color(red: 82.0 / 255.0, green: 82.0 / 255.0, blue: 91.0 / 255.0)     // #52525B
    static let warning       = Color(red: 255.0 / 255.0, green: 159.0 / 255.0, blue: 10.0 / 255.0)   // #FF9F0A
    static let destructive   = Color(red: 255.0 / 255.0, green: 69.0 / 255.0, blue: 58.0 / 255.0)    // #FF453A
    static let dangerSurface = Color(red: 31.0 / 255.0, green: 18.0 / 255.0, blue: 20.0 / 255.0)     // #1F1214
    static let dangerBorder  = Color(red: 76.0 / 255.0, green: 29.0 / 255.0, blue: 36.0 / 255.0)     // #4C1D24
}

// MARK: - Root Mobile Main View

struct MobileMainView: View {
    @ObservedObject var viewModel: MobileSessionViewModel

    private var isShowingRemote: Bool {
        viewModel.selectedTab == .remote && viewModel.phase.isConnected
    }

    private var isImmersiveFromState: Bool {
        isShowingRemote
            && !viewModel.showAppLauncher
            && viewModel.selectedWindowID != 0
            && (viewModel.isLandscape || viewModel.manualFullscreen)
    }

    var body: some View {
        GeometryReader { geo in
            let isLandscape = geo.size.width > geo.size.height
            let isImmersive = isShowingRemote
                && !viewModel.showAppLauncher
                && viewModel.selectedWindowID != 0
                && (isLandscape || viewModel.manualFullscreen)

            ZStack(alignment: .top) {
                (isImmersive ? Color.black : OpenUUTheme.background)
                    .ignoresSafeArea()

                if isShowingRemote {
                    RemoteWorkspaceContainer(
                        viewModel: viewModel,
                        isLandscape: isLandscape,
                        isImmersive: isImmersive,
                        viewportSize: geo.size
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    HostsHomeView(viewModel: viewModel)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }

                if let banner = viewModel.notificationBanner {
                    RemoteNotificationBannerView(banner: banner, isCompact: isImmersive) {
                        viewModel.dismissNotificationBanner()
                    } onOpenRemote: {
                        if viewModel.phase.isConnected {
                            viewModel.enterRemoteWorkspace()
                        }
                        viewModel.dismissNotificationBanner()
                    }
                    .frame(maxWidth: isImmersive ? 420 : .infinity)
                    .padding(.horizontal, 12)
                    .padding(.top, isImmersive ? 10 : 8)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .zIndex(100)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .statusBarHidden(isImmersive)
            .persistentSystemOverlays(isImmersive ? .hidden : .automatic)
            .animation(.easeOut(duration: 0.22), value: viewModel.notificationBanner)
            .onAppear {
                viewModel.updateViewportGeometry(size: geo.size, isImmersiveFullscreen: isImmersive)
            }
            .onChange(of: geo.size) { _, newSize in
                let landscapeNow = newSize.width > newSize.height
                let immersiveNow = isShowingRemote
                    && !viewModel.showAppLauncher
                    && viewModel.selectedWindowID != 0
                    && (landscapeNow || viewModel.manualFullscreen)
                viewModel.updateViewportGeometry(size: newSize, isImmersiveFullscreen: immersiveNow)
            }
            .onChange(of: isImmersive) { _, newVal in
                viewModel.updateViewportGeometry(size: geo.size, isImmersiveFullscreen: newVal)
            }
            .onOpenURL { url in
                let raw = url.absoluteString.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !raw.isEmpty else { return }
                viewModel.targetInput = DeviceCodeFormatter.formatInput(raw)
                viewModel.connectSmart(target: raw)
            }
            .sheet(isPresented: $viewModel.showGestureGuide) {
                GestureGuideSheet()
            }
        }
        .ignoresSafeArea(isImmersiveFromState ? .all : [])
    }
}

// MARK: - Top Notification Banner

private struct RemoteNotificationBannerView: View {
    let banner: RemoteNotificationBanner
    var isCompact: Bool = false
    let onDismiss: () -> Void
    let onOpenRemote: () -> Void

    private var detailText: String {
        [banner.subtitle, banner.body]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "bell.fill")
                .font(.system(size: isCompact ? 13 : 15, weight: .medium))
                .foregroundStyle(OpenUUTheme.textPrimary)

            VStack(alignment: .leading, spacing: 2) {
                Text(banner.title)
                    .font(.system(size: isCompact ? 12.5 : 13.5, weight: .semibold))
                    .foregroundStyle(OpenUUTheme.textPrimary)
                    .lineLimit(1)
                if !detailText.isEmpty {
                    Text(detailText)
                        .font(.system(size: 12))
                        .foregroundStyle(OpenUUTheme.textSecondary)
                        .lineLimit(isCompact ? 1 : 2)
                }
            }

            Spacer(minLength: 4)

            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(OpenUUTheme.textSecondary)
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("关闭通知")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, isCompact ? 8 : 10)
        .background(OpenUUTheme.elevated, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(OpenUUTheme.hairline, lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.42), radius: 10, y: 4)
        .contentShape(Rectangle())
        .onTapGesture(perform: onOpenRemote)
    }
}

// MARK: - Unified Host Row Model

private struct UnifiedHostRow: Identifiable {
    let id: String
    let name: String
    let subtitle: String
    let isOnline: Bool
    let isTrusted: Bool
    let isFavorite: Bool
    let savedPassword: String
    let bookEntry: ManagedRemoteDevice?
    let trustedPeer: TrustedPeerModel?
    let lanPeer: DiscoveredPeer?
    let connectAction: (String) -> Void
}

// MARK: - Hosts Home View

struct HostsHomeView: View {
    @ObservedObject var viewModel: MobileSessionViewModel
    @ObservedObject private var deviceBook: DeviceBookStore

    @State private var showSettingsSheet = false
    @State private var showEditorSheet = false
    @State private var editingDevice: ManagedRemoteDevice?
    @State private var pinPromptHost: UnifiedHostRow?
    @State private var copiedLocalCode = false
    @State private var copyResetTask: Task<Void, Never>?

    init(viewModel: MobileSessionViewModel) {
        self.viewModel = viewModel
        self._deviceBook = ObservedObject(wrappedValue: viewModel.deviceBook)
    }

    private var localCodeText: String {
        guard let id = viewModel.identity else { return "" }
        let formatted = id.formatted_code.trimmingCharacters(in: .whitespacesAndNewlines)
        return formatted.isEmpty ? id.device_code : formatted
    }

    private var canConnectManual: Bool {
        !DeviceCodeFormatter.sanitizeForUse(viewModel.targetInput).isEmpty && !viewModel.phase.isConnecting
    }

    private var unifiedHostRows: [UnifiedHostRow] {
        let trustedPeers = viewModel.identity?.trusted_peers ?? []
        var rows: [UnifiedHostRow] = []
        var consumedBookIDs = Set<String>()
        var consumedTrustedIDs = Set<String>()

        func findTrusted(deviceID: String, code: String) -> TrustedPeerModel? {
            let normCode = code.filter(\.isNumber)
            return trustedPeers.first { tp in
                (!deviceID.isEmpty && tp.device_id == deviceID)
                    || (normCode.count == 9 && tp.device_code.filter(\.isNumber) == normCode)
            }
        }

        func findBookEntry(deviceID: String, code: String, ip: String) -> ManagedRemoteDevice? {
            let normCode = code.filter(\.isNumber)
            return deviceBook.devices.first { d in
                (!deviceID.isEmpty && d.remoteDeviceID == deviceID)
                    || (normCode.count == 9 && d.deviceCode.filter(\.isNumber) == normCode)
                    || (!ip.isEmpty && DeviceCodeFormatter.sanitizeForUse(d.target) == ip)
            }
        }

        // 1. LAN Discovered Peers (always online)
        for peer in viewModel.discoveredPeers {
            let peerCode = peer.device_code ?? ""
            let peerIP = peer.preferredIP
            let trusted = findTrusted(deviceID: peer.device_id, code: peerCode)
            let book = findBookEntry(deviceID: peer.device_id, code: peerCode, ip: peerIP)
            if let trusted { consumedTrustedIDs.insert(trusted.device_id) }
            if let book { consumedBookIDs.insert(book.id) }

            var parts: [String] = ["局域网", peerIP.isEmpty ? (peerCode.isEmpty ? "在线" : peerCode) : peerIP]
            if trusted != nil {
                parts.append("已信任 · 免密")
            }
            let displayName = (book?.alias.isEmpty == false ? book!.alias : nil)
                ?? (peer.device_name.isEmpty ? "Mac" : peer.device_name)

            rows.append(
                UnifiedHostRow(
                    id: "lan_\(peer.device_id.isEmpty ? "\(peerIP):\(peer.port)" : peer.device_id)",
                    name: displayName,
                    subtitle: parts.joined(separator: " · "),
                    isOnline: true,
                    isTrusted: trusted != nil,
                    isFavorite: book?.isFavorite == true,
                    savedPassword: book?.savedPassword ?? "",
                    bookEntry: book,
                    trustedPeer: trusted,
                    lanPeer: peer,
                    connectAction: { pin in
                        if !peerIP.isEmpty {
                            viewModel.connectDirect(hostIP: peerIP, port: peer.port, pin: pin)
                        } else {
                            let target = peerCode.isEmpty ? peer.device_id : peerCode
                            viewModel.connectSmart(target: target, port: peer.port, pin: pin)
                        }
                    }
                )
            )
        }

        // 2. Saved Device Book Entries
        for entry in deviceBook.devices where !consumedBookIDs.contains(entry.id) {
            let codeCandidate = entry.deviceCode.isEmpty ? entry.target : entry.deviceCode
            let trusted = findTrusted(deviceID: entry.remoteDeviceID, code: codeCandidate)
            if let trusted { consumedTrustedIDs.insert(trusted.device_id) }
            let presence = deviceBook.presenceByID[entry.id]

            var parts: [String] = [entry.formattedTarget]
            if trusted != nil {
                parts.append("已信任 · 免密")
            }
            if let presence, presence.isOnline {
                parts.append(presence.label)
            }

            rows.append(
                UnifiedHostRow(
                    id: "book_\(entry.id)",
                    name: entry.alias.isEmpty ? entry.formattedTarget : entry.alias,
                    subtitle: parts.joined(separator: " · "),
                    isOnline: presence?.isOnline == true,
                    isTrusted: trusted != nil,
                    isFavorite: entry.isFavorite,
                    savedPassword: entry.savedPassword,
                    bookEntry: entry,
                    trustedPeer: trusted,
                    lanPeer: nil,
                    connectAction: { pin in
                        viewModel.connectSmart(target: entry.target, port: entry.port, pin: pin)
                    }
                )
            )
        }

        // 3. Remaining Trusted Peers
        for tp in trustedPeers where !consumedTrustedIDs.contains(tp.device_id) {
            let codeLabel = tp.formattedCode.isEmpty ? String(tp.device_id.prefix(12)) : tp.formattedCode
            rows.append(
                UnifiedHostRow(
                    id: "trusted_\(tp.device_id.isEmpty ? tp.endpoint_id : tp.device_id)",
                    name: tp.device_name.isEmpty ? "Mac" : tp.device_name,
                    subtitle: "\(codeLabel) · 已信任 · 免密",
                    isOnline: false,
                    isTrusted: true,
                    isFavorite: false,
                    savedPassword: "",
                    bookEntry: nil,
                    trustedPeer: tp,
                    lanPeer: nil,
                    connectAction: { pin in
                        viewModel.connectSmart(target: tp.preferredTarget, port: OpenUUConstants.defaultPort, pin: pin)
                    }
                )
            )
        }

        return rows
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                topBar

                if viewModel.phase != .idle {
                    sessionStatusBanner
                }

                availableHostsSection
                manualConnectSection
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
        }
        .scrollDismissesKeyboard(.interactively)
        .background(OpenUUTheme.background.ignoresSafeArea())
        .onAppear {
            viewModel.probeDeviceBookOnline()
        }
        .onDisappear {
            copyResetTask?.cancel()
        }
        .sheet(item: $pinPromptHost) { host in
            PinPromptSheet(hostName: host.name) { enteredPin in
                pinPromptHost = nil
                host.connectAction(enteredPin)
            }
            .presentationDetents([.height(240)])
            .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showEditorSheet) {
            DeviceEditorSheet(existing: editingDevice) { alias, target, port, password, isFavorite, notes in
                deviceBook.addOrUpdateDevice(
                    id: editingDevice?.id,
                    alias: alias,
                    target: target,
                    port: port,
                    savedPassword: password,
                    groupTag: editingDevice?.groupTag ?? "常用",
                    isFavorite: isFavorite,
                    notes: notes
                )
                viewModel.probeDeviceBookOnline()
            }
        }
        .sheet(isPresented: $showSettingsSheet) {
            SettingsLogsSheet(viewModel: viewModel)
        }
    }

    // MARK: - Top Bar

    private var topBar: some View {
        HStack(spacing: 10) {
            HStack(spacing: 9) {
                if UIImage(named: "BrandIcon") != nil {
                    Image("BrandIcon")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 28, height: 28)
                        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                } else {
                    Image(systemName: "desktopcomputer")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(OpenUUTheme.textPrimary)
                        .frame(width: 28, height: 28)
                        .background(OpenUUTheme.elevated, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .stroke(OpenUUTheme.hairline, lineWidth: 0.5)
                        )
                }

                Text("OpenUU")
                    .font(.system(size: 18, weight: .bold))
                    .tracking(-0.4)
                    .foregroundStyle(OpenUUTheme.textPrimary)
            }

            Spacer(minLength: 8)

            HStack(spacing: 8) {
                if !localCodeText.isEmpty {
                    Button {
                        UIPasteboard.general.string = viewModel.identity?.device_code ?? localCodeText
                        copiedLocalCode = true
                        copyResetTask?.cancel()
                        copyResetTask = Task { @MainActor in
                            try? await Task.sleep(for: .milliseconds(1400))
                            if !Task.isCancelled {
                                copiedLocalCode = false
                            }
                        }
                    } label: {
                        Text(copiedLocalCode ? "已复制 \(localCodeText)" : "本机 \(localCodeText)")
                            .font(.system(size: 11.5, weight: .medium, design: .monospaced))
                            .foregroundStyle(copiedLocalCode ? OpenUUTheme.liveDot : OpenUUTheme.textPrimary)
                            .lineLimit(1)
                            .padding(.horizontal, 9)
                            .padding(.vertical, 6.5)
                            .background(OpenUUTheme.elevated, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .stroke(OpenUUTheme.hairline, lineWidth: 0.5)
                            )
                    }
                    .buttonStyle(.plain)
                }

                Button {
                    showSettingsSheet = true
                } label: {
                    Image(systemName: "slider.horizontal.3")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(OpenUUTheme.textPrimary)
                        .frame(width: 32, height: 32)
                        .background(OpenUUTheme.elevated, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .stroke(OpenUUTheme.hairline, lineWidth: 0.5)
                        )
                }
                .buttonStyle(.plain)
                .accessibilityLabel("设置与日志")
            }
        }
    }

    // MARK: - Active Session / Connecting / Error Banner

    private var sessionStatusBanner: some View {
        let isError: Bool = {
            if case .error = viewModel.phase { return true }
            return false
        }()

        return HStack(spacing: 10) {
            switch viewModel.phase {
            case .connected(let hostName):
                Circle()
                    .fill(OpenUUTheme.liveDot)
                    .frame(width: 8, height: 8)

                VStack(alignment: .leading, spacing: 2) {
                    Text("正在远控 \(hostName)")
                        .font(.system(size: 13.5, weight: .semibold))
                        .foregroundStyle(OpenUUTheme.textPrimary)
                        .lineLimit(1)
                    if !viewModel.linkBadge.isEmpty {
                        Text(viewModel.linkBadge)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(OpenUUTheme.textSecondary)
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Button("进入画面") {
                    viewModel.enterRemoteWorkspace()
                }
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(OpenUUTheme.background)
                .padding(.horizontal, 11)
                .padding(.vertical, 6.5)
                .background(OpenUUTheme.primaryCTA, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .buttonStyle(.plain)

                Button("断开") {
                    viewModel.disconnect()
                }
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(OpenUUTheme.textSecondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 6.5)
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(OpenUUTheme.hairline, lineWidth: 0.5)
                )
                .buttonStyle(.plain)

            case .connecting(let detail):
                ProgressView()
                    .controlSize(.small)
                    .tint(OpenUUTheme.textPrimary)

                Text(detail)
                    .font(.system(size: 13))
                    .foregroundStyle(OpenUUTheme.textPrimary)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Button("取消") {
                    viewModel.disconnect()
                }
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(OpenUUTheme.textSecondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .buttonStyle(.plain)

            case .error(let reason):
                Image(systemName: "exclamationmark.circle")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(OpenUUTheme.destructive)

                Text(reason)
                    .font(.system(size: 12.5))
                    .foregroundStyle(Color(red: 1.0, green: 0.54, blue: 0.50))
                    .frame(maxWidth: .infinity, alignment: .leading)

                Button {
                    viewModel.clearConnectionError()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(OpenUUTheme.textSecondary)
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("忽略错误")

            case .idle:
                EmptyView()
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            isError ? OpenUUTheme.dangerSurface : OpenUUTheme.elevated,
            in: RoundedRectangle(cornerRadius: 10, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(isError ? OpenUUTheme.dangerBorder : OpenUUTheme.hairline, lineWidth: 0.5)
        )
    }

    // MARK: - Available Hosts Section

    private var availableHostsSection: some View {
        let rows = unifiedHostRows
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("可用主机")
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(OpenUUTheme.textSecondary)
                    .padding(.leading, 2)

                Spacer()

                HStack(spacing: 6) {
                    Button {
                        viewModel.probeDeviceBookOnline()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(OpenUUTheme.textSecondary)
                            .frame(width: 28, height: 28)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("探测在线状态")

                    Button {
                        editingDevice = nil
                        showEditorSheet = true
                    } label: {
                        HStack(spacing: 3) {
                            Image(systemName: "plus")
                                .font(.system(size: 11, weight: .semibold))
                            Text("添加")
                                .font(.system(size: 12, weight: .medium))
                        }
                        .foregroundStyle(OpenUUTheme.textPrimary)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 5)
                        .background(OpenUUTheme.elevated, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .stroke(OpenUUTheme.hairline, lineWidth: 0.5)
                        )
                    }
                    .buttonStyle(.plain)
                }
            }

            VStack(spacing: 0) {
                if rows.isEmpty {
                    HStack(spacing: 10) {
                        ProgressView()
                            .controlSize(.small)
                            .tint(OpenUUTheme.textSecondary)
                        Text("正在扫描局域网 Mac，或点击右上角添加常用主机")
                            .font(.system(size: 12.5))
                            .foregroundStyle(OpenUUTheme.textSecondary)
                        Spacer()
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 18)
                } else {
                    ForEach(Array(rows.enumerated()), id: \.element.id) { idx, row in
                        hostRowView(row)
                        if idx < rows.count - 1 {
                            Rectangle()
                                .fill(OpenUUTheme.divider)
                                .frame(height: 0.5)
                                .padding(.leading, 32)
                        }
                    }
                }
            }
            .background(OpenUUTheme.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(OpenUUTheme.hairline, lineWidth: 0.5)
            )
        }
    }

    private func hostRowView(_ row: UnifiedHostRow) -> some View {
        let hasMenu = row.bookEntry != nil || row.trustedPeer != nil || row.lanPeer != nil

        return HStack(spacing: 10) {
            Button {
                if row.isTrusted || !row.savedPassword.isEmpty {
                    row.connectAction(row.isTrusted ? "" : row.savedPassword)
                } else {
                    pinPromptHost = row
                }
            } label: {
                HStack(spacing: 10) {
                    Circle()
                        .fill(row.isOnline ? OpenUUTheme.liveDot : OpenUUTheme.offlineDot)
                        .frame(width: 7, height: 7)

                    VStack(alignment: .leading, spacing: 2.5) {
                        HStack(spacing: 5) {
                            Text(row.name)
                                .font(.system(size: 14.5, weight: .medium))
                                .foregroundStyle(OpenUUTheme.textPrimary)
                                .lineLimit(1)

                            if row.isFavorite {
                                Image(systemName: "star.fill")
                                    .font(.system(size: 10.5))
                                    .foregroundStyle(OpenUUTheme.textSecondary)
                            }
                        }

                        Text(row.subtitle)
                            .font(.system(size: 11.5, design: .monospaced))
                            .foregroundStyle(OpenUUTheme.textSecondary)
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.leading, 14)
                .padding(.vertical, 12)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if hasMenu {
                Menu {
                    if let entry = row.bookEntry {
                        Button {
                            deviceBook.toggleFavorite(id: entry.id)
                        } label: {
                            Label(entry.isFavorite ? "取消置顶" : "置顶主机", systemImage: entry.isFavorite ? "star.slash" : "star")
                        }

                        Button {
                            editingDevice = entry
                            showEditorSheet = true
                        } label: {
                            Label("编辑主机", systemImage: "pencil")
                        }
                    } else if let lp = row.lanPeer {
                        Button {
                            let target = (lp.device_code?.count == 9 ? lp.device_code! : lp.preferredIP)
                            deviceBook.addOrUpdateDevice(
                                alias: lp.device_name,
                                target: target,
                                port: lp.port,
                                savedPassword: ""
                            )
                        } label: {
                            Label("保存到主机列表", systemImage: "plus.circle")
                        }
                    }

                    if let tp = row.trustedPeer {
                        Button(role: .destructive) {
                            viewModel.removeTrustedPeer(deviceID: tp.device_id)
                        } label: {
                            Label("撤销免密信任", systemImage: "lock.slash")
                        }
                    }

                    if let entry = row.bookEntry {
                        Button(role: .destructive) {
                            deviceBook.removeDevice(id: entry.id)
                        } label: {
                            Label("删除主机", systemImage: "trash")
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(OpenUUTheme.textSecondary)
                        .frame(width: 36, height: 36)
                        .contentShape(Rectangle())
                }
                .padding(.trailing, 6)
                .accessibilityLabel("更多操作")
            }
        }
    }

    // MARK: - Manual Connect Card

    private var manualConnectSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("手动连接")
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(OpenUUTheme.textSecondary)
                .padding(.leading, 2)

            VStack(spacing: 10) {
                HStack(spacing: 6) {
                    TextField("9 位设备码 / IP:Port / openuu://", text: $viewModel.targetInput)
                        .font(.system(size: 14, design: .monospaced))
                        .foregroundStyle(OpenUUTheme.textPrimary)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .submitLabel(.go)
                        .onChange(of: viewModel.targetInput) { _, newVal in
                            let formatted = DeviceCodeFormatter.formatInput(newVal)
                            if formatted != newVal {
                                viewModel.targetInput = formatted
                            }
                        }
                        .onSubmit {
                            if canConnectManual { viewModel.connectFromForm() }
                        }

                    if !viewModel.targetInput.isEmpty {
                        Button {
                            viewModel.targetInput = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 14))
                                .foregroundStyle(OpenUUTheme.textMuted)
                                .frame(width: 24, height: 24)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("清除")
                    }

                    Button("粘贴") {
                        if let raw = UIPasteboard.general.string {
                            let formatted = DeviceCodeFormatter.formatInput(raw)
                            if !formatted.isEmpty {
                                viewModel.targetInput = formatted
                            }
                        }
                    }
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(OpenUUTheme.textPrimary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .buttonStyle(.plain)
                }
                .padding(.leading, 12)
                .padding(.trailing, 6)
                .padding(.vertical, 10)
                .background(OpenUUTheme.elevated, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .stroke(OpenUUTheme.hairline, lineWidth: 0.5)
                )

                HStack(spacing: 8) {
                    SecureField("配对码（已信任可留空）", text: $viewModel.pinInput)
                        .font(.system(size: 14, design: .monospaced))
                        .foregroundStyle(OpenUUTheme.textPrimary)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .submitLabel(.go)
                        .onSubmit {
                            if canConnectManual { viewModel.connectFromForm() }
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 11)
                        .background(OpenUUTheme.elevated, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 9, style: .continuous)
                                .stroke(OpenUUTheme.hairline, lineWidth: 0.5)
                        )

                    Button("连接") {
                        viewModel.connectFromForm()
                    }
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(canConnectManual ? OpenUUTheme.background : OpenUUTheme.textMuted)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 11.5)
                    .background(
                        canConnectManual ? OpenUUTheme.primaryCTA : OpenUUTheme.hairline,
                        in: RoundedRectangle(cornerRadius: 9, style: .continuous)
                    )
                    .buttonStyle(.plain)
                    .disabled(!canConnectManual)
                }
            }
            .padding(12)
            .background(OpenUUTheme.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(OpenUUTheme.hairline, lineWidth: 0.5)
            )
        }
    }
}
