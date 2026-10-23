import SwiftUI

/// Standard settings window (⌘,). The two accounts, each with its current state and the one action
/// that matters, plus the two things about the app itself a user can reasonably want to change: how
/// it looks and how a model may talk to it.
struct SettingsView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        TabView {
            AppearanceSettings(model: model)
                .tabItem { Label("外观", systemImage: "circle.lefthalf.filled") }
            QQMusicSettings(model: model)
                .tabItem { Label("QQ 音乐", systemImage: "music.note") }
            LastFMSettings(model: model)
                .tabItem { Label("Last.fm", systemImage: "waveform.path.ecg") }
            MCPSettings(model: model)
                .tabItem { Label("MCP", systemImage: "brain") }
        }
        .frame(width: 500, height: 320)
    }
}

// MARK: - Appearance

private struct AppearanceSettings: View {
    @ObservedObject var model: AppModel
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Form {
                LabeledContent("外观") {
                    Picker("", selection: Binding(
                        get: { model.appearance },
                        set: { model.setAppearance($0) }
                    )) {
                        ForEach(AppearanceMode.allCases) { mode in
                            Text(mode.label).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 240)
                }
                LabeledContent("当前") {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(Color.primary.opacity(0.25))
                            .frame(width: 7, height: 7)
                        Text(currentText)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .formStyle(.grouped)

            Spacer(minLength: 0)

            Text("跟随系统时，窗口用 macOS 的外观设置；选浅色或深色只影响 bbMusic，不改变系统本身。选择会被记住。")
                .font(.system(size: 10.5))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(16)
        }
    }

    /// Says what is on screen right now, which is the only way to tell that "跟随系统" resolved to
    /// something — the picker itself shows the preference, not its effect.
    private var currentText: String {
        switch model.appearance {
        case .system:
            return colorScheme == .dark ? "跟随系统 · 当前深色" : "跟随系统 · 当前浅色"
        case .light:
            return "浅色"
        case .dark:
            return "深色"
        }
    }
}

// MARK: - QQ Music

private struct QQMusicSettings: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Form {
                LabeledContent("状态") {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(model.connection.isConnected ? Color.green : Color.secondary.opacity(0.4))
                            .frame(width: 7, height: 7)
                        Text(model.connection.isConnected ? "已登录" : model.connection.label)
                    }
                }
                LabeledContent("账号") {
                    Text(model.connection.isConnected ? model.connection.label : "—")
                        .foregroundStyle(model.connection.isConnected ? .primary : .secondary)
                }
                LabeledContent("服务") {
                    switch model.sidecarState {
                    case .ready(let port):
                        Text("运行中 · 端口 \(port)")
                            .foregroundStyle(.secondary)
                    case .starting, .idle:
                        Text("启动中…").foregroundStyle(.secondary)
                    case .failed(let reason):
                        Text(reason).foregroundStyle(.red).lineLimit(2)
                    }
                }
                if model.connection.isConnected, !model.playlists.isEmpty {
                    LabeledContent("歌单") {
                        Text("\(model.playlists.count) 个 · \(model.albums.count) 张收藏专辑")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .formStyle(.grouped)

            Spacer(minLength: 0)

            HStack {
                if model.connection.isConnected {
                    Button("退出登录") {
                        Task { await model.signOutQQMusic() }
                    }
                } else {
                    Button("扫码登录…") {
                        model.showLoginSheet = true
                    }
                }
                Spacer()
                Text("登录态只保存在这台 Mac 上")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.tertiary)
            }
            .padding(16)
        }
    }
}

// MARK: - Last.fm

private struct LastFMSettings: View {
    @ObservedObject var model: AppModel
    @State private var isAuthorizing = false

    private var scrobbler: Scrobbler { model.scrobbler }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Form {
                LabeledContent("状态") {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(scrobbler.connection.isConnected ? Color.green : Color.secondary.opacity(0.4))
                            .frame(width: 7, height: 7)
                        Text(statusText)
                    }
                }
                LabeledContent("账号") {
                    Text(scrobbler.connection.isConnected ? scrobbler.connection.label : "—")
                        .foregroundStyle(scrobbler.connection.isConnected ? .primary : .secondary)
                }
                LabeledContent("待提交") {
                    Text(scrobbler.pendingCount == 0 ? "无" : "\(scrobbler.pendingCount) 条")
                        .foregroundStyle(.secondary)
                }
                LabeledContent("凭据文件") {
                    Text(model.lastFMCredentialsPath)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .formStyle(.grouped)

            Spacer(minLength: 0)

            HStack {
                if scrobbler.connection.isConnected {
                    Button("退出登录") { scrobbler.signOut() }
                } else {
                    Button(isAuthorizing ? "等待浏览器确认…" : "在浏览器授权…") {
                        isAuthorizing = true
                        Task {
                            await scrobbler.authorize()
                            isAuthorizing = false
                        }
                    }
                    .disabled(isAuthorizing || scrobbler.connection == .noCredentials)
                }
                Spacer()
                if scrobbler.connection == .noCredentials {
                    Text("缺少 lastfm.json，先运行 Scripts/seed-lastfm.sh")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.orange)
                } else {
                    Text("曲目 > 30 秒且播满一半或 4 分钟才记录")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(16)
        }
    }

    private var statusText: String {
        switch scrobbler.connection {
        case .connected: return "已连接"
        case .authorizing: return "授权中…"
        case .disconnected: return "未连接"
        case .noCredentials: return "未配置"
        case .failed(let message): return message
        }
    }
}


// MARK: - MCP

private struct MCPSettings: View {
    @ObservedObject var model: AppModel
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Form {
                LabeledContent("状态") {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(model.mcp.isRunning ? Color.green : Color.secondary.opacity(0.4))
                            .frame(width: 7, height: 7)
                        Text(model.mcp.isRunning ? "运行中" : "未启动")
                    }
                }
                LabeledContent("地址") {
                    Text("http://127.0.0.1:\(AppModel.mcpPort)/")
                        .font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled)
                }
                LabeledContent("Token") {
                    HStack(spacing: 6) {
                        Text(model.mcpToken)
                            .font(.system(size: 10, design: .monospaced))
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                        Button(copied ? "已复制" : "复制") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(model.mcpToken, forType: .string)
                            copied = true
                        }
                        .controlSize(.small)
                    }
                }
                LabeledContent("能力") {
                    Text("搜索 · 播放控制 · 歌单/专辑/红心歌单读取 · 音质 · 歌词")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)

            Spacer(minLength: 0)

            Text("只监听本机回环地址，需要 Bearer token。不提供任何写操作——模型不能改你的歌单、红心或 Last.fm。")
                .font(.system(size: 10.5))
                .foregroundStyle(.tertiary)
                .padding(16)
        }
    }
}
