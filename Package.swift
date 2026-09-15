// swift-tools-version:5.10
// Wattson — 多机 AI 编码用量看板（Swift 原生实现）。
// WattsonCore：纯逻辑层（解析/聚合/额度轮询/API 路由），零第三方依赖；
//              HTTP 走 Network.framework，加密走 CryptoKit，全部系统框架。
// WattsonApp：菜单栏 + 看板窗口（SwiftUI 原生 App，替代 Electron 客户端与 Web 前端）。
import PackageDescription

let package = Package(
    name: "Wattson",
    platforms: [.macOS(.v13)],
    targets: [
        .target(name: "WattsonCore", path: "Sources/WattsonCore"),
        .executableTarget(
            name: "WattsonApp",
            dependencies: ["WattsonCore"],
            path: "Sources/WattsonApp",
            resources: [.copy("Resources")]
        ),
        // 无头 API 服务器（launchd 常驻 / 远端中心机部署）
        .executableTarget(
            name: "wattson-server",
            dependencies: ["WattsonCore"],
            path: "Sources/wattson-server"
        ),
        .testTarget(
            name: "WattsonCoreTests",
            dependencies: ["WattsonCore"],
            path: "Tests/WattsonCoreTests"
        ),
    ]
)
