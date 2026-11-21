# OpenUU

局域网 & 跨公网「单应用窗口级」串流与无缝交互工具（类似 Parallels Coherence 模式，跨实体机版本）——多台 Mac，OpenUU 无缝同屏。

- 仓库地址：[https://github.com/onekb/OpenUU](https://github.com/onekb/OpenUU)
- 包名 / Bundle ID：`ren.onekb.openuu`（macOS / iOS / Android 三端统一）

## 架构概览

- `proto/openuu.proto`：跨平台 Protobuf v3 控制协议定义（支持 Ed25519 信道绑定鉴权与 H.264 / HEVC 双编码）。
- `crates/openuu-core`：Rust 跨平台核心：
  - **五层自动兜底传输**：`1. 局域网 mDNS 直连` ➔ `2. 国内原生公网 IPv6 直连` ➔ `3. IPv4 STUN/NAT 打洞 P2P` ➔ `4. 自建香港/私有 iroh-relay (HTTPS/WSS 443) 中继` ➔ `5. 全球公共节点终极兜底`。
  - **安全模型**：TLS 1.3 信道绑定 + Ed25519 公钥身份验证 + 防爆破滑动窗口限流（输错 5 次自动封禁）+ 已信任设备免密一键重连。
- `crates/openuu-coord`：轻量级 9 位数字设备码寻址服务（Ed25519 签名防伪，支持香港/国内轻量云一键 Docker 部署）。
- `crates/openuu-cli`：命令行调试工具（支持局域网与 `wan-host` / `wan-client` 跨网连通性测试）。
- `apps/macos`：macOS 原生 App（SwiftUI + AppKit + ScreenCaptureKit + VideoToolbox H.264/HEVC 路径自适应码率 + 本地中文输入法直通）。
- `apps/android`：Android 原生客户端（Kotlin + Jetpack Compose + JNI 静态链接 `openuu-core` + `MediaCodec` H.264 / HEVC 硬解，适配手机与平板）。
- `apps/ios`：iOS / iPadOS 原生客户端（SwiftUI + UIKit + `OpenUUCore.xcframework` + `VideoToolbox` / `AVSampleBufferDisplayLayer` H.264 / HEVC 硬解，支持 iPhone 与 iPad）。
- `deploy/`：香港/自建云服务器一键部署套件（`docker-compose.yml` 集成 `openuu-coord` + `iroh-relay` + `Caddy` 自动 HTTPS）。

## 快速构建与运行 (macOS)

```bash
chmod +x scripts/build-macos.sh
./scripts/build-macos.sh
open ./build/OpenUU.app
```

## 快速构建与验收 (Android & iOS / iPadOS)

移动端客户端与 macOS Host 复用同一套 Rust 核心 (`openuu-core`) 与跨平台 Protobuf 控制协议，开箱支持以下能力：
- **五层穿透连接**：自动按「局域网 mDNS 直连 ➔ 公网 IPv6 直连 ➔ IPv4 P2P 打洞 ➔ 自建私有 Relay 中继 ➔ 全球公共节点兜底」协商连接，支持直连地址、9 位设备码及 `openuu://...` 连接串。
- **硬件低延迟解码与横屏沉浸全屏**：Android 端基于 `MediaCodec`、iOS / iPadOS 端基于 `VideoToolbox` 原生硬解 H.264 & HEVC 视频流；手机/平板横屏时自动隐藏系统状态栏、导航栏/Home 指示条与工具栏实现 **100% 无边框沉浸全屏**，配备可拖拽半透明悬浮胶囊快捷菜单及「适应屏幕 / 铺满全屏」比例切换。
- **全套多指手势与双触控模式**：一键切换「直接触控」与「高精度虚拟触控板」，双模式全量支持：
  - **单指**：轻点左键、双击打开、**长按震动后移动左键拖拽**（拖窗口/框选文字/拖文件，放大状态下同样可用）、**双击按住拖拽**、长按原地抬起右键。
  - **双指**：**双指轻点右键**（及按住一指点二指右键）、**双指捏合张开 `1.0x`–`5.0x` 无极放大缩小**（含放大后视野平移与触控板光标边缘自动跟随平移）、**双指平行滑动平滑滚轮**。
  - **三指与指南**：**三指轻点**呼出/收起软键盘与 Mac 快捷键栏、**三指上下滑**显隐悬浮工具栏，并内置可视化「手势操作指南」面板。
- **中文输入法直通与 Mac 快捷键栏**：原生拉起系统软键盘直通提交中文及任意文本，并提供快捷功能栏（`Cmd` / `Ctrl` / `Opt` / `Esc` / `Tab` / 方向键及常用 `Cmd+C/V/Z/W` 组合键）。
- **双向剪贴板与文件投递**：支持手机/平板与远端 Mac 之间双向同步文本剪贴板，以及选择本地文件一键投递至远端应用窗口。
- **已信任设备免密重连**：首次口令配对并校验 Ed25519 身份后自动保存至本地设备簿，后续支持免密一键重连。

### Android 客户端

```bash
# 构建 Android APK（默认 arm64-v8a；传入 --all-abis 同时编译 arm64-v8a + x86_64）
chmod +x scripts/build-android.sh scripts/verify-android-e2e.sh
./scripts/build-android.sh
# 产物位置：./build/OpenUU-Android.apk

# 自动化端到端验收（拉起 AVD 模拟器 + mock-host，验证视频渲染、输入、剪贴板与免密重连）
./scripts/verify-android-e2e.sh
```

### iOS / iPadOS 客户端

```bash
# 构建 iOS Simulator 与真机 App（传入 --sim-only 仅构建 Simulator 版本）
chmod +x scripts/build-ios.sh scripts/verify-ios-e2e.sh
./scripts/build-ios.sh
# 产物位置：./build/OpenUUMobile-Sim.app（Simulator）与 ./build/OpenUUMobile-iOS.app（真机）

# 自动化端到端验收（拉起 iOS Simulator + mock-host，验证视频解码渲染、交互回传与免密重连）
./scripts/verify-ios-e2e.sh
```

## 使用方式

### 1. 同局域网零配置直连
- **被控端（Host）**：点击「启动 Host 服务」（首次需授予「屏幕录制」与「辅助功能」权限）。
- **控制端（Client）**：在「局域网发现」点击发现的 Mac，输入首次访问口令即可连接（配对后自动加入「已信任设备」，后续免密一键重连）。

### 2. 异地跨公网连接（适配中国大陆网络）
- **无需部署服务器快速直连**：被控端启动 Host 后点击「复制跨网连接串 (`openuu://...`)」发给控制端，控制端粘贴到连接框即可自动尝试公网 IPv6 / P2P 打洞 / 中继保底连接。
- **9 位设备码秒连 + 自建香港中继**：参考 [`deploy/README.md`](./deploy/README.md) 在香港轻量云服务器执行 `docker compose up -d --build`，在双端「设置与日志」填入 `Coord URL` 与 `Relay URL` 后，直接输入 9 位设备码即可秒连。
