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
    SC["Scrobble<br/>Last.fm 客户端 + 待提交队列 + 规则引擎"]
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
2. **会话存活靠文件，不靠进程。** sidecar 以 `QQ_SESSION_SECRET` + `QQ_AUTH_SESSION_PATH`（指向 `~/Library/Application Support/bbMusic/`）启动，登录态加密落盘。sidecar 崩溃重启后不需要重新扫码。
   **两个都必须做，缺任一个登录就是假的**：上游被 `require` 时**不会**自己安装持久化仓库，必须由宿主显式调用 `configureAuthSessionRepository(createConfiguredAuthSessionRepository(env))`，否则会话仓库留在内存、恢复 0 条，所有需登录的接口回 401；同时扫码 `803` 时上游通过 `Set-Cookie: qqmusic_session=<token>` 下发会话令牌，无 cookie 存储的 `URLSession` 会静默丢弃它，主进程必须从响应头取出、落盘（0600）并在每次请求带上 `X-QQ-Session`。
3. **崩溃恢复。** 主进程持有子进程句柄；非正常退出时按指数退避重启（1s / 2s / 5s，连续 3 次失败则向界面报错并提供「重试」），重启期间界面显示「服务未就绪」而不是空白列表。

**Last.fm 不经过 sidecar**：只有 4 个端点，直接在主进程用 `URLSession` 调用，省一个进程的复杂度。

## 模块边界

| 模块 | 负责 | 明确不做 |
| --- | --- | --- |
| `UI` | 侧边栏导航、列表渲染、播放条、歌词视图、空/加载/错误状态 | 不直接发网络请求，不持有 `AVPlayer` |
| `Playback` | 队列、当前曲目、播放模式、进度、音量、失败重试 | 不知道曲目来自哪个平台，不做网络请求 |
| `Platform` | 平台无关模型（`Track` / `Playlist` / `Lyrics`）、`MusicPlatform` 协议、sidecar 生命周期 | 不碰界面、不碰 `AVPlayer`、不碰 scrobble |
| `QQMusicPlatform` | 把 QQ 音乐响应映射为统一模型；扫码登录流程；红心写回；取流地址 | 不决定「播放什么」，只回答「怎么拿到它」 |
| `Scrobble` | Last.fm 授权、now-playing、播放判定（官方规则）、待提交队列持久化 | 不控制播放，只观察播放进度 |
| `Lyrics` | LRC 解析（含翻译行）、按时间定位当前行 | 不拉取歌词，由 `Platform` 提供 |
| `Storage` | Keychain 封装（Last.fm API key / secret / session）、应用状态文件、目录约定 | 不含业务判断 |

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
- **scrobble 的“成功”以 Last.fm 的正文为准，不以 HTTP 状态为准。** Last.fm 在被忽略时同样返回 `200`，正文里是 `@attr.ignored` / `@attr.accepted`。把 `200` 当成功会把没提交上去的记录从队列里删掉，造成静默丢失。
- **只有 Last.fm 真正收下的记录才出队。** `accepted` 与 `ignored` 都算「已了结」（ignored 是永久性拒收，重试不可能成功），其余留在队列里等下次。
- **试听不算播放。** 30 秒试听既不发 now-playing 也不记 scrobble——它会把「听了半首歌」写成假记录。
- **平台能力差异显式呈现。** 导航固定不随平台变化；未登录或平台不支持时，对应位置显示明确文案（如「需要先登录 QQ 音乐」「此平台暂不支持每日推荐」），不隐藏入口、不静默失败。

## Last.fm 集成

**认证**走 Last.fm 的 desktop 流程：`auth.getToken` → 在浏览器打开 `last.fm/api/auth` → 轮询 `auth.getSession`。轮询让回调 URL 变得不必要，因此不需要本地 HTTP 服务接回调。轮询期间 `error 14` 是正常中间态，不是失败。

**签名**是 `md5(按 key 排序拼接 key+value + shared secret)`，`api_sig` 与 `format` 不参与。批量 scrobble 用数组下标（`artist[0]`…），参数名按 ASCII 排序，因此 `artist[10]` 排在 `artist[2]` 之前。

**凭证**存 Keychain（API key、shared secret、session key、用户名）。源码只带占位常量，首次使用时写入——shared secret 足以冒充本应用签名，不能进 git，也不该以可被 `strings` 读出的形式留在二进制里。

**判定规则**（Last.fm 官方）：曲目 > 30 秒，且播放满 `min(时长/2, 240s)`；时间戳取**开播时刻**。一条播放只记一次。

