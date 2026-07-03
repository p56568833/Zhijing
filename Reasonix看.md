# Reasonix 看

## 开发工作流

1. 改代码
2. `swift build --disable-sandbox`
3. 打包到项目根目录：
   ```
   mkdir -p 知境.app/Contents/MacOS 知境.app/Contents/Resources
   cp .build/arm64-apple-macosx/debug/Zhijing 知境.app/Contents/MacOS/Zhijing
   cp Assets/AppIcon.icns 知境.app/Contents/Resources/
   ```
   （Info.plist 如不存在也需创建）
4. `open dist/知境.app` 快速预览效果

## 重要规则

- 不再区分正式版和测试版，仓库只构建一个 `知境.app`。
- 不要复制到 `~/Applications`；开发和使用都直接启动项目根目录的 `知境.app`。
- 每次构建会原地替换这一份应用，确保不会产生多个版本。
- 每次改完代码记得 `touch` 相关文件后再 build，避免增量编译缓存没更新。

## 项目信息

- 名称：知境
- 类型：macOS 原生 App（SwiftUI + AppKit）
- 最低系统：macOS 14
- 构建工具：Swift Package Manager
