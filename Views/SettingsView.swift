import SwiftUI

struct SettingsView: View {
    @Bindable var store: AppStore

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("偏好设置", systemImage: "slider.horizontal.3")
                .font(.title2.weight(.semibold))

            Form {
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

                Section("数据") {
                    Text("文稿、批注和历史版本均保存在你选择的文件夹中。")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
        }
        .padding()
    }
}