**队列**：持久化 JSON，按 `(曲目 ID, 开播时间)` 幂等去重，每批最多 50 条。超过 14 天的记录直接丢弃（Last.fm 拒收，未文档化但已实测）。

## 状态与持久化

| 数据 | 位置 | 生命周期 |
| --- | --- | --- |
| QQ 音乐凭证 | `~/Library/Application Support/bbMusic/qq-session.json`（sidecar 加密写入，0600） | 跨重启；过期靠 `/login/refresh` 续期 |
| QQ 音乐会话令牌 | `~/Library/Application Support/bbMusic/qq-session-token`（0600） | 跨重启；随每次请求以 `X-QQ-Session` 发送 |
| Last.fm API key / secret / 会话密钥 | `lastfm.json`（0600，`.gitignore`） | 跨重启；退出登录只清会话，保留应用身份 |
| 待提交 scrobble 队列 | 应用状态 JSON | 跨重启；14 天裁剪 |
| 播放队列与当前曲目 | 应用状态 JSON | 跨重启（恢复上次队列，不自动续播） |
| 窗口尺寸与导航位置 | 系统窗口状态 | 系统管理 |

## 打包与运行

- **无沙盒、不公证**（自用构建）：主进程可直接 `Process` 启动子进程、可访问应用支持目录。
- **Node 运行时随包分发**：`Contents/Resources/node/bin/node`（arm64）+ `Contents/Resources/qq-api/`（打包后的 sidecar 与 `node_modules`）。用户无需自备 Node。
- **启动顺序**：应用启动 → 拉起 sidecar → 读到端口后探测 `/login/status` → 已登录则加载侧边栏数据，未登录则引导扫码。
- **退出顺序**：先停播放、flush 待提交队列，再向 sidecar 发终止信号并等待退出（超时则强杀）。

## 古典音乐展示

**专辑接口提供真正的结构化古典数据**：`/getAlbumInfo?albummid=…` 的响应里有 `classic_list`，按曲目区间给出 `author`（作曲家）、`collection`（作品，含 K.620 这类编号）与 `CD`（碟号）。因此专辑页优先使用平台给的事实，`Track` 上的 `composer` / `work` / `disc` 由适配器填充，多碟专辑按 `disc` 显示碟标题。**只有搜索与歌单拿不到这些字段时**才退回下面的推导。

接口形状有个坑：路由是 `/getAlbumInfo/:albummid?`，路径段是**可选**的，把 id 放进路径会得到 `no albummid`，必须用查询参数。

QQ 音乐其余位置不提供结构化的作曲家/作品号/演奏者字段。`TrackDisplay` 从现有字段**推导**：作品号（`Op.`/`BWV`/`KV`/`Hob.`/`D.`/`RV`/`WoO`/`S.`，含 `No.` 子编号）、演奏者（把合并的歌手字段按 `/ 、 ; &` 拆开）、以及是否古典（作品号、作品体裁词、或多位演奏者+长标题）。判断偏保守：它只影响一行的排布与是否显示两行，绝不影响播放或 scrobble；推不出来的字段保持原样，不凭空补作曲家。

## 每日推荐与排行榜

`/user/daily-songs` 返回 30 首（需登录）；`/recommend/toplists` 返回**分组**结构（地区榜/特色榜/全球榜，共 24 个榜单），每榜带封面、简介、曲数与更新时间；`/recommend/toplist?id=` 取该榜曲目。榜单本身匿名可读，只有每日推荐需要登录。

曲目行要能点进歌手与专辑，因此 `Track` 额外携带 `artistID`（singer 数组首个非空 `mid`）与 `albumID`（`album.mid`）。没有 id 的行不可点击——不给一个点了没反应的链接。

## 歌手详情与写操作

**歌手接口的参数名不统一**，两个都踩过坑：`/singer/detail`、`/singer/songs` 读 `mid`（不是 `singermid`），而 `/getSingerAlbum` 的路径模板写着 `/:singermid?/:limit?/:page?`，**实际却只读查询参数**——把值放进路径会得到 `"no singermid"`。判断依据是看 handler 里 `queryRaw('…')` 的键名，而不是看路径模板。

**写操作**（`/user/song/like`、`/user/album/subscribe`、`/user/playlist/subscribe`）是真实账号变更，因此：
- 上游实现本身是**先读当前状态、已满足即成功**，所以重试不会把值翻回去；
- 红心在界面上**先乐观翻转**，写入失败再翻回并显示原因——不假装成功；
- 红心需要数字 `id`，而搜索结果里的 `id` 可能是 0，所以先经 `/song/batch` 解析真实 id。

## 音质与 MCP

