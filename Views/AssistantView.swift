import SwiftUI

struct AssistantView: View {
    @Bindable var store: AppStore
    @State private var prompt = ""

    var body: some View {
        VStack(spacing: 0) {
            header
            if store.latestUsage != nil || store.provider == .deepSeek {
                usageBar
                Divider()
            }
            Divider()
            messages
            Divider()
            composer
        }
        .background(.regularMaterial)
        .task {
            await store.refreshAccountBalance()
        }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Label("AI 助手", systemImage: "sparkles")
                    .font(.headline)
                Text(store.selectedDocument?.title ?? "随当前文稿切换")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Picker("检索范围", selection: $store.retrievalScope) {
                ForEach(RetrievalScope.allCases) { scope in
                    Text(scope.rawValue).tag(scope)
                }
            }
            .pickerStyle(.menu)
            .fixedSize()
            Button {
                store.clearCurrentChat()
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.plain)
            .help("清空当前对话")
        }
        .padding(.horizontal, 14)
        .frame(height: 58)
    }

    private var usageBar: some View {
        HStack(spacing: 10) {
            if let usage = store.latestUsage {
                Label("\(usage.promptTokens.formatted()) 上下文", systemImage: "text.line.first.and.arrowtriangle.forward")
                    .help("最近一次请求发送给模型的上下文 token 数")
            }
            if let cost = store.currentConversationCost {
                Label("\(cost.formatted) 本对话", systemImage: "banknote")
                    .help("当前文稿这轮对话的预估累计费用")
            }
            if store.provider == .deepSeek {
                Spacer(minLength: 0)
                if store.isRefreshingBalance {
                    ProgressView()
                        .controlSize(.mini)
                } else if let balance = store.accountBalances.first {
                    Button {
                        Task { await store.refreshAccountBalance(force: true) }
                    } label: {
                        Label("余额 \(balance.formattedTotal)", systemImage: "creditcard")
                    }
                    .buttonStyle(.plain)
                    .help("点击刷新 DeepSeek 账户余额")
                } else {
                    Button {
                        Task { await store.refreshAccountBalance(force: true) }
                    } label: {
                        Label("查询余额", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.plain)
                    .help(store.balanceError ?? "查询 DeepSeek 账户余额")
                }
            }
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .padding(.horizontal, 14)
        .frame(height: 30)
        .background(.thinMaterial)
    }

    private var messages: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    if store.currentMessages.isEmpty {
                        emptyState
                    }
                    ForEach(store.currentMessages) { message in
                        MessageView(message: message) { source in
                            store.openSource(source)
                        }
                        .id(message.id)
                    }
                    if store.isGenerating {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text(store.retrievalStatus.isEmpty ? "正在思考…" : store.retrievalStatus)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 14)
                        .id("generating")
                    }
                }
                .padding(.vertical, 16)
            }
            .onChange(of: store.currentMessages.count) { _, _ in
                if let last = store.currentMessages.last {
                    withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("围绕这篇文稿提问")
                .font(.headline)
            Text("我会先搜索知识库，只把相关片段交给模型，并在回答下方列出来源。")
                .font(.callout)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 7) {
                QuickPrompt(title: "总结当前文稿", icon: "text.alignleft") {
                    store.sendMessage("请总结当前文稿的核心观点。")
                }
                QuickPrompt(title: "寻找相关笔记", icon: "link") {
                    store.sendMessage("知识库里有哪些与当前文稿相关的笔记？请说明关联。")
                }
                QuickPrompt(title: "发现观点冲突", icon: "arrow.triangle.branch") {
                    store.sendMessage("请搜索知识库，找出与当前文稿可能冲突的观点，并分别标明来源。")
                }
            }
        }
        .padding(.horizontal, 14)
    }

    private var composer: some View {
        VStack(spacing: 9) {
            if !store.retrievalStatus.isEmpty && !store.isGenerating {
                Text(store.retrievalStatus)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            TextField("询问当前文稿或整个知识库…", text: $prompt, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(2...6)
                .onSubmit {
                    if !NSEvent.modifierFlags.contains(.shift) { send() }
                }
            HStack {
                Menu {
                    Button("润色全文") { propose("润色全文，保持原意与 Markdown 结构，让表达更清晰自然。") }
                    Button("压缩冗余") { propose("删去重复和冗余表达，使全文更紧凑，但保留重要信息。") }
                    Button("重组结构") { propose("重组文章结构与标题层级，使论述更有逻辑；不要添加无依据的事实。") }
                    if !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Divider()
                        Button("按输入要求修改") { propose(prompt) }
                    }
                } label: {
                    Label("修改", systemImage: "wand.and.stars")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .disabled(store.selectedDocument == nil || store.isGenerating)
                Spacer()
                Button {
                    send()
                } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.title2)
                }
                .buttonStyle(.plain)
                .disabled(
                    prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                    store.selectedDocument == nil ||
                    store.isGenerating
                )
            }
        }
        .padding(12)
        .background(.thinMaterial)
    }

    private func send() {
        let text = prompt
        prompt = ""
        store.sendMessage(text)
    }

    private func propose(_ instruction: String) {
        store.proposeEdit(instruction: instruction)
    }
}

private struct QuickPrompt: View {
    let title: String
    let icon: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.vertical, 3)
    }
}

private struct MessageView: View {
    let message: ChatMessage
    let openSource: (RetrievedChunk) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Text(message.role == .user ? "你" : "知境")
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(message.createdAt, style: .time)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            Text(markdown)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            if message.isGeneralKnowledge {
                Label("这部分使用了模型通用知识，并非来自你的资料", systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            if !message.sources.isEmpty {
                DisclosureGroup("引用来源 · \(Set(message.sources.map(\.filePath)).count) 篇") {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(message.sources) { source in
                            Button {
                                openSource(source)
                            } label: {
                                HStack(alignment: .top, spacing: 8) {
                                    Image(systemName: "doc.text")
                                        .foregroundStyle(.secondary)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(source.fileName)
                                            .fontWeight(.medium)
                                        Text(source.heading ?? "第 \(source.line) 行")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                        Text(source.text)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(2)
                                    }
                                    Spacer()
                                    Image(systemName: "arrow.right")
                                        .font(.caption)
                                        .foregroundStyle(.tertiary)
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.top, 7)
                }
                .font(.caption)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, message.role == .user ? 11 : 0)
        .background {
            if message.role == .user {
                RoundedRectangle(cornerRadius: 10)
                    .fill(.quaternary.opacity(0.6))
                    .padding(.horizontal, 8)
            }
        }
    }

    private var markdown: AttributedString {
        (try? AttributedString(markdown: message.text)) ?? AttributedString(message.text)
    }
}
