import SwiftUI

/// QR sign-in. The three channels are flat options rather than a hidden dropdown, and the code is
/// shown in place — no modal window on top of a modal window.
struct LoginSheet: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss

    @State private var channel: QRChannel = .qqmusic
    @State private var challenge: QRChallenge?
    @State private var status: QRStatus = .waiting
    @State private var errorMessage: String?
    @State private var pollTask: Task<Void, Never>?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("登录 QQ 音乐")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Button("关闭") { dismiss() }
                    .controlSize(.small)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            Divider()

            VStack(spacing: 12) {
                if let errorMessage {
                    Text(errorMessage)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 300)
                    Button("重试") { start() }
                        .controlSize(.small)
                } else if let challenge {
                    qrImage(challenge)
                    Text(statusText)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                } else {
                    ProgressView().controlSize(.small)
                    Text("正在获取二维码…")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                }

                HStack(spacing: 5) {
                    ForEach(QRChannel.allCases, id: \.self) { item in
                        Button {
                            guard channel != item else { return }
                            channel = item
                            start()
                        } label: {
                            Text(item.label)
                                .font(.system(size: 10.5, weight: channel == item ? .semibold : .regular))
                                .padding(.horizontal, 9)
                                .padding(.vertical, 4)
                                .background(
                                    RoundedRectangle(cornerRadius: 5)
                                        .fill(channel == item ? Color.primary.opacity(0.1) : Color.clear)
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 5)
                                                .stroke(Color.primary.opacity(0.15), lineWidth: 1)
                                        )
                                )
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(channel == item ? .primary : .secondary)
                    }
                }

                Text("用对应 App 扫码确认。登录态只保存在这台 Mac 上。")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 280)
            }
            .padding(.vertical, 18)
            .frame(maxWidth: .infinity)
        }
        .frame(width: 340)
        .onAppear { start() }
        .onDisappear {
            pollTask?.cancel()
            if let challenge, let qrLogin = model.qrLogin {
                Task { await qrLogin.cancelQRLogin(challenge) }
            }
        }
    }

    private var statusText: String {
        switch status {
        case .waiting: return "等待扫码…"
        case .scanned: return "已扫码，请在手机上确认"
        case .authorized: return "登录成功"
        case .failed(let reason): return reason
        }
    }

    @ViewBuilder
    private func qrImage(_ challenge: QRChallenge) -> some View {
        if let image = NSImage(data: challenge.image) {
            Image(nsImage: image)
                .interpolation(.none)
                .resizable()
                .frame(width: 168, height: 168)
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 7).fill(.white))
        } else {
            Text("二维码解码失败")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(width: 168, height: 168)
        }
    }

    private func start() {
        pollTask?.cancel()
        challenge = nil
        errorMessage = nil
        status = .waiting

        pollTask = Task {
            do {
                guard let qrLogin = model.qrLogin else {
                    throw PlatformError("当前平台不支持扫码登录")
                }
                let fresh = try await qrLogin.beginQRLogin(channel: channel)
                guard !Task.isCancelled else { return }
                challenge = fresh

                // Poll until the code is confirmed, expires, or the sheet goes away.
                while !Task.isCancelled {
                    try await Task.sleep(nanoseconds: 2_000_000_000)
                    guard !Task.isCancelled else { return }
                    let state = try await qrLogin.pollQRLogin(fresh)
                    guard !Task.isCancelled else { return }
                    status = state
                    switch state {
                    case .authorized:
                        await model.refreshConnection()
                        try? await Task.sleep(nanoseconds: 400_000_000)
                        dismiss()
                        return
                    case .failed(let reason):
                        errorMessage = reason
                        return
                    case .waiting, .scanned:
                        continue
                    }
                }
            } catch {
                guard !Task.isCancelled else { return }
                errorMessage = error.localizedDescription
            }
        }
    }
}
