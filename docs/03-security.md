# 03 安全设计

> 公网暴露意味着任何人都可能扫到隧道地址,而 grok 在远程机器上能执行命令、改文件——安全必须是分层的。

## 1. 威胁模型

- 主要威胁:陌生人扫到公网 URL → 尝试连接/驱动 grok(命令执行能力);
- 次级威胁:token 泄露后被利用;假桥钓鱼(客户端被指向恶意服务器)。

## 2. 分层防御模型

| 层 | 管什么 | 状态 |
|---|---|---|
| 桥(核心) | 操作鉴权:token / IP 白名单 / 限流 / 审计 / fail-closed | ✅ 已实现并实测 |
| 传输层 | 公网段防窃听/篡改/伪装(TLS、证书校验) | ✅ 协议层面具备;客户端必须正常校验证书(M2 必做) |
| 隧道层 | 入口开关、URL 生命周期、隧道凭证 | ⚠️ 操作纪律:用完连隧道一起关;`~/.cloudflared` 不泄露 |
| 客户端 | token 存 Keychain、不提供跳过证书校验 | ⏳ M2 |
| 系统层 | grok 以低权限用户运行;敏感机器不暴露 | ⚠️ 配置项 |

## 3. 桥已实现的加固(均实测)

| 措施 | 说明 |
|---|---|
| **默认失败关闭** | 未设置 `BRIDGE_TOKEN` 拒绝启动;`BRIDGE_ALLOW_NO_AUTH=1` 仅限纯本地调试 |
| **强 token** | `npm run -s gen-token` 生成 128-bit 随机 token(base64url,43 字符) |
| **常数时间比较** | `timingSafeEqual`,防时序侧信道 |
| **失败限流** | 每 IP 窗口内 5 次失败 → 临时 429(按 `CF-Connecting-IP` 取真实客户端 IP) |
| **审计日志** | 每次握手记 `[audit]`(时间/结果/IP,不记 token) |
| **healthz 加锁** | `/healthz` 需 token 访问,防信息泄露 |
| **IP 白名单** | `BRIDGE_ALLOW_IPS` 逗号分隔;**防伪造**:仅回环来源(本机隧道进程)才信任透传头,非回环直连按真实对端 IP |
| **auth-proxy(可选)** | 隧道与桥之间 HTTP Basic Auth 校验层(无域名时的入口校验),失败关闭、审计、剥 Authorization 头 |

## 4. 隧道场景的边界(如实说明)

- **cloudflared quick tunnel 入口无 ACL**(trycloudflare.com 随机 URL 只是隐蔽性);
- 经 cloudflared 时所有公网连接在本机视角是回环,限流/白名单依赖透传头;
- Cloudflare 边缘是信任点:它终结 TLS,理论上可见明文(所有 CDN/代理的固有属性);要端到端加密选 **Tailscale**(WireGuard,协调服务看不到流量);
- 邮箱 OTP 入口验证(Cloudflare Access)需要域名 + 美元支付,当前被"无域名/无外卡"卡住;等效入口验证可用 Tailscale(设备身份,免费免卡)或 auth-proxy(Basic Auth)。

## 5. 应用层安全通道(E2E 会话加密,2026-08-17)

**目的**:即使经过第三方隧道(cloudflared/Tailscale 协调服务/frp 等),会话内容(提示词、回复、思考)对隧道本身也不可见。

### 为什么不能只用 token 派生密钥

`BRIDGE_TOKEN` 在 `Authorization` 头中传输,cloudflared 边缘终结 TLS 后可见 → 边缘能推导出任何 token 派生密钥。**加密密钥必须是双方线下约定、从不传输的独立密钥**。

### 协议

- 密钥:`BRIDGE_ENCRYPT_KEY`(桥环境变量)与 App 档案「加密密钥」字段填写**同一个值**,两端各自独立 HKDF-SHA256 派生 32 字节 AES 密钥(空 salt,info = `bilink:e2e:v1`);
- 加密:每帧 AES-256-GCM,随机 12B nonce,帧格式 `nonce(12) || ciphertext || tag`;
- 模式协商:桥未配置 `BRIDGE_ENCRYPT_KEY` 时保持纯明文(兼容旧客户端);配置后进入**加密必需**模式——首帧必须是可解密的密文,否则 close 4001 拒绝;成功解密后该连接所有后续帧(请求/响应/通知)一律密文;
- App 端:档案配置了加密密钥即全帧加密;密钥不匹配/被篡改 → 安全失败,不自动重连,提示「请检查加密密钥是否与桥一致」。

### 边界(如实)

- 覆盖范围:app ↔ 桥的 WebSocket 帧;桥 ↔ grok 走回环明文(本机信任);
- `/healthz` 仍是明文 HTTP(token 鉴权,仅可达性检查,无会话内容);
- 密钥为静态共享(无前向保密);升级路径:token 认证的 X25519 临时密钥交换(ECDH + HKDF),本期未做;
- 密钥与 token 同等敏感:不落盘于 App 侧明文存储(Keychain),不贴聊天/截图。

### 验证(实测)

- 错误密钥 / 篡改密文 → 桥 close 4001 拒绝;
- Swift(CryptoKit)↔ Node(node:crypto)跨实现加解密互通,加密通道完整聊天(建会话/流式回复/重开恢复)通过;
- 加密必需模式下明文客户端被拒;未配置密钥的桥保持明文兼容(e2e/旧客户端不受影响)。

## 6. 操作铁律

1. token 用 `gen-token` 生成,不手敲、不贴聊天/截图、不进 git;
2. 客户端用 `Authorization: Bearer` 传 token(比 `?token=` 好,避免进日志);
3. 隧道按需开关,不用时连同桥一起停(URL 失效);
4. 怀疑泄露就换 token 重启;
5. grok 尽量以低权限用户运行。
