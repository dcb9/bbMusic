---
id: architecture-design
type: architecture-design
title: bbMusic 架构设计
status: draft
parent: goal-and-requirements
depends-on:
  - goal-and-requirements
tags:
  - macos
  - swiftui
  - avplayer
  - node-sidecar
  - lastfm
---

# bbMusic 架构设计

一个 SwiftUI 应用 + 一个只监听回环地址的 Node sidecar，把「QQ 音乐曲库」和「Last.fm 记录」缝在一起。核心取舍：**播放器与队列不认识任何平台，平台适配器不认识任何界面。**

## 拓扑

```mermaid
flowchart LR
  subgraph App["bbMusic.app（主进程）"]
    UI["SwiftUI 视图<br/>侧边栏 / 列表 / 播放条 / 歌词"]
    PB["Playback<br/>AVPlayer + 队列 + 播放模式"]
    NP["Now Playing<br/>MPNowPlayingInfoCenter + 远程指令"]
    PL["Platform 层<br/>MusicPlatform 协议"]
    QQ["QQMusicPlatform<br/>适配器"]
    SC["Scrobble<br/>Last.fm 客户端 + 待提交队列"]
    LY["Lyrics<br/>LRC 解析 + 高亮"]
    ST["Storage<br/>Keychain + JSON 状态"]
  end

  subgraph Side["Node sidecar（子进程）"]
    W["wrapper.js<br/>回环绑定 + 端口上报"]
    API["@yakult-green-tea/qq-music-api<br/>Koa2 + TS"]
  end

  UP["QQ 音乐上游"]
  LF["Last.fm API"]

  UI --> PB
  UI --> PL
  UI --> LY
  PB --> NP
  PL --> QQ
  QQ -->|"HTTP 127.0.0.1:动态端口"| W
  W --> API
  API -->|"HTTPS"| UP
  PB -->|"播放进度事件"| SC
  SC -->|"HTTPS"| LF
  SC --> ST
  PB --> ST
```

## 进程与端口

**主进程**持有全部用户可见状态：界面、播放、队列、歌词、scrobble 队列。它是唯一会崩溃后需要恢复用户感知的进程。

**sidecar** 只做一件事：把 QQ 音乐上游的逆向接口翻译成 HTTP JSON。它无界面、无用户状态，可以随时被杀掉重启。

三个具体约定：

1. **回环绑定 + 动态端口。** 上游包在导入时就 `app.listen(port)`，且不指定 host——即绑定所有网卡（实测为 `::`）。本项目用自带的 `wrapper.js` 作为 sidecar 入口：设 `NODE_ENV=test` 让上游跳过自己的 `listen()`（此时它导出的 `server` 为 `null`），再对默认导出的 Koa app 执行 `listen(0, '127.0.0.1')`，得到回环 + 系统分配的空闲端口，并向 stdout 打印一行 `BBMUSIC_PORT <n>`。主进程读这一行拿端口，因此不存在端口冲突，局域网也无法访问该服务。
   两个实现约束：上游在导入时用 zod 校验 `PORT > 0` 且校验失败即退出，所以**不能**传 `PORT=0`（由 wrapper 自己绑 0，并清掉继承来的 `0`）；`NODE_ENV` 必须在 `require` 之前赋值，上游在导入时读取它。
2. **会话存活靠文件，不靠进程。** sidecar 以 `QQ_SESSION_SECRET` + `QQ_AUTH_SESSION_PATH`（指向 `~/Library/Application Support/bbMusic/qq-session/`）启动，登录态加密落盘。sidecar 崩溃重启后不需要重新扫码。
3. **崩溃恢复。** 主进程持有子进程句柄；非正常退出时按指数退避重启（1s / 2s / 5s，连续 3 次失败则向界面报错并提供「重试」），重启期间界面显示「服务未就绪」而不是空白列表。

**Last.fm 不经过 sidecar**：只有 4 个端点，直接在主进程用 `URLSession` 调用，省一个进程的复杂度。

## 模块边界

