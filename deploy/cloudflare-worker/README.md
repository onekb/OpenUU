# OpenUU 官网 & 9位设备码寻址服务 —— Cloudflare Workers + Static Assets + D1

本目录同时承载 **OpenUU 官方网站（`public/` 静态资源）** 与 **100% 兼容 `openuu-core` 的无服务器寻址后端（`src/index.js`）**，共用同一个域名（如 `https://openuu.1kb.ren`）：
- **同域零冲突、静态访问零配额消耗**：通过 Cloudflare Workers Static Assets（`run_worker_first = ["/v1/*", "/health"]`），浏览器访问 `/` 官网页面与图片直接由 Cloudflare 边缘静态缓存响应（不消耗 Worker 请求额度）；而客户端 API（`/v1/*` 与 `/health`）直达 Worker 处理。
- **为什么选 D1 而不是 KV**：Workers KV 免费版每天仅限 1,000 次写入且有 60 秒最终一致性延迟；而 **Cloudflare D1 免费版每天支持 100,000 次写入 + 5,000,000 次读取，且强一致零延迟**，首次请求自动建表，零手动 SQL 迁移。
- **零第三方依赖**：纯原生 WebCrypto `Ed25519` 签名验签与 `SHA-256` 确定性 9 位设备码派生。

---

## 快速部署步骤

1. **登录 Cloudflare 并创建 D1 数据库**：
   ```bash
   cd deploy/cloudflare-worker
   npx wrangler login
   npx wrangler d1 create openuu-coord-db
   ```
2. **修改 `wrangler.toml`**：
   - 将终端输出的 `database_id` 填入 `wrangler.toml` 的 `database_id = "..."`。
   - 取消注释 `routes`，将 `coord.yourdomain.com` 替换为你托管在 Cloudflare 下的自定义子域名（中国大陆访问必需绑定自定义域名）。
3. **一键发布**：
   ```bash
   npx wrangler deploy
   ```
4. **在 OpenUU 客户端启用**：
   打开 **OpenUU -> 网络与日志**，在 `设备码寻址 (Coord)` 填入 `https://coord.yourdomain.com` 并点击「保存网络配置」即可。
