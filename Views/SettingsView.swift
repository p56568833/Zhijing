import SwiftUI

struct SettingsView: View {
    @Bindable var store: AppStore
    @State private var apiKeyDraft = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("API 与模型设置", systemImage: "key.horizontal")
                .font(.title2.weight(.semibold))
            Text("也可以随时按 ⌘, 打开这里。")
                .font(.callout)
                .foregroundStyle(.secondary)

            Form {
                Section("模型连接") {
                    Picker(
                        "服务商",
                        selection: Binding(
                            get: { store.provider },
                            set: { store.selectProvider($0) }
                        )
                    ) {
                        ForEach(AIProviderPreset.allCases) { provider in
                            Text(provider.name).tag(provider)
                        }
                    }

                    if store.provider == .custom {
                        TextField("模型名称", text: $store.model)
                            .onChange(of: store.model) { _, _ in store.resetConnectionTest() }
                        TextField("基础地址", text: $store.endpoint)
                            .onChange(of: store.endpoint) { _, _ in store.resetConnectionTest() }
                    } else {
                        Picker(
                            "模型",
                            selection: Binding(
                                get: { store.model },
                                set: { store.selectModel($0) }
                            )
                        ) {
                            ForEach(store.provider.models) { model in
                                VStack(alignment: .leading) {
                                    Text(model.name)
                                    Text(model.detail)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                .tag(model.id)
                            }
                        }

                        LabeledContent("基础地址") {
                            Text(store.endpoint)
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                    }

                    Text("请求路径 /chat/completions 由知境自动补全，无需手动填写。")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    SecureField("API Key", text: $apiKeyDraft)
                        .onChange(of: apiKeyDraft) { _, _ in store.resetConnectionTest() }
                        .onSubmit {
                            Task { await store.testAIConnection(apiKey: apiKeyDraft) }
                        }

                    HStack {
                        if store.connectionTestSucceeded {
                            Label("连接成功，设置已保存", systemImage: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                        } else {
                            Text("密钥只保存在这台 Mac 的钥匙串中")
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button {
                            Task { await store.testAIConnection(apiKey: apiKeyDraft) }
                        } label: {
                            if store.isTestingConnection {
                                HStack(spacing: 6) {
                                    ProgressView().controlSize(.small)
                                    Text("正在测试…")
                                }
                            } else {
                                Text("测试连接")
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(
                            apiKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                            store.isTestingConnection
                        )
                    }
                    .font(.caption)
                }

                Section("知识库") {
                LabeledContent("当前文件夹") {
                    Text(store.libraryURL?.path ?? "尚未选择")
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                HStack {
                    Spacer()
                    Button("选择文件夹…") { store.chooseLibrary() }
                }
                TextField("排除的文件夹（用逗号分隔）", text: $store.excludedFoldersText)
                    .onSubmit {
                        Task { await store.refreshLibrary() }
                    }
                }

                Section("外观") {
                    Picker("颜色模式", selection: $store.colorScheme) {
                        ForEach(AppColorScheme.allCases, id: \.self) { scheme in
                            Text(scheme.name).tag(scheme)
                        }
                    }
                }

                Section("隐私") {
                    Text("原始文稿始终保存在本地。向模型提问时，只发送当前问题、必要的当前文稿内容，以及本次检索命中的少量片段。")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
        }
        .padding()
        .onAppear {
            apiKeyDraft = store.apiKey
        }
        .alert(
            "连接失败",
            isPresented: Binding(
                get: { store.connectionTestError != nil },
                set: { if !$0 { store.connectionTestError = nil } }
            )
        ) {
            Button("好") { store.connectionTestError = nil }
        } message: {
            Text(store.connectionTestError ?? "")
        }
    }
}
