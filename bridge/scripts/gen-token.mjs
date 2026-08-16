// 生成强随机 token(128-bit):node scripts/gen-token.mjs
import { randomBytes } from "node:crypto";

console.log(randomBytes(32).toString("base64url"));
