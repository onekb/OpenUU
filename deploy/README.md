# OpenUU 香港 / 自建跨网寻址与打洞中继部署指南

OpenUU 内置 **五层自动兜底架构**：
1. **同局域网 mDNS 直连**（`< 2ms`）
2. **国内原生公网 IPv6 端到端直连**（`10 ~ 35ms`，零服务器带宽消耗）
3. **IPv4 STUN / UDP 打洞 P2P 直连**（`15 ~ 45ms`，零中继流量）
4. **自建香港 `iroh-relay` HTTPS/WSS 443 专属中继兜底**（穿透移动对称型 NAT4 / 企业防火墙，`25 ~ 50ms`）
5. **`iroh` 全球公共中继 (`n0`) 终极保底**（未部署自建服务器前开箱即用）

---

## 3 分钟在香港云服务器一键部署

推荐规格：**1 核 1G 内存** 轻量香港云服务器（如阿里云香港 / 腾讯云香港轻量 30M~200M 峰值，无需 ICP 备案）。

### 1. 准备域名与防火墙
- 将两个子域名（如 `coord.yourdomain.com` 与 `relay.yourdomain.com`）A 记录解析到香港服务器公网 IP。
- 在云安全组放行端口：
  - **TCP `80`, `443`**（HTTPS 寻址 + WebSocket 穿透中继，抗运营商 UDP 封锁）
  - **UDP `443`, `3478`, `7842`**（STUN / QUIC 公网地址探测辅助打洞）

### 2. 启动服务
在香港服务器上克隆仓库并执行：

```bash
cd deploy
export OPENUU_COORD_DOMAIN=coord.yourdomain.com
export OPENUU_RELAY_DOMAIN=relay.yourdomain.com
docker compose up -d --build
```

验证健康状态：
```bash
curl https://coord.yourdomain.com/health
# 返回: {"registered_devices":0,"service":"openuu-coord","status":"ok"}
```

### 3. 在两台 Mac 的 OpenUU 中填入地址
打开 **OpenUU -> 设置与日志 -> 跨网穿透与自建中继**：
- **9位设备码寻址服务 (Coord URL)**：`https://coord.yourdomain.com`
- **自建打洞/中继服务器 (Relay URL)**：`https://relay.yourdomain.com`
- 保持勾选 **「保留全球公共节点作为终极兜底」**

保存后，被控端（Host）启动即自动注册本机 **9 位数字设备码**；控制端（Client）只需输入这 9 位设备码 + 首次配对口令即可秒连，后续在「已信任设备」列表点击即可免密一键重连。
