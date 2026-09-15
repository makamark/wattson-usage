// SettingsView.swift — 独立设置窗口（macOS 系统设置同款：侧栏分页 + 右侧内容）。
// 从主看板剥离：看板只做数据展示，配置/诊断/口径说明集中在设置窗口。
import SwiftUI
import WattsonCore

struct SettingsView: View {
    @ObservedObject var state: AppState

    var body: some View {
        NavigationSplitView {
            List(selection: $selected) {
                Label("通用", systemImage: "gearshape").tag(Page.general)
                Label("服务状态", systemImage: "stethoscope").tag(Page.diagnostics)
                Label("数据口径", systemImage: "ruler").tag(Page.semantics)
                Label("关于", systemImage: "info.circle").tag(Page.about)
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(168)
        } detail: {
            Group {
                switch selected {
                case .general: GeneralPage(state: state)
                case .diagnostics: DiagnosticsPage(state: state)
                case .semantics: SemanticsPage()
                case .about: AboutPage(state: state)
                case nil: GeneralPage(state: state)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .padding(24)
        }
        .frame(width: 620, height: 420)
        .preferredColorScheme(nil)
    }

    private enum Page: Hashable {
        case general, diagnostics, semantics, about
    }

    @State private var selected: Page? = .general
}

// MARK: - 通用（可修改的设置）

private struct GeneralPage: View {
    @ObservedObject var state: AppState
    @State private var portText = ""
    @State private var refreshText = ""
    @State private var saved = false
    @State private var loginItem = false

    var body: some View {
        Form {
            Section("聚合服务") {
                LabeledContent("监听端口") {
                    TextField("8317", text: $portText)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 110)
                        .monospacedDigit()
                        .onAppear { if portText.isEmpty { portText = String(state.port) } }
                }
                LabeledContent("刷新间隔") {
                    HStack(spacing: 4) {
                        TextField("30", text: $refreshText)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 64)
                            .monospacedDigit()
                            .onAppear { if refreshText.isEmpty { refreshText = String(Int(state.refreshMinutes)) } }
                        Text("分钟").foregroundStyle(.secondary)
                    }
                }
                LabeledContent("") {
                    HStack(spacing: 10) {
                        Button("保存并应用") { save() }
                            .buttonStyle(.borderedProminent)
                            .tint(Theme.accent)
                        if saved {
                            Text("已应用").font(.caption).foregroundStyle(Theme.ok)
                        }
                    }
                }
            }
            Section("启动与同步") {
                Toggle("登录时启动", isOn: Binding(
                    get: { state.loginItemEnabled },
                    set: { on in
                        loginItem = on
                        if on != state.loginItemEnabled { state.toggleLoginItem() }
                    }))
                LabeledContent("远端镜像") {
                    Button(state.isMirrorRunning ? "同步中…" : "立即同步") { state.runMirrorNow() }
                        .disabled(state.isMirrorRunning)
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { loginItem = state.loginItemEnabled }
    }

    private func save() {
        guard let port = Int(portText), (1...65535).contains(port),
              let refresh = Double(refreshText), refresh >= 1, refresh <= 24 * 60 else { return }
        state.applySettings(port: port, refreshMinutes: refresh)
        withAnimation { saved = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { saved = false }
    }
}

// MARK: - 服务状态（只读诊断）

private struct DiagnosticsPage: View {
    @ObservedObject var state: AppState

    var body: some View {
        Form {
            Section("采集") {
                row("本机设备", state.collector.localHost)
                row("数据记录", "\(Fmt.int(Double(state.snapshot.rows.count))) 条")
                row("数据时间", Fmt.time(state.snapshot.lastSuccessAt ?? state.snapshot.fetchedAt))
                row("采集状态", state.snapshot.refreshing
                    ? "解析中…"
                    : (state.snapshot.errors.isEmpty ? "正常" : "异常 ×\(state.snapshot.errors.count)"))
            }
            Section("网络") {
                row("监听端口", String(state.port))
                row("额度出网代理", state.proxyNote ?? "直连")
            }
            if !state.snapshot.errors.isEmpty {
                Section("最近错误") {
                    Text(state.snapshot.errors.joined(separator: "\n"))
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Theme.err)
                        .textSelection(.enabled)
                }
            }
        }
        .formStyle(.grouped)
    }

    private func row(_ k: String, _ v: String) -> some View {
        LabeledContent(k) { Text(v).textSelection(.enabled) }
    }
}

// MARK: - 数据口径

private struct SemanticsPage: View {
    var body: some View {
        Form {
            Section {
                Text("· Token 总量口径与成本计费一致：reasoning-in-output 提供商（claude / codex / copilot）的推理 token 不重复计入")
                Text("· 成本按内嵌价目快照估算，未映射模型按 $0 计；可用 ~/.config/wattson/model-aliases.json 把内部模型名映射到有价目的模型")
                Text("· workbuddy 为会话级估算，粒度粗于 zcode / codex")
                Text("· 看板各区块共享同一份筛选（时间范围 + 设备/工具钻取），先过滤再聚合，口径一致")
                Text("· 订阅额度为各官方接口只读拉取，凭据只在内存解密、不出本机")
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - 关于

private struct AboutPage: View {
    @ObservedObject var state: AppState

    var body: some View {
        Form {
            Section {
                HStack(spacing: 14) {
                    BrandMark(size: 56)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Wattson Native").font(.system(size: 16, weight: .semibold))
                        Text("多机 AI 编码用量侦探 · Swift 原生版")
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                        Text("v\(WATTSON_VERSION)（\(WATTSON_CHANNEL)）")
                            .font(.system(size: 11)).foregroundStyle(.tertiary)
                    }
                }
                .padding(.vertical, 4)
            }
            Section("配置") {
                LabeledContent("配置文件") {
                    HStack(spacing: 6) {
                        Text(state.configPath).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                        Button("打开") {
                            NSWorkspace.shared.open(URL(fileURLWithPath: state.configPath))
                        }
                        .buttonStyle(.link)
                    }
                }
                LabeledContent("设备根声明") {
                    Text("~/.config/wattson/devices.json")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
                LabeledContent("日志目录") {
                    HStack(spacing: 6) {
                        Text("~/wattson").font(.system(size: 11)).foregroundStyle(.secondary)
                        Button("打开") {
                            NSWorkspace.shared.open(URL(fileURLWithPath: NSHomeDirectory() + "/wattson"))
                        }
                        .buttonStyle(.link)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}
