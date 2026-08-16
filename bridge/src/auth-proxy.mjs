import http from "node:http";
import net from "node:net";
import { timingSafeEqual } from "node:crypto";

// 鉴权代理:cloudflared → 本代理(HTTP Basic Auth 校验)→ 桥。
// 校验通过前,任何流量(普通 HTTP / WebSocket 升级)都不转发。
// 使用场景:没有域名/不想配 Cloudflare Access 时,在隧道与桥之间加一道独立校验层。
// 客户端约定:代理层用 Authorization: Basic ...;桥的 token 走 ?token=(两层凭证互不干扰)。
const PORT = Number(process.env.AUTH_PROXY_PORT ?? 8788);
const USER = process.env.AUTH_PROXY_USER ?? "";
const PASS = process.env.AUTH_PROXY_PASS ?? "";
const TARGET = new URL(process.env.AUTH_PROXY_TARGET ?? "http://127.0.0.1:8777");

if (!USER || !PASS) {
  console.error("[auth-proxy] 必须设置 AUTH_PROXY_USER 和 AUTH_PROXY_PASS,拒绝启动(失败关闭)");
  process.exit(1);
}

function checkAuth(req) {
  const header = req.headers.authorization ?? "";
  const m = /^Basic\s+(.+)$/i.exec(header);
  if (!m) return false;
  const decoded = Buffer.from(m[1], "base64").toString();
  const idx = decoded.indexOf(":");
  if (idx < 0) return false;
  return safeEqual(decoded.slice(0, idx), USER) && safeEqual(decoded.slice(idx + 1), PASS);
}

// 常数时间比较,避免时序侧信道。
function safeEqual(a, b) {
  const ba = Buffer.from(a);
  const bb = Buffer.from(b);
  if (ba.length !== bb.length) return false;
  return timingSafeEqual(ba, bb);
}

function audit(result, ip) {
  console.log(`[audit] ${new Date().toISOString()} ${result} ip=${ip}`);
}

// 普通 HTTP 请求(healthz 等):校验后转发。
const server = http.createServer((req, res) => {
  const ip = req.socket.remoteAddress ?? "unknown";
  if (!checkAuth(req)) {
    audit("auth-fail", ip);
    res.writeHead(401, { "WWW-Authenticate": 'Basic realm="RemoteHarness"' });
    res.end("unauthorized");
    return;
  }
  audit("auth-ok", ip);
  const proxyReq = http.request(
    {
      hostname: TARGET.hostname,
      port: TARGET.port || 80,
      path: req.url,
      method: req.method,
      headers: stripAuth(req.headers),
    },
    (proxyRes) => {
      res.writeHead(proxyRes.statusCode, proxyRes.headers);
      proxyRes.pipe(res);
    },
  );
  proxyReq.on("error", () => {
    res.writeHead(502);
    res.end("bad gateway");
  });
  req.pipe(proxyReq);
});

// WebSocket 升级:校验后按原始字节流透传(代理层不做协议解析)。
server.on("upgrade", (req, socket, head) => {
  const ip = socket.remoteAddress ?? "unknown";
  if (!checkAuth(req)) {
    audit("auth-fail", ip);
    socket.write(
      "HTTP/1.1 401 Unauthorized\r\nWWW-Authenticate: Basic realm=\"RemoteHarness\"\r\nConnection: close\r\n\r\n",
    );
    socket.destroy();
    return;
  }
  audit("auth-ok", ip);
  const upstream = net.connect(TARGET.port || 80, TARGET.hostname);
  // 重建原始升级请求并转发;剥掉 Authorization,桥只认自己的 ?token=。
  const raw =
    `${req.method} ${req.url} HTTP/${req.httpVersion}\r\n` +
    Object.entries(stripAuth(req.headers))
      .map(([k, v]) => `${k}: ${v}`)
      .join("\r\n") +
    "\r\n\r\n";
  upstream.on("connect", () => {
    upstream.write(raw);
    if (head?.length) upstream.write(head);
    socket.pipe(upstream).pipe(socket);
  });
  upstream.on("error", () => socket.destroy());
  socket.on("error", () => upstream.destroy());
});

function stripAuth(headers) {
  const { authorization, ...rest } = headers;
  return rest;
}

server.listen(PORT, "127.0.0.1", () => {
  console.log(`[auth-proxy] 监听 127.0.0.1:${PORT},校验通过后转发到 ${TARGET.href}`);
  console.log(`[auth-proxy] cloudflared ingress 应指向 http://localhost:${PORT}`);
});
