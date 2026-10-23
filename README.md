<img src="Assets/icon/AppIcon-1024.png" width="72" align="left" alt="bbMusic">

# bbMusic

macOS 上的 QQ 音乐播放器：原生 SwiftUI，用 Last.fm 记录听歌。

一个窗口、三个区域、没有广告位和直播入口。曲库来自自托管的 QQ 音乐 API，播放记录交给 Last.fm。

界面跟随图标：深林绿的侧边栏 + 暖纸白的内容区，浅色与深色外观各一套。

| 浅色 | 深色 |
|---|---|
| ![浅色](docs/screenshots/01-search.png) | ![深色](docs/screenshots/dark/01-search.png) |

## 功能

### 曲库与发现

| | |
|---|---|
| **搜索** | 歌曲 / 专辑 / 歌单 / 歌手四类分别搜索；结果逐页流式加载（一页到就显示一页，滚到底自动取下一批）；可按年份、作曲家、演奏者/乐团、专辑本地筛选 |
| **每日推荐** | 账号的 30 首每日推荐（上游固定集合，不支持翻页） |
| **排行榜** | 24 个榜单，分地区榜 / 特色榜 / 全球榜；进榜看曲目，滚到底加载下一批 |
| **我喜欢** | 红心歌曲列表，可直接取消红心 |
| **歌单** | 自建与收藏的歌单，格子展示；收藏的歌单显示「收藏」标记 |
| **专辑** | 收藏的专辑，格子展示；卡片显示年份与艺术家 |

### 播放

| | |
|---|---|
| **播放控制** | 播放/暂停、上一首/下一首、进度拖动、音量、播放模式（顺序/全部循环/单曲循环） |
| **音质** | 只列出**当前歌曲真实存在**的档位与文件大小（128K / 320K / AAC / FLAC / APE），切换时保留播放位置；播放条显示上游实际给出的格式 |
| **播放队列** | 播放条最右侧打开，双击跳到某首、右键移除、清空 |
| **歌词** | LRC 滚动高亮，有翻译时一并显示；整窗切换，播放条常驻 |
| **古典友好** | 专辑接口提供结构化古典数据（作曲家、作品、碟号）时优先使用；没有时从标题推导作品号（`Op.` / `BWV` / `KV` / `Hob.` / `D.` / `RV` / `WoO` / `S.`，含 `No. 2` 子编号）；古典曲目显示两行，多碟专辑按碟分组 |

### 账号与记录

| | |
|---|---|
| **QQ 音乐登录** | 扫码登录（QQ 音乐 App / 手机 QQ / 微信），登录态加密落盘，重启不用重扫 |
| **红心与收藏** | 歌曲红心、收藏专辑、收藏歌单，立即写回 QQ 音乐账号；成功给短提示，失败回滚并说明原因 |
| **Last.fm** | 浏览器内授权；开播发 now-playing；按官方规则记录（曲目 > 30 秒且播满一半或 4 分钟，时间戳取开播时刻）；断网排队，恢复后补交；超过 14 天丢弃 |
| **设置窗口** | `⌘,` 管理两个账号的登录状态与 MCP token |

### 给大模型用

内置本地 MCP 端点，运行中即可被 LLM 客户端调用：

```
地址:  http://127.0.0.1:43119/
认证:  Authorization: Bearer <token>   ← 设置 → MCP 里复制
```

10 个工具：`search_music`、`play_track`、`playback_control`、`now_playing`、`list_playlists`、`playlist_tracks`、`list_albums`、`liked_songs`、`track_qualities`、`lyrics`。

可以直接对模型说「放一首稻香」，它会搜索并播放。**只读 + 播放控制，没有任何写操作**——模型不能改歌单、红心或 Last.fm。只监听回环地址，无 token 一律 401。

## 截图

| 每日推荐 | 排行榜 |
|---|---|
| ![每日推荐](docs/screenshots/02-daily.png) | ![排行榜](docs/screenshots/03-charts.png) |

