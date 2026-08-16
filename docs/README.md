# RemoteHarness 文档索引

RemoteHarness:在 iPad 上获得与本地一致的「远程 chat」体验——连接远程 Mac/Linux,驱动远程 grok(Grok Build CLI)执行任务、输入提示、查看流式输出。

## 文档

| 文档 | 内容 |
|---|---|
| [01-architecture.md](01-architecture.md) | 总体架构与关键决策(路线 A / 厚桥 / Node.js) |
| [02-acp-protocol.md](02-acp-protocol.md) | ACP 0.10.4 协议实测校准记录(踩坑点) |
| [03-security.md](03-security.md) | 安全分层模型与已实现加固 |
| [04-testing.md](04-testing.md) | 测试矩阵与命令(含无 iPad 的测试方法) |
| [05-progress.md](05-progress.md) | 当前进度(M1 完成)与下一步(M2+) |
| 项目根 `HANDOFF.md` | 交接总览(概述、背景调研、里程碑、开放问题) |

## 代码结构

```
RemoteHarness/
├── HANDOFF.md          # 交接总览
├── docs/               # 本文档
└── bridge/             # 远程桥(Node.js daemon,运行在远程 Mac/Linux)
    ├── src/            # 桥源码(见 01-architecture.md)
    ├── scripts/        # start.sh / e2e.mjs / smoke.mjs / gen-token.mjs
    └── README.md       # 桥的启动与协议说明
└── Bilink/             # 独立 iPad App「比邻」(ACP 客户端,名称:比邻 Bilink)—— M2 起
```
