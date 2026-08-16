import { timingSafeEqual } from "node:crypto";
import { config } from "./config.js";

// iPad 侧 token 鉴权:WebSocket 升级 / healthz 均校验 query 或 Authorization header。
// 未配置 token 时默认拒绝(除非显式 BRIDGE_ALLOW_NO_AUTH=1,仅限纯本地调试)。
export function checkToken(query = {}, headers = {}) {
  const expected = config.token;
  if (!expected) return config.allowNoAuth;
  const candidate = query.token ?? parseBearer(headers.authorization) ?? "";
  if (!candidate) return false;
  return safeEqual(expected, candidate);
}

// 来源 IP 白名单(可选):BRIDGE_ALLOW_IPS=1.2.3.4,5.6.7.8
export function checkIp(ip) {
  const allow = config.allowIps;
  if (allow.length === 0) return true;
  return allow.includes(ip);
}

export function isAuthorized(req, query) {
  return checkToken(query, req.headers) && checkIp(clientIp(req));
}

// 隧道(cloudflared 等)会把所有公网连接本机化,优先取透传头里的真实客户端 IP。
// 只在连接来源是回环(即确实来自本机隧道进程)时才信任透传头,
// 防止不走隧道的直连方伪造 CF-Connecting-IP / X-Forwarded-For 绕过白名单。
export function clientIp(req) {
  const peer = req.socket.remoteAddress ?? "unknown";
  const loopback = peer === "127.0.0.1" || peer === "::1" || peer === "::ffff:127.0.0.1";
  if (loopback) {
    const cf = req.headers["cf-connecting-ip"];
    if (cf) return String(cf);
    const xff = req.headers["x-forwarded-for"];
    if (xff) return String(xff).split(",")[0].trim();
  }
  return peer;
}

function parseBearer(header) {
  if (!header) return null;
  const m = /^Bearer\s+(.+)$/i.exec(header);
  return m ? m[1] : null;
}

// 常数时间比较,避免时序侧信道泄露 token 前缀。
function safeEqual(a, b) {
  const ba = Buffer.from(a);
  const bb = Buffer.from(b);
  if (ba.length !== bb.length) return false;
  return timingSafeEqual(ba, bb);
}
