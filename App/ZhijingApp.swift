import AppKit
import SwiftUI

@main
struct ZhijingApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var store = AppStore()

    var body: some Scene {
        Window("知境", id: "main") {
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
            CommandGroup(replacing: .newItem) {
                Button("新建文稿") { store.createNote() }
                    .keyboardShortcut("n")
                Button("新建文件夹") { store.createFolder() }
                    .keyboardShortcut("n", modifiers: [.command, .shift])
            }
            CommandGroup(before: .newItem) {
                // 放在 File 菜单最前、系统「关闭窗口」之前：
                // 有文稿时 ⌘W 优先关标签页，没有文稿时按钮禁用，
                // 按键自然落到系统的关闭窗口。
                Button("关闭标签页") {
                    if let document = store.selectedDocument {
                        store.closeDocumentTab(document)
                    }
                }
                .keyboardShortcut("w")
                .disabled(store.selectedDocument == nil)
            }
            CommandGroup(after: .textEditing) {
                Button("查找…") {
                    store.showDocumentFind()
                }
                .keyboardShortcut("f")
                Button("查找下一个") {
                    store.findNext()
                }
                .keyboardShortcut("g")
                Button("查找上一个") {
                    store.findPrevious()
                }
                .keyboardShortcut("g", modifiers: [.command, .shift])
            }
            CommandMenu("文稿") {
                Button("添加批注…") {
                    store.requestAnnotationComposer()
                }
                .keyboardShortcut("m", modifiers: [.command, .shift])
                Button("立即保存") { store.saveNow() }
                    .keyboardShortcut("s")
                Button("创建版本快照") { store.createManualSnapshot() }
                    .keyboardShortcut("s", modifiers: [.command, .shift])
                Button(store.isComparisonVisible ? "关闭分屏对照" : "打开分屏对照") {
                    store.toggleComparison()
                }
                .keyboardShortcut("\\", modifiers: [.command, .control])
                Menu("导出") {
                    Button("导出 PDF…") {
                        store.exportCurrentDocument(as: .pdf)
                    }
                    Button("导出 Word…") {
                        store.exportCurrentDocument(as: .word)
                    }
                }
                Divider()
                Button("刷新知识库") {
                    Task { await store.refreshLibrary() }
                }
                .keyboardShortcut("r", modifiers: [.command, .shift])
            }
            CommandMenu("格式") {
                Button("加粗") {
                    store.applyInlineFormat(.bold)
                }
                .keyboardShortcut("b")
                Button("斜体") {
                    store.applyInlineFormat(.italic)
                }
                .keyboardShortcut("i")
                Button("删除线") {
                    store.applyInlineFormat(.strikethrough)
                }
                .keyboardShortcut("x", modifiers: [.command, .shift])
                Divider()
                Button("荧光标记") {
                    store.applyInlineFormat(.textMark(.highlight))
                }
                .keyboardShortcut("h", modifiers: [.command, .shift])
                Button("下划线标记") {
                    store.applyInlineFormat(.textMark(.underline))
                }
                .keyboardShortcut("u", modifiers: [.command, .shift])
                Divider()
                Menu("彩色文字") {
                    Button("红色文字") { store.applyInlineFormat(.textMark(.red)) }
                    Button("橙色文字") { store.applyInlineFormat(.textMark(.orange)) }
                    Button("绿色文字") { store.applyInlineFormat(.textMark(.green)) }
                    Button("蓝色文字") { store.applyInlineFormat(.textMark(.blue)) }
                }
                Button("清除标记") {
                    store.applyInlineFormat(.clearTextMark)
                }
            }
        }

        Settings {
            SettingsView(store: store)
                .frame(width: 500)
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
        guard store?.prepareForTermination() != false else { return .terminateCancel }
        return .terminateNow
    }

    private func open(_ urls: [URL]) {
        presentMainWindow()
        store?.openDocuments(at: urls)
    }

    private func presentMainWindow() {
        NSApp.activate(ignoringOtherApps: true)
        DispatchQueue.main.async {
            NSApp.windows.first(where: {
                $0.identifier?.rawValue == "zhijing-main"
            })?.makeKeyAndOrderFront(nil)
        }
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
