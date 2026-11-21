import SwiftUI
import UIKit

// MARK: - Compact PIN Prompt Sheet (240pt)

struct PinPromptSheet: View {
    let hostName: String
    let onConfirm: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var pin = ""
    @FocusState private var isPinFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("连接至 \(hostName)")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(OpenUUTheme.textPrimary)

            Text("首次连接请输入 Mac 端显示的 6 位配对码或访问密码，连接成功后将自动免密信任。")
                .font(.system(size: 12.5))
                .foregroundStyle(OpenUUTheme.textSecondary)

            SecureField("输入配对码 / 访问密码", text: $pin)
                .font(.system(size: 15, design: .monospaced))
                .foregroundStyle(OpenUUTheme.textPrimary)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .focused($isPinFocused)
                .submitLabel(.go)
                .onSubmit { onConfirm(pin.trimmingCharacters(in: .whitespacesAndNewlines)) }
                .padding(.horizontal, 12)
                .padding(.vertical, 11)
                .background(OpenUUTheme.elevated, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .stroke(OpenUUTheme.hairline, lineWidth: 0.5)
                )

            HStack(spacing: 10) {
                Button("取消") {
                    dismiss()
                }
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(OpenUUTheme.textSecondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 11)
                .background(OpenUUTheme.elevated, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .stroke(OpenUUTheme.hairline, lineWidth: 0.5)
                )
                .buttonStyle(.plain)

                Button("连接") {
                    onConfirm(pin.trimmingCharacters(in: .whitespacesAndNewlines))
                }
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(OpenUUTheme.background)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 11)
                .background(OpenUUTheme.primaryCTA, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 18)
        .padding(.top, 20)
        .padding(.bottom, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(OpenUUTheme.surface.ignoresSafeArea())
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                isPinFocused = true
            }
        }
    }
}

// MARK: - Device Editor Sheet

struct DeviceEditorSheet: View {
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
        _target = State(initialValue: DeviceCodeFormatter.formatInput(existing?.target ?? ""))
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
                        .font(.system(.body, design: .monospaced))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .onChange(of: target) { _, newVal in
                            let formatted = DeviceCodeFormatter.formatInput(newVal)
                            if formatted != newVal { target = formatted }
                        }
                    TextField("端口", text: $port)
                        .keyboardType(.numberPad)
                    SecureField("保存密码 / PIN（可选）", text: $password)
                }
                .listRowBackground(OpenUUTheme.surface)

                Section("偏好") {
                    Toggle("置顶主机", isOn: $isFavorite)
                        .tint(OpenUUTheme.liveDot)
                    TextField("备注", text: $notes)
                }
                .listRowBackground(OpenUUTheme.surface)
            }
            .scrollContentBackground(.hidden)
            .background(OpenUUTheme.background.ignoresSafeArea())
            .navigationTitle(existing == nil ? "添加主机" : "编辑主机")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                        .foregroundStyle(OpenUUTheme.textSecondary)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        let p = UInt16(port) ?? OpenUUConstants.defaultPort
                        onSave(alias, DeviceCodeFormatter.sanitizeForUse(target), p, password, isFavorite, notes)
                        dismiss()
                    }
                    .foregroundStyle(OpenUUTheme.textPrimary)
                    .disabled(DeviceCodeFormatter.sanitizeForUse(target).isEmpty)
                }
            }
        }
    }
}

// MARK: - Settings & Logs Sheet

