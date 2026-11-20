# Chameye（一眸）

局域网「单应用窗口级」串流与无缝交互工具（类似 Parallels Coherence 模式，跨实体机版本）——多台 Mac，一眸同屏。

## 架构概览

- `proto/chameye.proto`：跨平台 Protobuf v3 控制协议定义。
- `crates/chameye-core`：Rust 跨平台核心（QUIC TLS 1.3 多路复用传输、mDNS 局域网自动发现、6 位 PIN 配对与 Ed25519 设备证书、C-ABI 桥接）。
- `crates/chameye-cli`：命令行调试工具（验证 mDNS 发现与 QUIC 连通性）。
- `apps/macos`：macOS 原生 App（SwiftUI + AppKit + ScreenCaptureKit + VideoToolbox + 本地中文输入法直通）。

## 快速构建与运行 (macOS)

```bash
chmod +x scripts/build-macos.sh
./scripts/build-macos.sh
./apps/macos/.build/debug/ChameyeApp
```

### 首次使用权限说明
- **被控端（Host，运行微信的 Mac）**：需要授予「屏幕录制」与「辅助功能」权限。
- **控制端（Client，当前 Mac）**：启动后在「连接局域网应用」页点击已发现的 Host，输入 6 位配对码即可弹出原生可拖动远程窗口。
