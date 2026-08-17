# 10 多连接多会话管理:开发方案

> 2026-08-17。目标:支持「多台远程机器(多连接)× 每连接多会话 × 完整会话历史」。
> 前提:开发阶段,**不做存量数据迁移**,数据模型直接按最终形态落地(旧本地数据作废)。
> 对应 docs/09 的功能优先级调整:连接/会话管理提前,UI 打磨(Markdown 等)顺延。
>
> **实现状态(2026-08-17):已按 §7 全部落地并实测**(桥扩展→模型/存储→状态层→UI→测试收口)。
> 与本文档的两处差异:
> 1. §3.5 KeychainService 的 `delete(key:)` **实现前已存在**,无需新增;
> 2. 桥上发现条目打开后 `session/load` 失败(死会话)按评审结论处理:**自动移出目录并提示**,而非保留重试(本地用过、有历史文件的会话仍按 M2.5 保留历史)。

## 1. 范围与非目标

**范围**:
- 连接管理:多个连接 profile(增删改、点击连接),token 安全存储;
- 会话管理:每个 profile 独立的会话空间(切换/新建/删除/重命名/搜索);
- 会话历史:本地持久化 + **远端会话发现**(App 重装/换设备后找回桥上的会话);
- 删除会话时同步清理桥注册表(远端删除)。

**非目标(本期不做,预留)**:
- 并行会话(同时多个会话各自收流)——Phase C,每会话独立 WebSocket,桥已支持;
- 两台设备同时观看同一会话(桥通知广播)——Phase D;
- 会话跨设备云同步(iCloud)。

## 2. 关键设计决策

| 决策 | 内容 | 理由 |
|---|---|---|
| 会话归属键 | `profileID`(稳定 UUID),**不再用 URL** | 隧道 URL 易变(trycloudflare 每次重启换地址),按 URL 关联会话会失联 |
| token 存储 | Keychain,键 `bilink.token.profile.<profileID>` | 随 profile 而非 URL;URL 可随意编辑 |
| profile 存储 | JSON 文件(`BilinkProfiles/profiles.json`),`@Observable` | 与现有 SessionStore 风格一致;不引入 SwiftData |
| 消息文件 | 仍为 `BilinkSessions/<chatID>.json`(扁平) | chatID 是桥生成的 UUID,跨桥冲突概率忽略不计 |
| 远端删除/发现 | 桥新增两个本地扩展方法 `sessions/list`、`sessions/remove` | 复用桥已有 `SessionManager.list()/remove()`;`session/close` 现按"当前绑定会话"取参,删非当前会话语义不符,不改动它 |
| 单活跃连接 | `ConnectionStore` 仍持一个 `ACPClient`(一次连一台机器) | Phase C 才需要多 client 并存 |

## 3. 数据模型

### 3.1 ConnectionProfile(新)

```swift
/// 一台远程机器的连接配置。id 稳定不变;url 可编辑(隧道换地址不影响会话归属)。
struct ConnectionProfile: Identifiable, Codable, Equatable {
    var id: UUID
    var name: String          // "办公室 Mac" 等
    var url: String           // wss://… / ws://…
    var createdAt: Date
    var lastUsedAt: Date?
}
```

### 3.2 ProfileStore(新)

```swift
@Observable
final class ProfileStore {
    private(set) var profiles: [ConnectionProfile]   // 按 lastUsedAt 倒序展示
    func add(name:url:token:) -> ConnectionProfile   // token 写 Keychain(bilink.token.profile.<id>)
    func update(_ profile:ConnectionProfile, token:String?) // token 非-nil 时更新 Keychain
    func delete(id: UUID)   // 级联:Keychain token + 该 profile 全部本地会话(SessionStore.removeProfile)
    func token(for id: UUID) -> String?
    // 持久化:BilinkProfiles/profiles.json
}
```

### 3.3 SessionMeta(改造)

```swift
struct SessionMeta: Identifiable, Codable, Equatable {
    var id: String { chatID }
    var chatID: String
    var title: String            // 可重命名,不再锁死首条消息
    var preview: String?
    var messageCount: Int
    var createdAt: Date
    var updatedAt: Date
    var profileID: UUID          // ← 替换 connectionURL
    var isRemoteOnly: Bool       // true = 由 sessions/list 发现,本地无消息文件,打开时走 grok 回放
}
```

