import AppKit
import CoreServices
import SwiftUI

@main
struct ZhijingApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var store = AppStore()

    var body: some Scene {
        WindowGroup("知境", id: "main") {
            ContentView(store: store)
                .frame(minWidth: 940, minHeight: 620)
                .preferredColorScheme(store.colorScheme.colorScheme)
                .background(MainWindowBridge())
                .onAppear {
                    appDelegate.connect(store: store)
                }
                .alert(
                    "出现问题",
                    isPresented: Binding(
                        get: { store.errorMessage != nil },
                        set: { if !$0 { store.errorMessage = nil } }
                    )
                ) {
                    Button("好") { store.errorMessage = nil }
                } message: {
                    Text(store.errorMessage ?? "")
                }
        }
        .defaultSize(width: 1440, height: 900)
        .commands {
            CommandGroup(replacing: .appSettings) {
                SettingsLink {
                    Label("API 与模型设置…", systemImage: "gearshape")
                }
                .keyboardShortcut(",")
            }
            CommandGroup(replacing: .newItem) {
                Button("新建文稿") { store.createNote() }
                    .keyboardShortcut("n")
                Button("新建文件夹") { store.createFolder() }
                    .keyboardShortcut("n", modifiers: [.command, .shift])
            }
            CommandGroup(after: .sidebar) {
                Button(store.isAssistantVisible ? "隐藏 AI 助手" : "显示 AI 助手") {
                    store.toggleAssistant()
                }
                .keyboardShortcut("a", modifiers: [.command, .option])
            }
            CommandMenu("文稿") {
                Button("立即保存") { store.saveNow() }
                    .keyboardShortcut("s")
                Button("创建版本快照") { store.createManualSnapshot() }
                    .keyboardShortcut("s", modifiers: [.command, .shift])
                Divider()
                Button("刷新知识库") {
                    Task { await store.refreshLibrary() }
                }
                .keyboardShortcut("r", modifiers: [.command, .shift])
            }
        }

        Settings {
            SettingsView(store: store)
                .frame(width: 540)
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private weak var store: AppStore?
    private var pendingFiles: [URL] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        MarkdownFileAssociation.makeZhijingDefaultEditor()
    }

    func connect(store: AppStore) {
        self.store = store
        guard !pendingFiles.isEmpty else { return }
        let files = pendingFiles
        pendingFiles.removeAll()
        open(files)
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        guard store != nil else {
            pendingFiles.append(contentsOf: urls)
            return
        }
        open(urls)
    }

    func applicationShouldHandleReopen(
        _ sender: NSApplication,
        hasVisibleWindows flag: Bool
    ) -> Bool {
        if !flag, let mainWindow = sender.windows.first(where: { $0.identifier?.rawValue == "zhijing-main" }) {
            mainWindow.makeKeyAndOrderFront(nil)
        }
        sender.activate(ignoringOtherApps: true)
        return true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard store?.saveNow() != false else { return .terminateCancel }
        return .terminateNow
    }

    private func open(_ urls: [URL]) {
        guard let url = urls.first(where: {
            ["md", "markdown", "txt"].contains($0.pathExtension.lowercased())
        }) else { return }
        store?.openDocument(at: url)
    }
}

private struct MainWindowBridge: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { configure(view.window) }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { configure(nsView.window) }
    }

    private func configure(_ window: NSWindow?) {
        window?.identifier = NSUserInterfaceItemIdentifier("zhijing-main")
        window?.isReleasedWhenClosed = false
    }
}

private enum MarkdownFileAssociation {
    static func makeZhijingDefaultEditor() {
        guard let bundleID = Bundle.main.bundleIdentifier else { return }
        LSSetDefaultRoleHandlerForContentType(
            "net.daringfireball.markdown" as CFString,
            .all,
            bundleID as CFString
        )
    }
}