| 模块 | 负责 | 明确不做 |
| --- | --- | --- |
| `UI` | 侧边栏导航、列表渲染、播放条、歌词视图、空/加载/错误状态 | 不直接发网络请求，不持有 `AVPlayer` |
| `Playback` | 队列、当前曲目、播放模式、进度、音量、失败重试 | 不知道曲目来自哪个平台，不做网络请求 |
| `Platform` | 平台无关模型（`Track` / `Playlist` / `Lyrics`）、`MusicPlatform` 协议、sidecar 生命周期 | 不碰界面、不碰 `AVPlayer`、不碰 scrobble |
| `QQMusicPlatform` | 把 QQ 音乐响应映射为统一模型；扫码登录流程；红心写回；取流地址 | 不决定「播放什么」，只回答「怎么拿到它」 |
| `Scrobble` | Last.fm 授权、now-playing、播放判定、待提交队列持久化 | 不控制播放，只观察播放进度 |
| `Lyrics` | LRC 解析（含翻译行）、按时间定位当前行 | 不拉取歌词，由 `Platform` 提供 |
| `Storage` | Keychain 封装、应用状态文件、目录约定 | 不含业务判断 |

**依赖方向**：`UI → Playback / Platform / Lyrics`，`Playback → Platform`（只为取流地址），`Scrobble → Storage`。没有任何模块反向依赖 `UI`。`QQMusicPlatform` 是唯一知道 QQ 音乐存在的地方——换成 Spotify 时它整体替换，其余模块不变。

## 数据流：播放一首歌

1. 用户在列表里点一首 → `Playback` 把它设为当前曲目，并把列表其余部分作为队列（`Playback` 是队列的唯一真相）。
2. `Playback` 向 `Platform` 要取流地址：`streamURL(for:quality:)` → `QQMusicPlatform` 调 `/getMusicPlay/:songmid?quality=best`。
3. 拿到 URL 后创建 `AVPlayerItem` 播放；同时更新 `MPNowPlayingInfoCenter`（标题、歌手、专辑、封面、时长）。
4. 播放进度事件喂给 `Scrobble`：开播即发 now-playing；达到阈值（见下）记一条待提交记录。
5. 同时 `Platform` 拉 `/getLyric` → `Lyrics` 解析；用户切到歌词视图时按 `currentTime` 高亮。

**取流失败的处理**：`url_unavailable` 等 `restriction` 直接作为可读提示呈现（「这首歌暂时无法播放」+ 可能原因），不静默跳下一首。

**媒体 URL 必须是 https。** QQ 音乐返回的是 `http://` 媒体地址。AVFoundation 把媒体加载放在独立进程里，**App 自己的 App Transport Security 例外对那个进程不生效**，所以纯 http 资源在任何 `.app` 内都以 `-1022` 失败——已实测：同一 URL 在裸命令行二进制里能播、在 bundle 内不能播，而它的 `https` 孪生地址两边都能播。CDN 本身支持 TLS，因此适配器统一把 scheme 升级为 https，而不是放宽传输安全。这也是「本地转发降级」方案被否掉的原因：转发本身也会是 http。

## 关键不变量

- **队列是唯一真相。** 播放列表、当前曲目、播放模式全部由 `Playback` 的队列状态推导；界面任何一处都不得自行维护「正在播放的是哪首」的副本。
- **一条播放记录只提交一次。** 待提交记录的幂等键是 `(平台, 曲目 ID, 开始播放时间戳)`；重试与补交都按这个键去重，因此重启、断网重连都不会产生重复 scrobble。
- **scrobble 判定跟随 Last.fm 官方规则**：曲目长于 30 秒，且播放满 50% 或 4 分钟（取先到者）。不满足则丢弃，不做「凑数」提交。
- **补交有时间上限**：Last.fm 不接受超过 14 天的记录（官方未写入文档，社区与官方回复一致）。待提交队列按此裁剪，过期条目丢弃并在诊断日志里留下一条，绝不假装成功。
- **界面状态可从状态推导。** 侧边栏选中项、列表内容、播放条、歌词高亮都由「当前导航 + 队列 + 当前曲目 + 加载状态」决定，不存在只能由某次点击写入的隐藏标志。
- **平台能力差异显式呈现。** 导航固定不随平台变化；未登录或平台不支持时，对应位置显示明确文案（如「需要先登录 QQ 音乐」「此平台暂不支持每日推荐」），不隐藏入口、不静默失败。

