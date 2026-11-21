import AppKit
import SwiftUI

// ============================================================================
// TAB 3: 安全与画质 (Codec / FPS / Virtual Display / Clipboard / Permissions)
// ============================================================================

struct SecurityAndQualityView: View {
    @ObservedObject var state: AppState

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // 1. Frame Rate & Capture Mode
                GroupBox("画面流畅度与被控窗口隔离") {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Text("最高帧率档位:")
                                .frame(width: 110, alignment: .leading)
                            Picker("", selection: $state.targetFPS) {
                                Text("30 FPS (省流最稳)").tag(30)
                                Text("45 FPS (均衡推荐)").tag(45)
                                Text("60 FPS (局域网丝滑)").tag(60)
                            }
                            .pickerStyle(.segmented)
                            .frame(maxWidth: 360)
                            Spacer()
                        }

                        HStack {
                            Text("被控窗口方案:")
                                .frame(width: 110, alignment: .leading)
                            Picker("", selection: $state.captureScheme) {
                                ForEach(AppState.CaptureScheme.allCases) { scheme in
                                    Text(scheme.label).tag(scheme)
                                }
                            }
                            .labelsHidden()
                            if state.captureScheme == .virtualDisplay {
                                Button("一键移回主屏") {
                                    state.returnWindowsToMainDisplay()
                                }
                                .controlSize(.small)
                            }
                        }

                        Toggle("动态分辨率加速（高速滚动/播放视频时智能降采样，静止恢复 Retina 锐利文字）", isOn: $state.dynamicResolutionBoost)
                            .toggleStyle(.checkbox)
                        Toggle("显示画面调试浮窗（远程窗口左下角展示 H.264/HEVC、实时码率与解码耗时）", isOn: $state.showDebugHUD)
                            .toggleStyle(.checkbox)
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                // 2. Interaction & Multi-Host Sync
                GroupBox("多机键鼠与剪贴板无缝协同") {
                    VStack(alignment: .leading, spacing: 10) {
                        Toggle("跨多机双向剪贴板同步（复制文字 / 图片 / 文件自动同步至所有已连设备）", isOn: $state.clipboardSyncEnabled)
                            .toggleStyle(.checkbox)
                        Toggle("远端消息通知横幅与本地 Dock 图标未读红点同步", isOn: $state.notificationSyncEnabled)
                            .toggleStyle(.checkbox)
                        HStack(spacing: 24) {
                            Toggle("静默点击模式（后台注入不抢物理鼠标）", isOn: $state.silentClickMode)
                                .toggleStyle(.checkbox)
                            Toggle("同步远端光标形状", isOn: $state.hoverCursorSync)
                                .toggleStyle(.checkbox)
                            Toggle("共享期间阻止被控端息屏", isOn: $state.preventDisplaySleep)
                                .toggleStyle(.checkbox)
                        }
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                // 3. System Permissions
                GroupBox {
                    VStack(alignment: .leading, spacing: 8) {
                        permissionRow(
                            ok: state.hasEffectiveScreenRecordingPermission,
                            title: "屏幕录制权限（被控端捕获窗口画面必需）",
                            onGrant: {
                                state.openScreenRecordingSettings()
                            }
                        )
                        Divider()
                        permissionRow(
                            ok: state.hasDirectCapturePermission,
                            title: "直接窗口访问（免系统弹窗自动枚举被控应用）",
                            onGrant: {
                                Task { await state.checkDirectCapturePermission() }
                            }
                        )
                        Divider()
                        permissionRow(
                            ok: state.hasAccessibilityPermission,
                            title: "辅助功能权限（被控端接收远程键鼠点击与中文输入法直通必需）",
                            onGrant: {
                                state.openAccessibilitySettings()
                            }
                        )
                    }
                    .padding(10)
                } label: {
                    HStack {
                        Text("本机作为被控端所需系统权限")
                        Spacer()
                        Button("重新检测") {
                            state.refreshPermission()
                        }
                        .controlSize(.mini)
                    }
                }

                // 4. Trusted Devices Whitelist
                if !state.trustedPeers.isEmpty {
                    GroupBox("已信任免密证书设备白名单 (\(state.trustedPeers.count))") {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(state.trustedPeers) { peer in
                                HStack {
                                    Image(systemName: "checkmark.seal.fill")
                                        .foregroundStyle(.green)
                                    Text(peer.device_name)
                                        .font(.system(size: 12.5, weight: .semibold))
                                    if !peer.device_code.isEmpty {
                                        Text("(\(peer.formattedCode))")
                                            .font(.system(size: 11.5, design: .monospaced))
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Button("撤销免密授权") {
                                        state.revokeTrustedPeer(peer)
                                    }
                                    .controlSize(.mini)
                                }
                                .padding(.vertical, 2)
                            }
                        }
                        .padding(10)
                    }
                }
            }
            .padding(22)
        }
    }

    private func permissionRow(ok: Bool, title: String, onGrant: @escaping () -> Void) -> some View {
        HStack {
            Image(systemName: ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(ok ? .green : .orange)
            Text("\(title)：\(ok ? "已授权" : "未授权")")
                .font(.system(size: 12.5))
            Spacer()
            if !ok {
                Button("去授权", action: onGrant)
                    .controlSize(.small)
            }
        }
    }
}

