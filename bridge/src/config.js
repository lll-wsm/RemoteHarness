import os from "node:os";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

// 全部配置来自环境变量,默认值适合局域网开发。
// 桥与被控端 grok 同机,通过回环地址连接 agent serve。
const port = Number(process.env.BRIDGE_PORT ?? 8777);
const token = process.env.BRIDGE_TOKEN ?? "";
const allowNoAuth = process.env.BRIDGE_ALLOW_NO_AUTH === "1";
const bindHost = process.env.BRIDGE_BIND ?? "127.0.0.1";
const grokServeUrl = process.env.GROK_SERVE_URL ?? "ws://127.0.0.1:2419";
const grokServeSecret = process.env.GROK_SERVE_SECRET ?? "";
const bridgeDir = path.dirname(fileURLToPath(import.meta.url)) + "/..";
// 加密密钥:显式值 > 默认读 .encrypt-key(缺失自动生成由 start-all 负责;直接 node 跑时缺失=明文,
// 便于测试)。BRIDGE_ENCRYPT_KEY=off 可显式强制明文。
let encryptKey = process.env.BRIDGE_ENCRYPT_KEY ?? "";
if (encryptKey === "off") {
  encryptKey = "";
} else if (encryptKey === "" || encryptKey === "auto") {
  try {
    encryptKey = fs.readFileSync(path.join(bridgeDir, ".encrypt-key"), "utf8").trim();
  } catch {
    encryptKey = "";
  }
}
const registryFile = process.env.BRIDGE_REGISTRY_FILE ?? "sessions.json";
const defaultCwd = process.env.BRIDGE_CWD ?? os.homedir(); // 远程 grok 会话的工作目录兜底
const allowIps = (process.env.BRIDGE_ALLOW_IPS ?? "")
  .split(",")
  .map((s) => s.trim())
  .filter(Boolean);

if (!token) {
  console.warn(
    "[config] BRIDGE_TOKEN 未设置:默认拒绝所有连接;仅当 BRIDGE_ALLOW_NO_AUTH=1 时放行(仅限纯本地调试)",
  );
}
if (!grokServeSecret) {
  console.warn("[config] GROK_SERVE_SECRET 未设置:无法鉴权 grok agent serve");
}

export const config = {
  port,
  token,
  allowNoAuth,
  bindHost,
  grokServeUrl,
  grokServeSecret,
  encryptKey,
  registryFile,
  defaultCwd,
  allowIps,
};
