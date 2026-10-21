# bbMusic

macOS 上的 QQ 音乐播放器：原生 SwiftUI，用 Last.fm 记录听歌。

## 现在能做什么

搜索歌曲、播放（含 30 秒试听降级）、队列、进度/音量/播放模式、歌词滚动高亮、扫码登录 QQ 音乐。

歌单、每日推荐、排行榜、红心写回、Last.fm 记录尚未实现——对应入口会明确说明，而不是假装加载。

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
