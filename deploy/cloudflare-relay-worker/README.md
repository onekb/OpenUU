# OpenUU Zero-IP-Exposure Private Relay (`https://openuu-relay.1kb.ren`)

This directory contains the **Cloudflare Edge Relay Gateway (`openuu-relay`)**, which combines **Cloudflare Workers Custom Domains + Workers VPC + Cloudflare Tunnel (`cloudflared`)** to expose your private `iroh-relay` node under `https://openuu-relay.1kb.ren` with:

1. **100% Hidden Origin IP**: Public DNS resolves `openuu-relay.1kb.ren` strictly to Cloudflare Anycast IPs.
2. **Zero Inbound Firewall Ports**: Your server (currently `192.168.9.99`, or your Hong Kong server) needs **0 open TCP/UDP inbound ports** — `cloudflared` dials outbound QUIC to Cloudflare's nearest edge POP.
3. **Edge Bearer Token Protection (`401 Unauthorized`)**: Unauthenticated scanners or third-party clients hitting `https://openuu-relay.1kb.ren/relay` are rejected right at Cloudflare's Edge before touching your tunnel bandwidth.

## Migrating from `192.168.9.99` to Your Hong Kong Server (1-Command, Zero Port Exposure)

Whenever you want to move (or dual-run for High Availability!) the relay backend onto your Hong Kong server without exposing its IP:

1. Copy `/opt/openuu-test-stack/deploy/docker-compose.tunnel.yml` and `/opt/openuu-test-stack/deploy/.env` (`CF_TUNNEL_TOKEN=...`) from `root@192.168.9.99` to your Hong Kong server.
2. On your Hong Kong server (even with all inbound firewall ports closed!), run:
   ```bash
   docker compose -f docker-compose.tunnel.yml up -d
   ```
3. Done! Cloudflare Tunnel automatically routes `https://openuu-relay.1kb.ren` to the active `cloudflared` connector(s) — zero DNS or client configuration changes required.