struct SettingsLogsSheet: View {
    @ObservedObject var viewModel: MobileSessionViewModel
    @Environment(\.dismiss) private var dismiss

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
    4. 部署完成后，直接输出需要填入 OpenUU「设置与日志」页面的三项配置：设备码寻址 (Coord URL)、打洞与中继 (Relay URL)、中继鉴权 Token。
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
                                    .foregroundStyle(OpenUUTheme.textPrimary)
                                Button {
                                    UIPasteboard.general.string = id.device_code
                                } label: {
                                    Image(systemName: "doc.on.doc")
                                        .font(.caption)
                                        .foregroundStyle(OpenUUTheme.textSecondary)
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
                        .font(.system(.callout, design: .monospaced))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("中继服务 Relay URL", text: $relayURL)
                        .font(.system(.callout, design: .monospaced))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField("中继鉴权 Token（可选）", text: $relayToken)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Toggle("允许公共节点兜底 (Public Fallback)", isOn: $enablePublicFallback)
                        .tint(OpenUUTheme.liveDot)
                    Toggle("允许自签证书 TLS (局域网/测试)", isOn: $allowInsecureTLS)
                        .tint(OpenUUTheme.liveDot)

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
                        .fontWeight(.semibold)
                        .foregroundStyle(OpenUUTheme.textPrimary)

                        Spacer()
                        if let msg = wanSaveMessage {
                            Text(msg)
                                .font(.caption)
                                .foregroundStyle(OpenUUTheme.liveDot)
                        }
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
                    Toggle("横屏固定顶部窗口栏", isOn: $viewModel.pinLandscapeTabBar)
                        .tint(OpenUUTheme.liveDot)
                    Toggle("显示性能调试 HUD (FPS / 码率)", isOn: $viewModel.showDebugHUD)
                        .tint(OpenUUTheme.liveDot)
                    Button {
                        dismiss()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                            viewModel.showGestureGuide = true
                        }
                    } label: {
                        Label("查看远控手势指南", systemImage: "hand.draw")
                            .foregroundStyle(OpenUUTheme.textPrimary)
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
                                        .foregroundStyle(OpenUUTheme.textPrimary)
                                    Text(peer.formattedCode.isEmpty ? peer.device_id : peer.formattedCode)
                                        .font(.caption.monospacedDigit())
                                        .foregroundStyle(OpenUUTheme.textSecondary)
                                }
                                Spacer()
                                Button("撤销", role: .destructive) {
                                    viewModel.removeTrustedPeer(deviceID: peer.device_id)
                                }
                                .font(.caption)
                                .foregroundStyle(OpenUUTheme.destructive)
                            }
                        }
                    }
                    .listRowBackground(OpenUUTheme.surface)
                }

                Section("自建专属机房") {
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
                        HStack {
                            Label(
                                copiedDeployPrompt ? "已复制部署提示词并打开 GitHub" : "复制 AI 部署提示词并打开 GitHub",
                                systemImage: copiedDeployPrompt ? "checkmark.circle" : "arrow.up.right.square"
                            )
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(copiedDeployPrompt ? OpenUUTheme.liveDot : OpenUUTheme.textPrimary)
                            Spacer()
                        }
                    }
                }
                .listRowBackground(OpenUUTheme.surface)

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
                        .frame(maxHeight: 220)
                    }
                } header: {
                    HStack {
                        Text("实时日志 (\(viewModel.logs.count))")
                        Spacer()
                        Button("复制") {
                            UIPasteboard.general.string = viewModel.logs.joined(separator: "\n")
                        }
                        .font(.caption)
                        .foregroundStyle(OpenUUTheme.textPrimary)
                        Button("清空") {
                            viewModel.clearLogs()
                        }
                        .font(.caption)
                        .foregroundStyle(OpenUUTheme.destructive)
                    }
                }
                .listRowBackground(OpenUUTheme.surface)
            }
            .scrollContentBackground(.hidden)
            .background(OpenUUTheme.background.ignoresSafeArea())
            .navigationTitle("设置与日志")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                        .foregroundStyle(OpenUUTheme.textPrimary)
                }
            }
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

// MARK: - Gesture Guide Sheet

struct GestureGuideSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section("单指操作（直触 & 触控板通用）") {
                    gestureRow(icon: "hand.tap", title: "单指轻点", detail: "左键单击（右键浮层菜单也可直接点击）")
                    gestureRow(icon: "hand.tap", title: "单指双击", detail: "左键双击")
                    gestureRow(icon: "hand.point.up.left", title: "长按 0.3 秒后移动", detail: "左键拖拽（缩放画面下也可精准拖拽）")
                    gestureRow(icon: "contextualmenu.and.cursorarrow", title: "长按 0.3 秒静止抬起", detail: "右键单击（带触觉反馈）")
                    gestureRow(icon: "cursorarrow.click.2", title: "双击按住后滑动", detail: "macOS 触控板风格左键拖拽")
                    gestureRow(icon: "hand.draw", title: "单指滑动", detail: "直触：未缩放时拖拽，放大后平移视野；触控板：移动光标并边缘跟随")
                }
                .listRowBackground(OpenUUTheme.surface)

                Section("双指操作") {
                    gestureRow(icon: "hand.raised", title: "双指轻点", detail: "右键单击")
                    gestureRow(icon: "hand.point.up.braille", title: "按住一指 + 轻点第二指", detail: "单手/双手快捷右键单击")
                    gestureRow(icon: "arrow.up.left.and.arrow.down.right", title: "双指捏合", detail: "缩放画面（1.0x – 5.0x，自动防滚轮误触）")
                    gestureRow(icon: "arrow.up.and.down.and.arrow.left.and.right", title: "双指平行滑动", detail: "平滑滚轮滚动（上下 / 左右）")
                }
                .listRowBackground(OpenUUTheme.surface)

                Section("三指与窗口管理") {
                    gestureRow(icon: "keyboard", title: "三指轻点", detail: "呼出 / 收起键盘与 Mac 快捷键栏")
                    gestureRow(icon: "menubar.rectangle", title: "三指上下滑", detail: "横屏展开/收起顶部窗口栏，竖屏切换沉浸全屏")
                    gestureRow(icon: "macwindow.on.rectangle", title: "多窗口自动切换", detail: "Mac 打开新子窗口时自动聚焦并短暂浮现顶部窗口标签栏")
                }
                .listRowBackground(OpenUUTheme.surface)
            }
            .scrollContentBackground(.hidden)
            .background(OpenUUTheme.background.ignoresSafeArea())
            .navigationTitle("远控手势说明")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("知道了") { dismiss() }
                        .foregroundStyle(OpenUUTheme.textPrimary)
                }
            }
        }
    }

    private func gestureRow(icon: String, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(OpenUUTheme.textPrimary)
                .frame(width: 28, height: 28)
                .background(OpenUUTheme.keycap, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .stroke(OpenUUTheme.hairline, lineWidth: 0.5)
                )

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