| 榜单曲目 | 歌手详情 |
|---|---|
| ![榜单曲目](docs/screenshots/04-chart-detail.png) | ![歌手详情](docs/screenshots/08-artist.png) |

| 歌单 | 专辑 |
|---|---|
| ![歌单](docs/screenshots/05-playlists.png) | ![专辑](docs/screenshots/06-albums.png) |

| 我喜欢 | 古典专辑 |
|---|---|
| ![我喜欢](docs/screenshots/07-liked.png) | ![古典专辑](docs/screenshots/09-album-classical.png) |

| 播放队列 | 歌词 |
|---|---|
| ![播放队列](docs/screenshots/10-queue.png) | ![歌词](docs/screenshots/11-lyrics.png) |

截图由 App 自己渲染导出，可复现：

```sh
./dist/bbMusic.app/Contents/MacOS/bbMusic --capture-screenshots docs/screenshots
./dist/bbMusic.app/Contents/MacOS/bbMusic --appearance dark --capture-screenshots docs/screenshots/dark
```

## 构建与运行

需要 macOS 14+、Xcode 命令行工具、Node 20+（仅构建时用来装依赖；运行时不依赖系统 Node）。

```sh
# 1. 安装 sidecar 依赖（只需一次）
cd sidecar && npm install && cd ..

# 2. 组装 .app（内嵌 Node 运行时与 sidecar）
./Scripts/build-app.sh

# 3. 打开
open dist/bbMusic.app
```

`NODE_BIN=/path/to/node ./Scripts/build-app.sh` 可指定要内嵌的 Node。

图标源在 `Assets/icon/AppIcon.svg`，由 `Scripts/make-icon.py` 生成（需要 `brew install librsvg` 提供 `rsvg-convert`）；构建只是把已提交的 `AppIcon.icns` 拷进 bundle，平时改图标才需要跑它。

## Last.fm

应用身份（API key + shared secret）**不在仓库里**——shared secret 足以冒充本应用签名，所以只存本地文件（0600）。每台机器跑一次：

```sh
./Scripts/seed-lastfm.sh     # 交互输入，或 LASTFM_API_KEY=... LASTFM_SECRET=... ./Scripts/seed-lastfm.sh
```

然后在 App 里点侧边栏底部的「连接 Last.fm」，浏览器确认即可（desktop token 流程，不需要回调地址）。

## 自检

界面无法从终端直接观察，所以有一条无头自检，在真实 bundle 内跑真实链路：

```sh
./dist/bbMusic.app/Contents/MacOS/bbMusic --self-test
```

逐步输出 `PASS`/`FAIL`，退出码即结果。覆盖：sidecar 启动、登录态、搜索与分页、四类搜索、库读取、专辑/歌单/歌手、古典推导、播放与音质、每日推荐、排行榜翻页、红心写入往返、MCP 端点、Last.fm 凭据与记录规则。

截图是同一套办法：`--capture-screenshots` 在 App 内渲染每一页，`--appearance dark` 让同一组页面在深色外观下再跑一遍——不需要改动系统外观设置。

## 未登录时

QQ 音乐匿名只能拿到 30 秒试听，完整播放需要登录。播放条会标注「试听 30 秒」，不会假装是完整曲目。

## 已知限制

- **只做 macOS**，不上架 App Store，不做自动更新。
- **每日推荐不能翻页**：上游固定返回 30 首，`offset` / `limit` 被忽略。
- **厂牌与指挥不做筛选**：QQ 音乐搜索响应没有这两个字段，用正则从描述里猜会给出不可靠的结果。
- **下架曲目无法播放**：版权下架后上游会抹掉 `mid` 与 `album.mid`，这类歌单（例如「李志」）没有封面也播不了。
- **ad-hoc 签名**：媒体键与部分系统集成未验证。

## 文档

- [`goal-and-requirements.md`](goal-and-requirements.md) — 产品目标、能力范围、非目标
- [`architecture-design.md`](architecture-design.md) — 拓扑、模块边界、不变量、已实测的上游约束
