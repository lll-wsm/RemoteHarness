#!/usr/bin/env bash
# 一键启动完整链路:grok agent serve(模型)+ 桥 + cloudflared 隧道。
# 用法:
#   ./scripts/start-all.sh
# 环境变量(均有默认值):
#   GROK_SERVE_SECRET  未设置则自动生成(serve 与桥共用,启动时打印)
#   BRIDGE_TOKEN       未设置则 npm run -s gen-token 生成(打印,供 iPad 填入)
#   GROK_MODEL         default glm-5-2(config.toml 的 [model.xxx] 段名)
#   PROBE=1            启动前先用 grok -p 探测模型可用性(余额不足提前报错)
#   TUNNEL=0           跳过 cloudflared,仅局域网使用
#   BRIDGE_PORT        默认 8777;GROK_SERVE_PORT 默认 2419
# 停止:Ctrl+C 同时关闭 serve / 桥 / 隧道。
set -euo pipefail

cd "$(dirname "$0")/.."

GROK_MODEL="${GROK_MODEL:-$(sed -n 's/^default = "\(.*\)"/\1/p' ~/.grok/config.toml 2>/dev/null | head -1)}"
GROK_MODEL="${GROK_MODEL:-glm-5-2}"
BRIDGE_PORT="${BRIDGE_PORT:-8777}"
GROK_SERVE_PORT="${GROK_SERVE_PORT:-2419}"
BRIDGE_ENCRYPT_KEY="${BRIDGE_ENCRYPT_KEY:-}"

command -v grok >/dev/null 2>&1 || { echo "[start-all] 未找到 grok CLI" >&2; exit 1; }
command -v node >/dev/null 2>&1 || { echo "[start-all] 未找到 node" >&2; exit 1; }
[ -d node_modules ] || { echo "[start-all] 缺少 bridge/node_modules,先运行 npm install" >&2; exit 1; }

# 密钥:未提供则自动生成;BRIDGE_TOKEN 打印给 iPad 使用
GROK_SERVE_SECRET="${GROK_SERVE_SECRET:-$(openssl rand -base64 32 | tr -d '\n')}"
BRIDGE_TOKEN="${BRIDGE_TOKEN:-$(npm run -s gen-token)}"

PIDS=()
SERVE_LOG="$(mktemp -t rh-serve.XXXXXX)"
BRIDGE_LOG="$(mktemp -t rh-bridge.XXXXXX)"
TUNNEL_LOG="$(mktemp -t rh-tunnel.XXXXXX)"
cleanup() {
  echo "[stop] 关闭 serve/桥/隧道…" >&2
  for pid in "${PIDS[@]:-}"; do kill "$pid" 2>/dev/null || true; done
  wait 2>/dev/null || true
  rm -f "$SERVE_LOG" "$BRIDGE_LOG" "$TUNNEL_LOG"
}
trap cleanup EXIT INT TERM

# 可选:模型探测(避免 402 余额不足的坑)
if [ "${PROBE:-0}" = "1" ]; then
  echo "[start-all] 探测模型 $GROK_MODEL 可用性(grok -p)…" >&2
  R="$(grok -m "$GROK_MODEL" -p "只回复两个字母:OK" 2>&1 || true)"
  case "$R" in
    *OK*) echo "[start-all] 模型可用" >&2 ;;
    *) echo "[start-all] 模型 $GROK_MODEL 探测失败: $(echo "$R" | tail -2)" >&2; exit 1 ;;
  esac
fi

# 端口占用检查
for pp in "$GROK_SERVE_PORT" "$BRIDGE_PORT"; do
  if lsof -iTCP:"$pp" -sTCP:LISTEN -P 2>/dev/null | grep -q .; then
    echo "[start-all] 端口 $pp 已被占用,请先释放" >&2
    exit 1
  fi
done

# 1) grok agent serve
echo "[start-all] 启动 grok agent serve(-m $GROK_MODEL)…" >&2
GROK_SERVE_SECRET="$GROK_SERVE_SECRET" \
  grok -m "$GROK_MODEL" agent serve \
  --bind "127.0.0.1:$GROK_SERVE_PORT" --secret "$GROK_SERVE_SECRET" \
  >"$SERVE_LOG" 2>&1 &
PIDS+=($!)

