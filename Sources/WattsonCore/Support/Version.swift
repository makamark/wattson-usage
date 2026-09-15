// Support/Version.swift — 发布版本标识。
// 与打包脚本 scripts/package-app.sh 的 VERSION 保持一致；命名沿用原版体系
// （Wattson / com.wattson.app / Wattson-<ver>-arm64.dmg），Swift 原生线自 2.0.0 起，
// Electron 时代为 0.1.x。
import Foundation

public let WATTSON_VERSION = "2.0.24"
/// 产品线标识：native = Swift 原生版
public let WATTSON_CHANNEL = "native"