### 3.4 SessionStore(改造)

- `sessions(for profileID: UUID)` / `latest(for profileID: UUID)`(原 URL 参数改 UUID);
- 新增 `rename(chatID:to:)`;
- 新增 `removeProfile(profileID:)`:删除该 profile 全部条目与消息文件(profile 删除时级联);
- 新增 `mergeRemote(records:profileID:)`:把 `sessions/list` 返回的远端会话合并进目录——**跨 profile 按 chatID 去重**(chatID 已存在于任何 profile 下则跳过:同一台桥可能同时有 LAN 与隧道两个 profile,不去重会出现双条目、标题漂移、互相残害的删除);本地没有的创建 `isRemoteOnly = true` 条目(title 回退链:cwd 末段 > "远端会话",打开回放后按 §5.2 补全)。

### 3.5 KeychainService(扩展)

现有 `save/read` 基础上补 `delete(key:)`(profile 删除时清理 token)。

## 4. 状态层改造

### 4.1 ConnectionStore

- `connect(_ profile: ConnectionProfile)`:token 从 `ProfileStore.token(for:)` 取,失败(无 token)直接 `.failed` 提示;
- `disconnect()` 同时清空 `onReconnected`(旧 ChatStore 闭包残留,防切换 profile 后误触发旧会话 reload);
- 其余状态机(idle/connecting/connected/reconnecting/failed)不动;
- `config: ConnectionConfig?` 保留,`ConnectionConfig` 增加 `profileID: UUID` 字段(供 ChatStore 持久化键使用)。

### 4.2 ChatStore

- `latest(for profileID:)` **只返回非 `isRemoteOnly` 的最新条目**:自动恢复的目标必须是"本地用过"的会话;远端发现的会话(可能是另一台设备创建的)只能从列表手动进入,否则启动时会恢复到一个陌生会话;
- 持久化键改挂 profile:`"bilink.chatID.<profileID>"`(原 `<connectionURL>`);
- `init(client:profileID:sessionStore:)`;
- `resume()` 不变:本地历史优先,`isRemoteOnly` 或本地为空时依赖 grok 回放(现有 `startReplayWindow()` 逻辑正好覆盖)。
- 新增三个会话管理入口:

```swift
func deleteSession(chatID: String) async      // 需在线:桥 sessions/remove -> SessionStore.delete -> 若是当前会话则 startNewSession
                                              // 断线时失败保留本地并提示,不做"仅删本地"
func renameSession(chatID: String, to: String) // SessionStore.rename;当前会话直接改
func syncRemoteSessions() async               // 桥 sessions/list -> SessionStore.mergeRemote(聊天页下拉刷新或进入会话列表时调)
```

**`prepareSession()` 恢复顺序(重装/换设备后"继续处理"的关键)**:

```
1. SessionStore.latest(for: profileID)(仅本地用过的会话)有 -> resume
2. 无 -> syncRemoteSessions() 发现远端会话?  有 -> resume 最新的 isRemoteOnly 条目(走 grok 回放)
3. 远端也没有 -> createSession(session/new)
```

不再"本地无记录就盲目新建"——重装 App 后会先接回桥上的原会话继续。

**生命周期收尾规则**:
- 远端会话打开后(回放窗口结束或首条新消息落盘)`isRemoteOnly` 翻转为 `false`,移出「桥上发现」分段;
- `switchTo` 切换前若 `isResponding`,先对**旧会话**发 `session/cancel`(桥的 cancel 按"当前绑定会话"注入 sessionId,切过去后就取消不了旧的,在途 turn 会继续在远程跑);
- `deleteSession` 目标是当前会话时:成功后再 `startNewSession`(此时若失败,现有 `isSessionReady=false` + 错误横幅兜底)。

## 5. UI 设计

### 5.1 页面结构(替换现有 RootView 直连 ConnectView)

