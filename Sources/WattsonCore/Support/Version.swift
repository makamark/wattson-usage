// Support/Version.swift — 发布版本标识。
// 与打包脚本 scripts/package-app.sh 的 VERSION 保持一致；原生版的命名体系
// （WattsonNative / com.wattson.native / 2.x）与 Electron 时代
// （Wattson / com.wattson.app / 0.1.0）明确区分。
import Foundation

public let WATTSON_VERSION = "2.0.2"
/// 产品线标识：native = Swift 原生版
public let WATTSON_CHANNEL = "native"
