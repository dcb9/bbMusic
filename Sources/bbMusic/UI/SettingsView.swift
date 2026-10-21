import SwiftUI

/// Standard settings window (⌘,). Two accounts, each with its current state and the one action that
/// matters: authorize or sign out.
struct SettingsView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        TabView {
            QQMusicSettings(model: model)
                .tabItem { Label("QQ 音乐", systemImage: "music.note") }
            LastFMSettings(model: model)
                .tabItem { Label("Last.fm", systemImage: "waveform.path.ecg") }
        }
        .frame(width: 460, height: 260)
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