```
ProfileListView(常驻主页)
  ├─ 机器列表:name + url + 最后使用时间;点击 -> connect -> ChatView
  ├─ 工具栏 +:ProfileEditView(新增/编辑:name、url、token;token 只写不读显示)
  ├─ 滑动删除 profile:确认弹窗(提示同时删除 token 与该机器全部本地会话)
  └─ 空状态:引导文案(启动桥、填 wss 地址与 token)
ChatView(结构不变)
  ├─ iPhone:会话列表仍为 sheet,增加搜索框、重命名、删除(远端同步)
  ├─ iPad:后续按 09/P1-2 改 NavigationSplitView 侧栏(本期先保持 sheet,不阻塞)
  └─ 会话列表分两段:本地会话 / 「桥上发现」(isRemoteOnly 条目,首次打开走回放)
ConnectView(现连接页)退役,表单逻辑并入 ProfileEditView
```

### 5.2 交互细节

- 连接失败:留在 ProfileListView,该行下方或弹窗显示错误(401 → 提示检查 token;超时/不可达 → 检查地址与桥);
- 正在连接的行显示 ProgressView;重连中进入 ChatView(现状不变);
- 会话列表进入时自动 `syncRemoteSessions()`,顶部细 progress;
- 删除当前会话:先 `deleteSession` 再自动 `startNewSession`(现 onDelete 已如此,补远端调用);
- 机器行信息密度:名称 · 地址 · N 个会话 · 最后使用时间;
- 远端会话标题补全:占位符("远端会话"/"新会话")条目在首条用户消息到达后自动转为正式标题(现有 `touchSessionMeta` 只处理"新会话"占位符,需扩展覆盖"远端会话";重装恢复场景靠回放后的首条用户消息触发)。

## 6. 桥扩展(向后兼容,均为新增)

`acp-server.js` 的 `handleMessage` switch 新增两个本地方法(不经 grok,除 remove 需转发 close):

```js
case "sessions/list": {
  // 只读;返回桥注册表全部可恢复会话(经 WebSocket 鉴权后可见)。
  // 只返回 restorable(grokSessionId 非空)的记录:session/new 失败的孤儿记录
  // (grokSessionId=null)永远无法 load,推给客户端只会"点开必失败"。
  this.reply(ws, msg.id, {
    sessions: this.sessions.list()
      .filter(r => Boolean(r.grokSessionId))
      .map(r => ({
        chatID: r.chatID,
        cwd: r.cwd,
        createdAt: r.createdAt,
        restorable: true,
      })),
  });
  break;
}
case "sessions/remove": {
  const { chatID } = msg.params ?? {};
  const record = chatID ? this.sessions.get(chatID) : null;
  if (!record) return this.replyError(ws, msg.id, -32602, `未知会话: ${chatID}`);
  if (record.grokSessionId) {
    // 尽力而为:grok 断连/超时时 close 会 reject,但注册表删除是主要目的,必须继续
    try { await this.grok.request("session/close", { sessionId: record.grokSessionId }); }
    catch (err) { console.warn(`[bridge] sessions/remove: grok close 失败(忽略): ${err.message}`); }
  }
  this.sessions.remove(chatID);
  if (this.connSessions.get(ws) === chatID) this.unbindConn(ws, chatID); // 删的是当前会话时解绑
  this.reply(ws, msg.id, { ok: true });
  break;
}
```

说明:
- 两个方法都在 WebSocket 鉴权之后,无新增安全面;`sessions/list` 只读注册表,**grok 断连时也可用**(发现照常,load 时才会失败);
- `sessions/remove` 对 grok 的 close 失败不回滚、不阻塞(grok 会话遗留无害);
- **配套修改 `handleSessionNew`**:grok `session/new` 返回错误时,把已 `create()` 的注册表记录回滚 `remove()`(否则产生 `grokSessionId=null` 孤儿记录,只能靠 list 过滤兜底);
- 现有 `session/close` 方法保持原语义(关当前会话)不动。

## 7. 实施步骤(按提交粒度)

