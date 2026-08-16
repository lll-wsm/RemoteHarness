#!/usr/bin/env bash
# 一键启动:桥(固定安全参数)+ cloudflared quick tunnel(固定指向桥端口)。
# 作用:把「cloudflared 只能指向桥」的配置纪律固化成脚本——
#       --url 写死为 127.0.0.1:BRIDGE_PORT,脚本内无法指向其他服务;
#       安全参数缺失时拒绝启动(fail-closed)。
# 用法:
#   BRIDGE_TOKEN=$(npm run -s gen-token) GROK_SERVE_SECRET=xxx ./scripts/start.sh
#   Ctrl+C 或 kill -INT <pid> 会同时关掉 cloudflared 和桥。
set -euo pipefail

cd "$(dirname "$0")/.."

# 安全参数必须显式提供,缺省拒绝启动
: "${BRIDGE_TOKEN:?请设置 BRIDGE_TOKEN(可先运行 npm run -s gen-token 生成)}"
: "${GROK_SERVE_SECRET:?请设置 GROK_SERVE_SECRET(grok agent serve 的 secret)}"

BRIDGE_PORT="${BRIDGE_PORT:-8777}"
BRIDGE_BIND="${BRIDGE_BIND:-127.0.0.1}"
BRIDGE_ALLOW_IPS="${BRIDGE_ALLOW_IPS:-}"
BRIDGE_REGISTRY_FILE="${BRIDGE_REGISTRY_FILE:-sessions.json}"

# 启动桥
BRIDGE_TOKEN="$BRIDGE_TOKEN" \
GROK_SERVE_SECRET="$GROK_SERVE_SECRET" \
BRIDGE_PORT="$BRIDGE_PORT" \
BRIDGE_BIND="$BRIDGE_BIND" \
BRIDGE_ALLOW_IPS="$BRIDGE_ALLOW_IPS" \
BRIDGE_REGISTRY_FILE="$BRIDGE_REGISTRY_FILE" \
  node src/index.js &
BRIDGE_PID=$!

# 等桥就绪(healthz 需 token)
READY=""
for _ in $(seq 1 20); do
  if curl -sf --max-time 1 "http://127.0.0.1:${BRIDGE_PORT}/healthz?token=${BRIDGE_TOKEN}" >/dev/null; then
    READY=1
    break
  fi
  if ! kill -0 "$BRIDGE_PID" 2>/dev/null; then
    echo "[start] 桥启动失败,退出" >&2
    exit 1
  fi
  sleep 0.5
done
if [ -z "$READY" ]; then
  echo "[start] 桥在 10s 内未就绪,退出" >&2
  kill "$BRIDGE_PID" 2>/dev/null || true
  exit 1
fi
echo "[start] 桥已就绪 (${BRIDGE_BIND}:${BRIDGE_PORT})"

LOG="$(mktemp -t rh-tunnel.XXXXXX)"
cleanup() {
  echo "[stop] 关闭 cloudflared 与桥…" >&2
  kill "$TUNNEL_PID" "$BRIDGE_PID" 2>/dev/null || true
  rm -f "$LOG"
}
trap cleanup EXIT INT TERM

# 启动 cloudflared —— --url 写死指向桥端口,这就是配置纪律的固化点
echo "[start] 启动 cloudflared quick tunnel → http://127.0.0.1:${BRIDGE_PORT}" >&2
cloudflared tunnel --url "http://127.0.0.1:${BRIDGE_PORT}" --no-autoupdate >"$LOG" 2>&1 &
TUNNEL_PID=$!

# 等公网 URL 出现
URL=""
for _ in $(seq 1 30); do
  URL="$(grep -oE 'https://[a-z0-9-]+\.trycloudflare\.com' "$LOG" | head -1 || true)"
  [ -n "$URL" ] && break
  sleep 1
done
if [ -z "$URL" ]; then
  echo "[start] 未拿到公网 URL,日志见 $LOG" >&2
  exit 1
fi
echo "[start] 公网地址: $URL"
echo "[start] 公网 healthz: curl -s \"$URL/healthz?token=...\"" >&2
echo "[start] 按 Ctrl+C 停止(同时关闭桥与隧道)" >&2

wait "$TUNNEL_PID"
