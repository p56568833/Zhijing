// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Zhijing",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Zhijing", targets: ["Zhijing"])
    ],
    targets: [
        .executableTarget(
            name: "Zhijing",
            path: ".",
            exclude: [
                "Tests",
                "script",
                "知境.app",
                "Assets",
                "dist",
                "残梅记",
                "fm26-expert-skill",
                "tmp",
                "知识库笔记软件-MVP产品需求文档.md",
                "Reasonix看.md",
                "README.md"
            ],
            sources: ["App", "Models", "Services", "Stores", "Support", "Views"]
        ),
        .testTarget(
            name: "ZhijingTests",
            dependencies: ["Zhijing"],
            path: "Tests/ZhijingTests"
        )
    ]
)
