```cd bridge
cd /Users/lll/Projects.localized/GitHubProjects/RemoteHarness/bridge
export BRIDGE_TOKEN=$(npm run -s gen-token)       # 在 bridge 目录下生成
export GROK_SERVE_SECRET=$(npm run -s gen-token)
echo "长度: ${#BRIDGE_TOKEN} / ${#GROK_SERVE_SECRET}"   # 应显示 43 / 43

一个关键坑:变量只活在当前终端

BRIDGE_TOKEN=... 设的值换一个终端窗口就没了。所以要么全程同一个终端,要么用 export:

# 同一个终端里一次跑完(推荐):
cd /Users/lll/Projects.localized/GitHubProjects/RemoteHarness/bridge
export BRIDGE_TOKEN=$(npm run -s gen-token)      # 生成并导出
export GROK_SERVE_SECRET=$(npm run -s gen-token) # 各自独立生成
echo "token 长度: ${#BRIDGE_TOKEN} / secret 长度: ${#GROK_SERVE_SECRET}"

# 后台起 agent serve(同终端,环境变量能传给它)
grok -m opencode-deepseek-v4-flash agent serve --bind 127.0.0.1:2419 --secret "$GROK_SERVE_SECRET" &

# 前台跑桥 + 隧道(Ctrl+C 停止,会自动带上 export 的变量)
BRIDGE_TOKEN="$BRIDGE_TOKEN" GROK_SERVE_SECRET="$GROK_SERVE_SECRET" ./scripts/start.sh

# 另开终端测(这会失败,因为变量没过去):
# BRIDGE_TOKEN="$BRIDGE_TOKEN" node scripts/e2e.mjs ws://127.0.0.1:8777 "你好"
```