echo "[start-all] 等 serve 就绪…" >&2
SERVE_OK=""
for _ in $(seq 1 90); do
  lsof -iTCP:"$GROK_SERVE_PORT" -sTCP:LISTEN -P 2>/dev/null | grep -q . && SERVE_OK=1 && break
  kill -0 "${PIDS[0]}" 2>/dev/null || break
  sleep 1
done
if [ -z "$SERVE_OK" ]; then
  echo "[start-all] serve 未在预期时间内就绪,日志:" >&2
  tail -8 "$SERVE_LOG" >&2
  exit 1
fi

# 2) 桥
echo "[start-all] 启动桥…" >&2
BRIDGE_TOKEN="$BRIDGE_TOKEN" \
GROK_SERVE_SECRET="$GROK_SERVE_SECRET" \
BRIDGE_PORT="$BRIDGE_PORT" \
GROK_SERVE_URL="ws://127.0.0.1:$GROK_SERVE_PORT" \
BRIDGE_ENCRYPT_KEY="$BRIDGE_ENCRYPT_KEY" \
  node src/index.js >"$BRIDGE_LOG" 2>&1 &
PIDS+=($!)

echo "[start-all] 等桥就绪(healthz)…" >&2
READY=""
for _ in $(seq 1 30); do
  curl -sf --max-time 1 "http://127.0.0.1:${BRIDGE_PORT}/healthz?token=${BRIDGE_TOKEN}" >/dev/null && READY=1 && break
  sleep 0.5
done
if [ -z "$READY" ]; then
  echo "[start-all] 桥未就绪,日志:" >&2
  tail -8 "$BRIDGE_LOG" >&2
  exit 1
fi

# 3) cloudflared 隧道(可选)
TUNNEL_URL=""
if [ "${TUNNEL:-1}" != "0" ]; then
  command -v cloudflared >/dev/null 2>&1 || {
    echo "[start-all] 未找到 cloudflared;设 TUNNEL=0 可仅局域网使用" >&2
    exit 1
  }
  echo "[start-all] 启动 cloudflared quick tunnel → http://127.0.0.1:${BRIDGE_PORT} …" >&2
  cloudflared tunnel --url "http://127.0.0.1:${BRIDGE_PORT}" --no-autoupdate >"$TUNNEL_LOG" 2>&1 &
  PIDS+=($!)
  for _ in $(seq 1 45); do
    TUNNEL_URL="$(grep -oE 'https://[a-z0-9-]+\.trycloudflare\.com' "$TUNNEL_LOG" | head -1 || true)"
    [ -n "$TUNNEL_URL" ] && break
    sleep 1
  done
  if [ -z "$TUNNEL_URL" ]; then
    echo "[start-all] 未拿到公网 URL,日志:" >&2
    tail -8 "$TUNNEL_LOG" >&2
    exit 1
  fi
fi

echo
echo "[start-all] ✔ 链路就绪"
echo "   模型:      $GROK_MODEL(grok agent serve 127.0.0.1:$GROK_SERVE_PORT)"
echo "   桥:        ws://127.0.0.1:$BRIDGE_PORT"
[ -n "$TUNNEL_URL" ] && echo "   公网:      wss://${TUNNEL_URL#https://}"
echo "   BRIDGE_TOKEN: $BRIDGE_TOKEN"
echo "   密钥已复用:GROK_SERVE_SECRET(长度 ${#GROK_SERVE_SECRET})"
if [ -n "$BRIDGE_ENCRYPT_KEY" ]; then
  echo "   🔒 加密必需模式已开启(BRIDGE_ENCRYPT_KEY):App 档案需配置同一加密密钥"
fi
echo "   验证:      curl -s \"http://127.0.0.1:${BRIDGE_PORT}/healthz?token=${BRIDGE_TOKEN}\""
echo "   e2e 测试:  BRIDGE_TOKEN=$BRIDGE_TOKEN node scripts/e2e.mjs ws://127.0.0.1:$BRIDGE_PORT \"你好\""
echo "   日志:      serve=$SERVE_LOG 桥=$BRIDGE_LOG 隧道=$TUNNEL_LOG"
echo "   停止:      Ctrl+C(同时关闭全部进程)"
echo

wait "${PIDS[@]}"