| # | 内容 | 涉及文件 | 验证 |
|---|---|---|---|
| 1 | 桥:`sessions/list` + `sessions/remove` + `handleSessionNew` 失败回滚 | `acp-server.js` | `npm run check`;e2e 扩展两个方法的手动验证(wscat) |
| 2 | 模型与存储:`ConnectionProfile`/`ProfileStore`/`KeychainService.delete`;`SessionMeta.profileID` + `isRemoteOnly`;`SessionStore` 改造(rename/removeProfile/mergeRemote 跨 profile 去重) | Models、Stores、Services | CLI 冒烟:增删 profile、会话归属 |
| 3 | 状态层:`ConnectionStore.connect(profile)` + disconnect 清 onReconnected、`ConnectionConfig.profileID`、`ChatStore` 改挂 profileID + `prepareSession` 三级恢复 + `deleteSession`/`renameSession`/`syncRemoteSessions` + `switchTo` 前 cancel 旧会话 | Stores、Networking | CLI chat 回归 |
| 4 | UI:`ProfileListView` + `ProfileEditView`,`RootView` 接线,`ConnectView` 退役 | Views | 模拟器手动:增删改连 |
| 5 | 会话列表强化:搜索、重命名、删除远端同步、远端发现分段 | `SessionListView`、`ChatStore` | 真机/模拟器 + e2e |
| 6 | 测试收口:CLI harness 加多 profile、多会话切换、远端发现场景;更新 `docs/08` 命令 | `test/acp-client-test/main.swift` | 全绿 |

依赖关系:1、2 可并行;3 依赖 2;4、5 依赖 3;6 收尾。注意**新增 Swift 文件要同步 swiftc 文件列表**(docs/08 §5、CLAUDE.md)。

## 8. 测试要点

- **桥**:e2e 脚本补 `sessions/list` 断言(数量随 new/remove 变化);`sessions/remove` 后 `session/load { chatID }` 应报未知会话;`session/new` 失败(如停 serve)后 `sessions/list` 不应多出孤儿条目;
- **CLI**:`profile A 建会话 -> 断开 -> profile B 建会话 -> 会话目录互不可见`;`删除会话 -> 桥 sessions/list 不再包含`;**自动恢复目标**:存在 isRemoteOnly 条目时启动仍恢复最近本地会话(而非远端条目);
- **手动关键场景**:编辑 profile 的 URL(模拟隧道换地址)后,会话列表与历史**不变**、`session/load` 照常恢复(归属键是 profileID 的直接验证);
- **远端发现**:删 App 重装(清 Application Support)→ 连接 → 会话列表出现「桥上发现」条目 -> 打开走回放,回放后移出该分段且标题自动补全;重装的更优路径是**自动接回桥上原会话(prepareSession 三级恢复)而非新建**,需显式验证;
- **同桥双 profile**:为同一台桥建 LAN 与隧道两个 profile,`sessions/list` 合并后同一会话不得出现在两个 profile 下。

## 9. 边界与已知限制

| 场景 | 行为 |
|---|---|
| 桥重启 | 注册表 sessions.json 持久;grok 会话在 `~/.grok/sessions/`;load 失败时现有兜底提示生效 |
| 隧道 URL 变化 | 编辑 profile.url 即可,token/会话不受影响(URL 不再是归属键) |
| token 失效 | 现有 401 分类提示;ProfileEditView 重新填 token |
| 两设备同时用同一桥的不同会话 | 桥多连接天然支持,互不干扰(通知按 chatID 路由) |
| 两设备同时用**同一**会话 | 通知只达最后绑定的连接(Phase D 修复,本期文档标注限制) |
| 删除 profile | 级联删本地(token/会话);桥注册表条目保留但不再可见,无害;如需清理可在删除前逐会话 sessions/remove(暂不做) |
| 同一台桥两个 profile(LAN + 隧道) | 同一 chatID 只归属最先使用它的 profile(mergeRemote 跨 profile 去重);本地消息文件按 chatID 共享,两个 profile 打开的是同一份历史 |
| 切换会话时旧会话有在途 turn | switchTo 前先对旧会话 session/cancel(见 §4.2);若 cancel 失败(断线)仍切换,turn 在远程继续跑完,结果不丢失(回放可见) |
| chatID 跨桥冲突 | UUID,概率忽略;扁平消息文件不按 profile 分目录 |
