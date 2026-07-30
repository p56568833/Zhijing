import SwiftUI

struct DocumentTabBar: View {
    let store: AppStore

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 3) {
                ForEach(store.openDocuments) { document in
                    HStack(spacing: 5) {
                        Button {
                            store.select(document)
                        } label: {
                            Text(document.title)
                                .lineLimit(1)
                                .frame(maxWidth: 180)
                        }
                        .buttonStyle(.plain)

                        Button {
                            store.closeDocumentTab(document)
                        } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(.secondary)
                                .frame(width: 16, height: 16)
                        }
                        .buttonStyle(.plain)
                        .help("关闭标签页")
                    }
                    .padding(.leading, 10)
                    .padding(.trailing, 5)
                    .frame(height: 28)
                    .background(
                        store.selectedDocument?.id == document.id
                            ? Color.accentColor.opacity(0.16)
                            : Color.clear,
                        in: RoundedRectangle(cornerRadius: 6)
                    )
                    .contentShape(RoundedRectangle(cornerRadius: 6))
                }
            }
            .padding(.horizontal, 8)
        }
        .frame(height: 40)
    }
}

struct DocumentFindBar: View {
    @Bindable var store: AppStore
    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField(
                "在当前文稿中查找",
                text: Binding(
                    get: { store.documentFindOptions.query },
                    set: { store.documentFindOptions.query = $0 }
                )
            )
            .textFieldStyle(.roundedBorder)
            .focused($isFocused)
            .frame(minWidth: 180, maxWidth: 360)
            .onSubmit { store.findNext() }

            Text(resultText)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 66, alignment: .leading)

            Button {
                store.findPrevious()
            } label: {
                Image(systemName: "chevron.up")
            }
            .buttonStyle(.plain)
            .help("上一个（⇧⌘G）")
            .disabled(store.documentFindResult.matchCount == 0)

            Button {
                store.findNext()
            } label: {
                Image(systemName: "chevron.down")
            }
            .buttonStyle(.plain)
            .help("下一个（⌘G）")
            .disabled(store.documentFindResult.matchCount == 0)

            Toggle(
                "Aa",
                isOn: Binding(
                    get: { store.documentFindOptions.matchCase },
                    set: { store.documentFindOptions.matchCase = $0 }
                )
            )
            .toggleStyle(.button)
            .help("区分大小写")

            Toggle(
                "整词",
                isOn: Binding(
                    get: { store.documentFindOptions.wholeWord },
                    set: { store.documentFindOptions.wholeWord = $0 }
                )
            )
            .toggleStyle(.button)
            .help("整词匹配")

            Spacer()

            Button {
                store.hideDocumentFind()
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.plain)
            .help("关闭查找")
        }
        .font(.callout)
        .padding(.horizontal, 12)
        .frame(height: 38)
        .background(.bar)
        .onAppear { isFocused = true }
    }

    private var resultText: String {
        store.documentFindOptions.trimmedQuery.isEmpty
            ? ""
            : store.documentFindResult.displayText
    }
}

struct ReferenceDocumentView: View {
    let store: AppStore

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label("对照文稿", systemImage: "doc.on.doc")
                    .font(.headline)
                Spacer()
                Picker(
                    "对照文稿",
                    selection: Binding(
                        get: { store.comparisonDocumentPath },
                        set: { store.setComparisonDocument($0) }
                    )
                ) {
                    ForEach(store.comparisonCandidates) { document in
                        Text(document.title)
                            .tag(Optional(document.relativePath))
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(maxWidth: 240)
                Button {
                    store.toggleComparison()
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.plain)
                .help("关闭分屏对照")
            }
            .padding(.horizontal, 14)
            .frame(height: 50)
            Divider()

            if store.comparisonDocument != nil {
                MarkdownReadingView(text: store.comparisonText)
            } else {
                ContentUnavailableView(
                    "选择一篇对照文稿",
                    systemImage: "rectangle.split.2x1"
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct DocumentMetricsBar: View {
    let store: AppStore

    var body: some View {
        HStack(spacing: 14) {
            if store.selectedDocument != nil {
                if store.saveState == .saving {
                    ProgressView().controlSize(.mini)
                }
                Text(store.saveState.label)
                if let location = store.selectedDocumentLocationLabel {
                    Text("·")
                    Text(location)
                        .lineLimit(1)
                }
            }
            Spacer()
            Label("\(store.documentWordCount.formatted()) 字", systemImage: "textformat")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 14)
        .frame(height: 30)
        .background(.bar)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "\(store.saveState.label)，\(store.documentWordCount.formatted()) 字"
        )
    }
}
