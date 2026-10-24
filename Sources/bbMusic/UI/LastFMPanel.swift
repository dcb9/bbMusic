import SwiftUI

/// Last.fm account panel. Authorization happens in the browser (Last.fm's desktop flow), so this
/// pane explains what will happen and then reports progress — it never pretends to have a form.
struct LastFMPanel: View {
    @ObservedObject var scrobbler: Scrobbler
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Last.fm")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Button("关闭") { dismiss() }
                    .controlSize(.small)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            Divider()

            VStack(spacing: 12) {
                switch scrobbler.connection {
                case .connected(let username):
                    Image(systemName: "checkmark.circle")
                        .font(.system(size: 22))
                        .foregroundStyle(.green)
                    Text("已连接：\(username)")
                        .font(.system(size: 12.5, weight: .semibold))
                    Text("听歌时会自动记录，无需其他操作。")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    if scrobbler.pendingCount > 0 {
                        Text("有 \(scrobbler.pendingCount) 条待提交")
                            .font(.system(size: 10.5))
                            .foregroundStyle(.tertiary)
                    }
                    Button("退出登录") { scrobbler.signOut() }
                        .controlSize(.small)

                case .authorizing:
                    ProgressView().controlSize(.small)
                    Text("等待你在浏览器里确认…")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                    Text("授权完成后这里会自动更新。")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.tertiary)

                case .failed(let message):
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 20))
                        .foregroundStyle(.orange)
                    Text(message)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 280)
                    Button("重试") {
                        Task { await scrobbler.authorize() }
                    }
                    .controlSize(.small)

                case .noCredentials:
                    Image(systemName: "key.slash")
                        .font(.system(size: 20))
                        .foregroundStyle(.tertiary)
                    Text("没有可用的 API 凭据")
                        .font(.system(size: 12.5, weight: .semibold))
                    Text("缺少 lastfm.json。运行 Scripts/seed-lastfm.sh 写入 API key 与 shared secret。")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 280)

                case .disconnected:
                    Image(systemName: "person.crop.circle.badge.questionmark")
                        .font(.system(size: 22))
                        .foregroundStyle(.tertiary)
                    Text("需要在浏览器里授权")
                        .font(.system(size: 12.5, weight: .semibold))
                    Text("点击下面的按钮会打开 Last.fm，确认后回来即可，授权状态会自动更新。")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 290)
                    Button("在浏览器授权") {
                        Task { await scrobbler.authorize() }
                    }
                    .controlSize(.small)
                    .padding(.top, 2)
                }
            }
            .padding(.vertical, 20)
            .frame(maxWidth: .infinity)
        }
        .frame(width: 340)
    }
}
