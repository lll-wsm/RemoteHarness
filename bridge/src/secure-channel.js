import crypto from "node:crypto";

// 应用层安全通道(app ↔ 桥,端到端):HKDF(BRIDGE_ENCRYPT_KEY) → AES-256-GCM,
// 每帧随机 12 字节 nonce,密文前 12B 为 nonce,尾部 16B 为 GCM tag。
// 密钥为双方线下约定、从不传输的独立密钥(不经隧道,隧道服务商无法推导)。

const SALT = Buffer.alloc(0);
const INFO = Buffer.from("bilink:e2e:v1", "utf8");

export function deriveKey(encryptKey) {
  if (!encryptKey) return null;
  return crypto.hkdfSync("sha256", Buffer.from(encryptKey, "utf8"), SALT, INFO, 32);
}

export function encrypt(key, plaintext) {
  const nonce = crypto.randomBytes(12);
  const cipher = crypto.createCipheriv("aes-256-gcm", key, nonce);
  const enc = Buffer.concat([cipher.update(plaintext, "utf8"), cipher.final()]);
  return Buffer.concat([nonce, enc, cipher.getAuthTag()]);
}

export function decrypt(key, frame) {
  if (frame.length < 12 + 16) throw new Error("帧过短,无法解密");
  const nonce = frame.subarray(0, 12);
  const tag = frame.subarray(frame.length - 16);
  const data = frame.subarray(12, frame.length - 16);
  const decipher = crypto.createDecipheriv("aes-256-gcm", key, nonce);
  decipher.setAuthTag(tag);
  return Buffer.concat([decipher.update(data), decipher.final()]).toString("utf8");
}