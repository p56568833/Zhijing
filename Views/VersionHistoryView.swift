import SwiftUI

struct VersionHistoryView: View {
    let store: AppStore
    @State private var selectedRevisionID: Revision.ID?
    @State private var selectedRevisionText = ""
    @State private var loadedRevisionID: Revision.ID?
    @State private var isLoadingRevision = false
    @State private var snapshotName = ""
    @State private var mode = VersionDisplayMode.preview
    @State private var restoreTarget: Revision?
    @Environment(\.dismiss) private var dismiss

    private enum VersionDisplayMode: String, CaseIterable, Identifiable {
        case preview = "预览"
        case compare = "与当前比较"

        var id: Self { self }
    }

    private var selectedRevision: Revision? {
        guard let selectedRevisionID else { return store.revisions.first }
        return store.revisions.first { $0.id == selectedRevisionID }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("版本历史")
                        .font(.title2.weight(.semibold))
                    Text(store.selectedDocument?.title ?? "")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                TextField("快照名称，例如：完成初稿", text: $snapshotName)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 260)
                    .onSubmit(createNamedSnapshot)
                Button("保存快照", action: createNamedSnapshot)
                    .buttonStyle(.borderedProminent)
                    .disabled(
                        snapshotName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    )
            }
            .padding(18)
            Divider()

            HSplitView {
                Group {
                    if store.revisions.isEmpty {
                        ContentUnavailableView(
                            "还没有历史版本",
                            systemImage: "clock.arrow.circlepath",
                            description: Text("为重要节点命名并保存快照。")
                        )
                    } else {
                        List(store.revisions, selection: $selectedRevisionID) { revision in
                            VStack(alignment: .leading, spacing: 3) {
                                Text(revision.displayName)
                                    .fontWeight(.medium)
                                    .lineLimit(1)
                                Text(
                                    revision.createdAt.formatted(
                                        date: .abbreviated,
                                        time: .standard
                                    )
                                )
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            }
                            .tag(revision.id)
                        }
                        .listStyle(.sidebar)
                    }
                }
                .frame(minWidth: 230, idealWidth: 260, maxWidth: 320)

                VStack(spacing: 0) {
                    if let revision = selectedRevision {
                        HStack {
                            Picker("查看方式", selection: $mode) {
                                ForEach(VersionDisplayMode.allCases) { value in
                                    Text(value.rawValue).tag(value)
                                }
                            }
                            .pickerStyle(.segmented)
                            .labelsHidden()
                            .fixedSize()
                            Spacer()
                            Button("恢复这个版本") {
                                restoreTarget = revision
                            }
                        }
                        .padding(12)
                        Divider()

                        if isLoadingRevision || loadedRevisionID != revision.id {
                            ProgressView("正在载入版本…")
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                        } else {
                            switch mode {
                            case .preview:
                                MarkdownReadingView(text: selectedRevisionText)
                            case .compare:
                                TextComparisonView(
                                    originalTitle: revision.displayName,
                                    original: selectedRevisionText,
                                    replacementTitle: "当前文稿",
                                    replacement: store.editorText
                                )
                            }
                        }
                    } else {
                        ContentUnavailableView(
                            "选择一个版本",
                            systemImage: "doc.text.magnifyingglass"
                        )
                    }
                }
            }

            Divider()
            HStack {
                Text("恢复版本前，知境会先保存当前内容。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("完成") { dismiss() }
            }
            .padding(14)
        }
        .frame(minWidth: 960, minHeight: 640)
        .onAppear {
            selectedRevisionID = store.revisions.first?.id
        }
        .task(id: selectedRevisionID) {
            await loadSelectedRevisionText()
        }
        .confirmationDialog(
            "恢复“\(restoreTarget?.displayName ?? "")”？",
            isPresented: Binding(
                get: { restoreTarget != nil },
                set: { if !$0 { restoreTarget = nil } }
            )
        ) {
            Button("恢复版本") {
                if let restoreTarget {
                    store.restore(restoreTarget)
                }
                self.restoreTarget = nil
            }
            Button("取消", role: .cancel) { restoreTarget = nil }
        } message: {
            Text("当前文稿会先自动保存为一个快照。")
        }
    }

    private func createNamedSnapshot() {
        let name = snapshotName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        store.createManualSnapshot(name: name)
        snapshotName = ""
        selectedRevisionID = store.revisions.first?.id
    }

    @MainActor
    private func loadSelectedRevisionText() async {
        guard let revision = selectedRevision else {
            selectedRevisionText = ""
            loadedRevisionID = nil
            isLoadingRevision = false
            return
        }

        if loadedRevisionID == revision.id {
            return
        }

        isLoadingRevision = true
        let id = revision.id
        let url = revision.url
        let text = await Task.detached(priority: .userInitiated) {
            (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        }.value
        guard selectedRevision?.id == id else { return }
        selectedRevisionText = text
        loadedRevisionID = id
        isLoadingRevision = false
    }
}
