import SwiftUI

@main
struct BbMusicApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = AppModel()

    var body: some Scene {
        Window("bbMusic", id: "main") {
            Group {
                if SelfTest.isRequested {
                    SelfTestView(model: model)
                } else {
                    RootView(model: model, player: model.player)
                        .sheet(isPresented: $model.showLoginSheet) {
                            LoginSheet(model: model)
                        }
                        .sheet(isPresented: $model.showLastFMPanel) {
                            LastFMPanel(scrobbler: model.scrobbler)
                        }
                        .onAppear {
                            delegate.model = model
                            model.start()
                        }
                        .onDisappear {
                            model.shutdown()
                        }
                }
            }
        }
        .defaultSize(width: 1000, height: 640)

        Settings {
            SettingsView(model: model)
        }
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandMenu("播放") {
                Button("播放 / 暂停") { model.player.togglePlayPause() }
                    .keyboardShortcut(.space, modifiers: [])
                Button("上一首") { model.player.previous() }
                    .keyboardShortcut(.leftArrow, modifiers: [.command])
                Button("下一首") { model.player.next() }
                    .keyboardShortcut(.rightArrow, modifiers: [.command])
                Divider()
                Button("显示歌词") {
                    model.pane = .lyrics
                }
                .keyboardShortcut("l", modifiers: [.command])
                Button("返回列表") {
                    model.pane = .list
                }
                .keyboardShortcut("[", modifiers: [.command])
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var model: AppModel?

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Stop the sidecar with the app; leaving it behind would hold the port and the session file.
        MainActor.assumeIsolated {
            model?.shutdown()
        }
    }
}
