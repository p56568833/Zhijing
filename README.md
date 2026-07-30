# 知境

一款原生 macOS 私人 AI 知识库笔记应用。真实的 Markdown 文件夹是唯一数据源。

![知境应用图标](Assets/AppIcon.png)

## 当前 MVP

- 打开本地知识库，浏览、创建、编辑、重命名和删除 `.md` / `.txt`
- 自动保存、收藏、最近文稿、全文搜索与来源定位
- 编辑 / Markdown 阅读模式
- 选中文字后快速添加批注，批注会随相关正文一起提供给 AI
- 每篇文稿独立的 AI 对话和状态恢复
- 本地关键词检索；没有 API Key 时仍可查看知识库命中片段
- OpenAI 兼容 Chat Completions 接口，Keychain 安全保存密钥
- AI 回答显示引用来源，可点击打开原文
- AI 修改先展示前后差异，接受前自动创建版本快照
- 手动快照与历史恢复

## 运行

在 Codex 中点击 `Run`，或运行：

```bash
./script/build_and_run.sh
```

构建后的唯一应用位于项目根目录的 `知境.app`。