// ============================================================================
// TAB 4: 网络与日志 (5-Layer WAN Config + Diagnostic Console)
// ============================================================================

struct NetworkAndLogsView: View {
    @ObservedObject var state: AppState
    @State private var copiedDeployPrompt = false

    static let githubRepoURL = "https://github.com/onekb/OpenUU"
    static let selfHostAIPrompt = """
    请帮我部署一套私有的 OpenUU 跨网寻址（Coord）与打洞中继（Relay）服务器。
    开源仓库地址：https://github.com/onekb/OpenUU （请先拉取或阅读仓库下的 deploy/ 目录与 README.md）。

    部署要求：
    1. 云服务器方案请参考 `deploy/docker-compose.yml`、`deploy/Dockerfile.coord` 与 `deploy/Caddyfile`；零暴露公网 IP 方案请参考 `deploy/cloudflare-worker` 与 `deploy/cloudflare-relay-worker`（Cloudflare Workers + D1 + Tunnel）。
    2. 先向我确认服务器 SSH 信息与解析好的 Coord / Relay 二级域名（或是否采用纯 IP 自签证书 / Cloudflare 方案）。
    3. 自动完成容器构建启动、HTTPS 证书签发、端口放行（TCP 80/443，UDP 443/3478/7842）及中继鉴权 Bearer Token 配置，并验证 `/health` 接口返回正常。
    4. 部署完成后，直接输出需要填入 OpenUU「网络与日志」页面的三项配置：设备码寻址 (Coord URL)、打洞与中继 (Relay URL)、中继鉴权 Token。
    """

    private func copyPrompt(andOpenGitHub: Bool) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(Self.selfHostAIPrompt, forType: .string)
        copiedDeployPrompt = true
        if andOpenGitHub, let url = URL(string: Self.githubRepoURL) {
            NSWorkspace.shared.open(url)
            state.statusLog = "[自建机房] 已复制 AI 部署提示词并打开 GitHub 仓库页面"
        } else {
            state.statusLog = "[自建机房] 已复制 AI 部署提示词，可直接发送给 AI 助手自动部署"
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
            copiedDeployPrompt = false
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            GroupBox("跨网连接与服务域名配置（局域网 mDNS ➔ 原生公网 IPv6 ➔ STUN 打洞 ➔ 专属中继 ➔ 全球节点保底）") {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("设备码寻址 (Coord):")
                            .frame(width: 128, alignment: .leading)
                        TextField("https://openuu.1kb.ren", text: $state.wanCoordURL)
                            .font(.system(size: 12.5, design: .monospaced))
                            .textFieldStyle(.roundedBorder)
                    }
                    HStack {
                        Text("打洞与中继 (Relay):")
                            .frame(width: 128, alignment: .leading)
                        TextField("https://openuu-relay.1kb.ren", text: $state.wanRelayURL)
                            .font(.system(size: 12.5, design: .monospaced))
                            .textFieldStyle(.roundedBorder)
                    }
                    HStack {
                        Text("中继鉴权 Token:")
                            .frame(width: 128, alignment: .leading)
                        TextField("中继服务 Bearer Token（无鉴权可留空）", text: $state.wanRelayAuthToken)
                            .font(.system(size: 12.5, design: .monospaced))
                            .textFieldStyle(.roundedBorder)
                    }
                    HStack(spacing: 16) {
                        Toggle("保留全球公共节点作为终极兜底", isOn: $state.wanEnablePublicFallback)
                            .toggleStyle(.checkbox)
                        Toggle("允许自签 TLS 证书", isOn: $state.wanAllowInsecureTLS)
                            .toggleStyle(.checkbox)
                        Spacer()
                        Button("使用公共服务域名") {
                            state.wanCoordURL = "https://openuu.1kb.ren"
                            state.wanRelayURL = "https://openuu-relay.1kb.ren"
                            state.wanRelayAuthToken = AppState.defaultRelayToken
                            state.wanEnablePublicFallback = true
                            state.wanAllowInsecureTLS = false
                            state.saveWanSettings()
                        }
                        .controlSize(.small)
                        Button("保存网络配置") {
                            state.saveWanSettings()
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                    }
                }
                .padding(8)
            }

