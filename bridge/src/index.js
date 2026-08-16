import http from "node:http";
import { config } from "./config.js";
import { isAuthorized } from "./auth.js";
import { GrokClient } from "./grok-client.js";
import { SessionManager } from "./session-manager.js";
import { AcpServer } from "./acp-server.js";

// 默认失败关闭:公网/隧道暴露必须带 token。
if (!config.token && !config.allowNoAuth) {
  console.error(
    "[bridge] BRIDGE_TOKEN 未设置且未显式允许 BRIDGE_ALLOW_NO_AUTH=1,拒绝启动。公网/隧道暴露必须设置 token。",
  );
  process.exit(1);
}

const sessions = new SessionManager(config.registryFile);

const grok = new GrokClient({
  url: config.grokServeUrl,
  secret: config.grokServeSecret,
  onOpen: () => console.log(`[grok] 已连接 ${config.grokServeUrl}`),
  onClose: () => console.warn("[grok] 连接断开,自动重连中…"),
});
grok.connect();

const acp = new AcpServer({ grok, sessions, defaultCwd: config.defaultCwd });

const httpServer = http.createServer((req, res) => {
  const url = new URL(req.url, `http://${req.headers.host}`);
  if (url.pathname === "/healthz") {
    if (!isAuthorized(req, Object.fromEntries(url.searchParams))) {
      res.writeHead(401);
      res.end("unauthorized");
      return;
    }
    res.writeHead(200, { "content-type": "application/json" });
    res.end(
      JSON.stringify({
        ok: true,
        grokConnected: grok.isConnected(),
        sessions: sessions.list().length,
      }),
    );
    return;
  }
  res.writeHead(404);
  res.end("not found");
});

acp.attach(httpServer);

httpServer.listen(config.port, config.bindHost, () => {
  console.log(`[bridge] ACP 服务监听 ${config.bindHost}:${config.port}`);
  console.log(`[bridge] 健康检查 http://${config.bindHost}:${config.port}/healthz`);
});
