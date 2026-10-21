# bbMusic

macOS 上的 QQ 音乐播放器：原生 SwiftUI，用 Last.fm 记录听歌。

## 现在能做什么

搜索歌曲、播放（含 30 秒试听降级）、队列、进度/音量/播放模式、歌词滚动高亮、扫码登录 QQ 音乐、Last.fm 自动记录。

歌单、每日推荐、排行榜、红心写回尚未实现——对应入口会明确说明，而不是假装加载。

## 构建与运行

```sh
# 1. 安装 sidecar 依赖（只需一次）
cd sidecar && npm install && cd ..

# 2. 组装 .app（内嵌 Node 运行时与 sidecar）
./Scripts/build-app.sh

# 3. 打开
open dist/bbMusic.app
```

`NODE_BIN=/path/to/node ./Scripts/build-app.sh` 可指定要内嵌的 Node（需要 20+）。

## Last.fm

应用身份（API key + shared secret）**不在仓库里**——shared secret 足以冒充本应用签名，所以只存 Keychain。每台机器跑一次：

```sh
./Scripts/seed-lastfm.sh     # 交互输入，或 LASTFM_API_KEY=... LASTFM_SECRET=... ./Scripts/seed-lastfm.sh
```

然后在 App 里点侧边栏底部的「连接 Last.fm」，浏览器确认即可（desktop token 流程，不需要回调地址）。

记录规则用 Last.fm 官方的那套：曲目 > 30 秒，且播放满一半或 4 分钟（取先到者），时间戳取开播时刻。**30 秒试听不计入**。断网时排队，恢复后补交，超过 14 天的丢弃（Last.fm 拒收）。

## 音质

播放条右侧的音质菜单只列出**当前歌曲真实存在**的档位与文件大小（用 `/song/batch` 查），
不会给出点下去没声音的选项。默认「自动（最高可用）」，切换时保留播放位置。

## MCP（给大模型用）

App 内置一个本地 MCP 端点，运行中即可被 LLM 客户端调用：

- 地址：`http://127.0.0.1:43119/`
- 认证：`Authorization: Bearer <token>`，token 在「设置 → MCP」里复制
- 只监听回环地址；不带 token 一律 401

工具（10 个）：`search_music`、`play_track`、`playback_control`、`now_playing`、
`list_playlists`、`playlist_tracks`、`list_albums`、`liked_songs`、`track_qualities`、`lyrics`。

可以直接对模型说「放一首稻香」，它会 `search_music` → `play_track`。

**只读 + 播放控制**：没有任何写操作，模型无法改你的歌单、红心或 Last.fm 记录。

## 自检

界面无法从终端观察（截屏与辅助功能都受 TCC 限制），所以有一条无头自检，在真实 bundle 内跑真实链路：

```sh
./dist/bbMusic.app/Contents/MacOS/bbMusic --self-test
```

逐步输出 `PASS`/`FAIL`（sidecar → 连接 → 搜索 → 歌词 → 取流 → 播放），退出码即结果。

## 未登录时

QQ 音乐匿名只能拿到 30 秒试听，完整播放需要登录。播放条会标注「试听 30 秒」，不会假装是完整曲目。

## 文档

- [`goal-and-requirements.md`](goal-and-requirements.md) — 产品目标、能力范围、非目标
- [`architecture-design.md`](architecture-design.md) — 拓扑、模块边界、不变量、已实测的约束
