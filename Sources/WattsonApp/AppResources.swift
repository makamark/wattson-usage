// AppResources.swift — 定位打包进来的资源束（品牌图标 / logos / mirror.sh）。
//
// 不用 SwiftPM 生成的 Bundle.module：它只试两个路径 —— Bundle.main.bundleURL 下的
// Wattson_WattsonApp.bundle，以及构建机上写死的绝对路径 —— 都不命中就 fatalError。
// 手工组装的 .app 把资源束放在 Contents/Resources，两个路径都不命中，于是在渲染
// 品牌图标时直接崩溃（点状态栏图标即触发）。这里按标准布局探测，找不到返回 nil，
// 由各调用方兜底（⚡ 字形 / 首字母圆底 / 跳过同步），绝不再中止进程。
import Foundation

enum AppResources {
    /// 资源束在 .app 内的标准位置（scripts/package-app.sh 复制到此处）
    private static let bundleName = "Wattson_WattsonApp.bundle"

    static let bundle: Bundle? = locate()

    private static func locate() -> Bundle? {
        // 打包分发：Contents/Resources；swift run / swift build：与可执行文件同级
        let roots = [Bundle.main.resourceURL, Bundle.main.bundleURL].compactMap { $0 }
        for root in roots {
            if let found = Bundle(url: root.appendingPathComponent(bundleName)) {
                return found
            }
        }
        return nil
    }

    static func url(forResource name: String, withExtension ext: String,
                    subdirectory: String? = nil) -> URL? {
        bundle?.url(forResource: name, withExtension: ext, subdirectory: subdirectory)
    }

    static func path(forResource name: String, ofType ext: String,
                     inDirectory dir: String? = nil) -> String? {
        bundle?.path(forResource: name, ofType: ext, inDirectory: dir)
    }
}
