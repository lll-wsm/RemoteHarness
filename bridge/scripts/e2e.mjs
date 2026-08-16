// 端到端测试:模拟 iPad ACP 客户端的完整流程。
// initialize → session/new → session/prompt → 打印流式事件(即 iPad 端要渲染的内容)。
// 用法:BRIDGE_TOKEN=<token> node scripts/e2e.mjs [ws://127.0.0.1:8777] ["测试提示词"]
// 说明:session/prompt 的参数形状以真实 grok 为准,如报错请贴出错误信息用于校准。
import WebSocket from "ws";

const url = process.argv[2] ?? "ws://127.0.0.1:8777";
const prompt = process.argv[3] ?? "你好,请回复一句话。";
const token = process.env.BRIDGE_TOKEN ?? "";
const wsUrl = token ? `${url}?token=${encodeURIComponent(token)}` : url;

const ws = new WebSocket(wsUrl);
let nextId = 1;
const pending = new Map();

function rpc(method, params = {}, timeoutMs = 120000) {
  return new Promise((resolve, reject) => {
    const id = nextId++;
    const timer = setTimeout(() => {
      pending.delete(id);
      reject(new Error(`${method} 超时`));
    }, timeoutMs);
    pending.set(id, { resolve, reject, timer });
    ws.send(JSON.stringify({ jsonrpc: "2.0", id, method, params }));
  });
}

ws.on("message", (data) => {
  const msg = JSON.parse(data.toString());
  if (msg.id !== undefined && msg.id !== null) {
    const p = pending.get(msg.id);
    if (!p) return;
    pending.delete(msg.id);
    clearTimeout(p.timer);
    p.resolve(msg);
  } else {
    // 通知(session/update 等):流式事件,打印前 300 字符
    console.log(`[event] ${JSON.stringify(msg).slice(0, 300)}`);
  }
});

ws.on("open", async () => {
  try {
    const init = await rpc("initialize", {});
    console.log("[initialize]", JSON.stringify(init.result ?? init.error));

    const created = await rpc("session/new", {});
    console.log("[session/new]", JSON.stringify(created.result ?? created.error));
    const chatID = created.result?.chatID;
    if (!chatID) throw new Error("未拿到 chatID(桥未连上 grok?)");

    console.log(`[prompt] 发送: "${prompt}"`);
    const resp = await rpc("session/prompt", { prompt });
    console.log("[session/prompt 响应]", JSON.stringify(resp.result ?? resp.error));
  } catch (err) {
    console.error("失败:", err.message);
    process.exitCode = 1;
  } finally {
    ws.close();
    setTimeout(() => process.exit(), 300);
  }
});

ws.on("error", (err) => {
  console.error("连接失败:", err.message);
  process.exit(1);
});