            GroupBox {
                VStack(alignment: .leading, spacing: 6) {
                    Text("想独享满速带宽？点击下方提示词区域即可自动复制并打开 GitHub 仓库，把提示词直接发给你的 AI 助手（Claude Code / Cursor / Antigravity 等）即可自动部署专属服务器：")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)

                    Button {
                        copyPrompt(andOpenGitHub: true)
                    } label: {
                        ScrollView {
                            Text(Self.selfHostAIPrompt)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(.primary)
                                .multilineTextAlignment(.leading)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(8)
                        }
                        .frame(height: 72)
                        .background(Color.accentColor.opacity(0.07))
                        .clipShape(RoundedRectangle(cornerRadius: 7))
                        .overlay(
                            RoundedRectangle(cornerRadius: 7)
                                .strokeBorder(Color.accentColor.opacity(0.28), lineWidth: 1)
                        )
                    }
                    .buttonStyle(.plain)
                    .help("点击复制 AI 部署提示词并打开 GitHub 仓库 (\(Self.githubRepoURL))")
                }
                .padding(6)
            } label: {
                HStack(spacing: 8) {
                    Label("自建专属机房 · AI 自动部署提示词", systemImage: "server.rack")
                        .font(.system(size: 12.5, weight: .semibold))
                    if copiedDeployPrompt {
                        Text("✓ 已复制提示词")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.green)
                    }
                    Spacer()
                    Button("仅复制提示词") {
                        copyPrompt(andOpenGitHub: false)
                    }
                    .controlSize(.mini)
                    Button("复制提示词并打开 GitHub") {
                        copyPrompt(andOpenGitHub: true)
                    }
                    .controlSize(.mini)
                    .buttonStyle(.borderedProminent)
                }
            }

            HStack {
                Text("实时分级诊断日志")
                    .font(.system(size: 13.5, weight: .bold))
                Picker("级别", selection: $state.selectedLogLevel) {
                    ForEach(OpenUULogLevel.allCases, id: \.self) { level in
                        Text(level.label).tag(level)
                    }
                }
                .labelsHidden()
                .frame(width: 125)
                Spacer()
                Button("复制诊断报告") {
                    state.copyDiagnosticLogs()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                Button("打开日志目录") {
                    state.revealLogFileInFinder()
                }
                .controlSize(.small)
                Button("清空") {
                    state.clearDiagnosticLogs()
                }
                .controlSize(.small)
            }

            let filteredEntries = state.logEntries.filter { $0.level >= state.selectedLogLevel }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(filteredEntries) { entry in
                            Text(entry.formatted)
                                .font(.system(size: 10.5, design: .monospaced))
                                .foregroundStyle(
                                    entry.level == .error
                                        ? .red
                                        : (entry.level == .warn ? .orange : (entry.level == .debug ? .secondary : .primary))
                                )
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .id(entry.id)
                        }
                    }
                    .padding(8)
                }
                .background(Color.black.opacity(0.06))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .onChange(of: filteredEntries.last?.id) { _, lastID in
                    if let lastID {
                        proxy.scrollTo(lastID, anchor: .bottom)
                    }
                }
            }
            .frame(maxHeight: .infinity)
        }
        .padding(22)
    }
}
