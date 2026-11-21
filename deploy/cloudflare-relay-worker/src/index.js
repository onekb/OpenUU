function timingSafeEqualStr(a, b) {
  const enc = new TextEncoder();
  const ba = enc.encode(a);
  const bb = enc.encode(b);
  if (ba.byteLength !== bb.byteLength) {
    return false;
  }
  return crypto.subtle.timingSafeEqual(ba, bb);
}

function extractBearerOrQueryToken(request, url) {
  const auth = request.headers.get("Authorization") || "";
  if (auth.toLowerCase().startsWith("bearer ")) {
    return auth.slice(7).trim();
  }
  return url.searchParams.get("token") || "";
}

export default {
  async fetch(request, env) {
    const url = new URL(request.url);

    if (url.pathname === "/healthz") {
      return Response.json({
        status: "ok",
        service: "openuu-relay-edge",
        mode: "cloudflare-tunnel-vpc",
      });
    }

    // Enforce Bearer token at Cloudflare Edge on `/relay` when RELAY_AUTH_TOKEN is configured
    const expectedToken = (env.RELAY_AUTH_TOKEN || "").trim();
    if (expectedToken && url.pathname.startsWith("/relay")) {
      const provided = extractBearerOrQueryToken(request, url);
      if (!provided || !timingSafeEqualStr(provided, expectedToken)) {
        return new Response("Unauthorized private OpenUU relay", {
          status: 401,
          headers: { "WWW-Authenticate": 'Bearer realm="openuu-relay"' },
        });
      }
    }

    // Forward HTTP + WebSocket (101 Switching Protocols + Sec-WebSocket-Protocol) over Cloudflare Tunnel VPC
    const targetUrl = new URL(url.pathname + url.search, "http://127.0.0.1:3340");
    const forwarded = new Request(targetUrl.toString(), request);
    return env.RELAY_ORIGIN.fetch(forwarded);
  },
};