**音质**：`/getMusicPlay` 只说「这个档位拿不到链接」，不说「有哪些档位」。`/song/batch` 对每档回报真实文件大小，非零即存在——界面因此只列真实可用的档位。`AudioQuality` 枚举负责请求值（`320`/`128`/`m4a`/`flac`/`ape`），`deliveredQuality` 记录**上游实际给的**格式（从文件名推断），因为 `best` 可能降级。

**MCP**：App 内 `NWListener` 只绑 `127.0.0.1:43119`，Bearer token 每次安装生成一次（0600 落盘）。10 个工具覆盖搜索、播放控制、库读取、音质、歌词，**没有任何写操作**——模型可以点歌，不能改歌单/红心/Last.fm。这个边界是有意的：写操作一旦被误调就是真实的账号变更。

## 导航与歌单入口

侧边栏**只有固定导航**（搜索 / 我喜欢 / 歌单 / 专辑），不内联列出歌单。歌单的唯一入口是「歌单」页的格子——两处并列同一份列表既冗余，也会在打开某个歌单时让侧边栏突然长出一整列列表。

**打开歌单不改 `section`**：内容区切到该歌单的曲目，导航选中态保持在原处，否则从搜索结果点歌单会连带把侧边栏跳走。

## 歌单来源与命名

`/user/playlist` **同一个数组里混着两种结构**：用户自建的用 `dirName` / `songNum` / `picUrl`，收藏别人的用 `name` / `songnum` / `logo`（小写）。只读第一种会让所有收藏歌单显示成「未命名」。解析时按两种键兜底，并用 `isCollected` 标记出来。

封面**只取 API 给的**（`picUrl` / `logo` / `bigpicUrl`），没有就显示占位图标，不做推导。曾试过用第一首有封面的曲目顶替，但对下架歌单无效：例如「李志」这个歌单的 82 首曲目 `mid` 与 `album.mid` 全为空、`interval` 为 0（版权下架后上游抹掉了这些字段），既拼不出封面也播不了。

封面 URL 与音频一样是 `http://`，而图片走 URLSession，**ATS 同样会拦**，所以统一升级为 https。

## 搜索的分页、筛选与完整展示

**分页**：上游每页固定 20 条（`limit=50` 也只给 20），`total` 可到上千。界面**按批展示**：一批 100 条（= 5 个上游页），**滚动到底自动取下一批**，不需要点按钮。

**逐页展示**：每一页（20 条）拿到就立刻发布给界面，不等一批 100 条取完。所以「搜索中」只表示"还有页在飞"，不表示"没东西可看"——首屏 20 条到齐后列表就一直可见并向上长。

**上游会间歇性返回空页**：0 条、`total 0`、`more false`，然后下一页又恢复正常（实测同一查询在第 3–4 页与第 10–12 页出现）。把它当成「结果到底了」会让每次搜索都静默截断在 80 条左右。因此空页被**跳过并继续翻页**；只有连续 4 个空页时才判断是否真到底——已取够 `total` 才算完，否则**保留当前位置**让下次滚动重试，而不是把用户丢在 100/989 的位置上。

筛选只作用于**已载入**的结果，底部显示「已载入 N / M」，避免误以为筛选漏了数据。筛选生效时**不自动翻页**——筛选后的列表比未筛选短，滚到底不代表用户已经看完，按那个信号加载会一路拉到底。

**筛选维度只取数据里真有的**：`time_public` → 年份；`desc` 的「作曲:」前缀 → 作曲家；歌手字段 → 演奏者/乐团；专辑名。QQ 音乐搜索响应**没有厂牌与指挥字段**，所以不做这两项——用正则从专辑描述里猜会给出不可靠的筛选。筛选选项由已取到的结果动态生成，不会出现选了却 0 条的空维度。

**完整展示**：曲目标题不再单行截断，改为按内容换行（`fixedSize(vertical:)`），行高由内容决定。古典标题常常长到一行放不下，截断会把作品名、调性与作品号一起切掉。

## 搜索与网格

`/search` 用同一个端点、靠 `type=song|album|playlist|singer` 切换，**四种类型的 item 结构完全不同**：专辑是 `albummid`/`singer`(字符串)，歌单是 `dissid`/`dissname`/`nickname`，歌手是 `singerMID`/`singerName`/`singerPic`。所以 `SearchKind` 与 `SearchResults` 各自建模，不复用一个 parser。

搜索到的**他人歌单**走 `/getSongListDetail?disstid=…`，曲目藏在 `response.cdlist[0].songlist` 里——没有顶层 `songlist`，按顶层找会静默得到空歌单。

歌单与专辑用自适应格子（封面 120pt）而不是列表：封面是这两个东西的识别特征，列表里只能看到名字。

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