## 状态与持久化

| 数据 | 位置 | 生命周期 |
| --- | --- | --- |
| QQ 音乐会话 | `~/Library/Application Support/bbMusic/qq-session/`（sidecar 加密写入） | 跨重启；过期靠 `/login/refresh` 续期 |
| Last.fm 会话密钥 | Keychain | 跨重启 |
| 待提交 scrobble 队列 | 应用状态 JSON | 跨重启；14 天裁剪 |
| 播放队列与当前曲目 | 应用状态 JSON | 跨重启（恢复上次队列，不自动续播） |
| 窗口尺寸与导航位置 | 系统窗口状态 | 系统管理 |

## 打包与运行

- **无沙盒、不公证**（自用构建）：主进程可直接 `Process` 启动子进程、可访问应用支持目录。
- **Node 运行时随包分发**：`Contents/Resources/node/bin/node`（arm64）+ `Contents/Resources/qq-api/`（打包后的 sidecar 与 `node_modules`）。用户无需自备 Node。
- **启动顺序**：应用启动 → 拉起 sidecar → 读到端口后探测 `/login/status` → 已登录则加载侧边栏数据，未登录则引导扫码。
- **退出顺序**：先停播放、flush 待提交队列，再向 sidecar 发终止信号并等待退出（超时则强杀）。

## 决策记录

**用 `AVPlayer` 而不是 `AVQueuePlayer`。** `AVQueuePlayer` 的队列是「播完自动前进」的单调序列，任意跳转、插入、移除、随机播放都要绕开它；本项目的队列需要被用户随时重排。由 `Playback` 自己持有队列、在曲目结束时推进 `AVPlayer`，模型更简单，也更符合「队列是唯一真相」。

**自己写 `--self-test`，而不是靠截图验证。** 终端进程无法截屏、也无法取得辅助功能权限，界面无法从命令行观察。`bbMusic --self-test` 在真实 bundle 内跑真实链路（sidecar → 适配器 → 搜索 → 歌词 → 取流 → AVPlayer）并逐步输出 PASS/FAIL，退出码即结果。它比截图更能证明「真的能工作」，也是后续的回归检查手段。

**MVP 不用 WebView 播放。** QQ 音乐经该 API 能拿到直链音频，`AVPlayer` 可直接播放，无需 WebView。WebView 是**以后接入 DRM 平台**（YouTube Music、Spotify）时的形态：那些平台只能靠已登录的网页会话出声，届时新增的适配器在隐藏 WebView 里播放并通过 JS 桥接回传进度——`MusicPlatform` 协议为此保留「平台自己决定怎么出声」的空间（`streamURL` 返回直链，或适配器自带播放后端），但 MVP 不实现这条路径。

**Last.fm 直连而非库。** 只需 `auth.getToken` / `auth.getSession` / `track.updateNowPlaying` / `track.scrobble`，签名算法是 MD5 拼接参数，自己实现约 150 行，比引入依赖更好控制失败与重试。

## 风险

| 风险 | 影响 | 应对 |
| --- | --- | --- |
| 上游 QQ 音乐接口变动 | 搜索/播放/歌单全部失效 | 适配器隔离；失效时界面报「QQ 音乐接口不可用」，播放器与 scrobble 不受影响 |
| 设备数上限（上游 `20279`） | 无法登录 | 引导用户到 QQ 音乐 App 的设备管理移除旧设备后重扫 |
| 直链需要 Referer 校验 | 播放 403 | 实测无需 Referer；真正的问题是 http/ATS，已由 https 升级解决 |
| 14 天补交上限 | 长期离线后记录丢失 | 队列裁剪 + 日志留痕，界面不承诺超出窗口的补交 |
