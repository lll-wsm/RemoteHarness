// 冒烟测试:连桥 → initialize → 打印响应。
// 用法:BRIDGE_TOKEN=<token> node scripts/smoke.mjs ws://127.0.0.1:8777
import WebSocket from "ws";

const url = process.argv[2] ?? "ws://127.0.0.1:8777";
const token = process.env.BRIDGE_TOKEN ?? "";
const wsUrl = token ? `${url}?token=${encodeURIComponent(token)}` : url;

const ws = new WebSocket(wsUrl);
ws.on("open", () => {
  ws.send(JSON.stringify({ jsonrpc: "2.0", id: 1, method: "initialize", params: {} }));
});
ws.on("message", (data) => {
  console.log(JSON.stringify(JSON.parse(data.toString()), null, 2));
  ws.close();
  process.exit(0);
});
ws.on("error", (err) => {
  console.error("连接失败:", err.message);
  process.exit(1);
});
