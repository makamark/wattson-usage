// SettingsView.swift — 独立设置窗口（macOS 系统设置同款：侧栏分页 + 右侧内容）。
// 从主看板剥离：看板只做数据展示，配置/诊断/口径说明集中在设置窗口。
import SwiftUI
import WattsonCore

/// 设置分页标识（外部入口可指定打开后定位到哪页）
enum SettingsPage: String, Hashable {
    case general, devices, diagnostics, semantics, about
}

struct SettingsView: View {
    @ObservedObject var state: AppState
    var initialPage: SettingsPage = .general

    var body: some View {
        // 自定义侧栏：List(selection:) 在 macOS 会覆盖初始选中页（SwiftUI 已知行为）
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(SettingsPage.allCases) { page in
                    Button {
                        selected = page
                    } label: {
                        Label(page.title, systemImage: page.icon)
                            .font(.system(size: 13))
                            .foregroundStyle(selected == page ? Theme.text : Theme.muted)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 6)
                            .padding(.horizontal, 10)
                            .background(RoundedRectangle(cornerRadius: 7)
                                .fill(selected == page ? Theme.accentSoft : Color.clear))
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
            }
            .padding(10)
            .frame(width: 168, alignment: .topLeading)
            .background(Theme.bgSoft)
            .overlay(Divider().overlay(Theme.border), alignment: .trailing)

            Group {
                switch selected {
                case .general: GeneralPage(state: state)
                case .devices: DevicesPage(state: state)
                case .diagnostics: DiagnosticsPage(state: state)
                case .semantics: SemanticsPage()
                case .about: AboutPage(state: state)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .padding(24)
        }
        .frame(width: 620, height: 420)
        .preferredColorScheme(nil)
    }

    @State private var selected: SettingsPage

    init(state: AppState, initialPage: SettingsPage = .general) {
        self.state = state
        self.initialPage = initialPage
        _selected = State(initialValue: initialPage)
    }
}

extension SettingsPage: CaseIterable, Identifiable {
    public var id: String { rawValue }

    var title: String {
        switch self {
        case .general: return "通用"
        case .devices: return "设备"
        case .diagnostics: return "服务状态"
        case .semantics: return "数据口径"
        case .about: return "关于"
        }
    }

    var icon: String {
        switch self {
        case .general: return "gearshape"
        case .devices: return "desktopcomputer.and.arrow.down"
        case .diagnostics: return "stethoscope"
        case .semantics: return "ruler"
        case .about: return "info.circle"
        }
    }
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

// MARK: - 设备（多机管理：本机 + 远端 SSH 镜像）

private struct DevicesPage: View {
    @ObservedObject var state: AppState
    @State private var sshText = ""
    @State private var nameText = ""
    @State private var devices: [AppState.RemoteDevice] = []
    @State private var saved = false

    var body: some View {
        Form {
            Section {
                LabeledContent("本机") {
                    Label(state.collector.localHost, systemImage: "desktopcomputer")
                }
                .help("本机数据源自动发现，零配置")
            } header: {
                Text("本机（自动发现）")
            } footer: {
                Text("本机会自动扫描 claude / codex / zcode / workbuddy 的本机数据目录，无需配置。")
            }

            Section {
                if devices.isEmpty {
                    Text("暂无远端设备").foregroundStyle(.secondary)
                }
                ForEach(devices) { d in
                    HStack {
                        Image(systemName: "server.rack")
                            .foregroundStyle(Theme.accent)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(d.name).font(.system(size: 12.5, weight: .medium))
                            Text(d.ssh).font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button(role: .destructive) {
                            devices.removeAll { $0.id == d.id }
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                    }
                }
            } header: {
                Text("远端设备（SSH 镜像）")
            } footer: {
                Text("远端机器只需系统自带 ssh + rsync + sqlite3，免密可达即可；数据快照镜像到本机，远端零常驻。")
            }

            Section {
                LabeledContent("SSH 目标") {
                    TextField("别名（如 workstation）或 user@host", text: $sshText)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(probe)
                }
                LabeledContent("设备名") {
                    TextField("看板展示名（默认取 SSH 目标）", text: $nameText)
                        .textFieldStyle(.roundedBorder)
                }
                LabeledContent("") {
                    HStack(spacing: 10) {
                        Button("探测") { probe() }
                            .disabled(sshText.trimmingCharacters(in: .whitespaces).isEmpty || state.sshProbe.running)
                        if state.sshProbe.running {
                            ProgressView().controlSize(.small)
                            Text("探测中…").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                if state.sshProbe.done {
                    probeResult
                }
                LabeledContent("") {
                    HStack(spacing: 10) {
                        Button("添加设备") { add() }
                            .buttonStyle(.borderedProminent)
                            .tint(Theme.accent)
                            .disabled(!state.sshProbe.ok || devices.contains { $0.ssh == sshText.trimmingCharacters(in: .whitespaces) })
                        Spacer()
                        Button("保存并生成映射") { save() }
                            .disabled(devices == state.remoteDevices && !devicesAdded)
                        if saved {
                            Text("已保存").font(.caption).foregroundStyle(Theme.ok)
                        }
                    }
                }
            } header: {
                Text("添加远端设备")
            } footer: {
                Text("先探测验证 SSH 可达性与远端数据源，再添加。保存后可在状态栏右键「立即同步远端」执行首轮镜像。")
            }
        }
        .formStyle(.grouped)
        .onAppear {
            state.loadDevices()
            if devices.isEmpty { devices = state.remoteDevices }
        }
    }

    @State private var devicesAdded = false

    @ViewBuilder private var probeResult: some View {
        if state.sshProbe.ok {
            LabeledContent("探测结果") {
                VStack(alignment: .leading, spacing: 2) {
                    if !state.sshProbe.tools.isEmpty {
                        Label("数据源：\(state.sshProbe.tools.joined(separator: "、"))", systemImage: "checkmark.circle")
                            .foregroundStyle(Theme.ok)
                    } else {
                        Text("可达，但未发现数据源").foregroundStyle(.secondary)
                    }
                    ForEach(state.sshProbe.missing, id: \.self) { m in
                        Label("远端缺少 \(m)", systemImage: "exclamationmark.triangle")
                            .foregroundStyle(Theme.warn)
                    }
                }
            }
        } else if let err = state.sshProbe.error {
            LabeledContent("探测结果") {
                Label(err, systemImage: "xmark.circle").foregroundStyle(Theme.err)
            }
        }
    }

    private func probe() {
        let dest = sshText.trimmingCharacters(in: .whitespaces)
        guard !dest.isEmpty else { return }
        state.probeSsh(dest: dest)
    }

    private func add() {
        let dest = sshText.trimmingCharacters(in: .whitespaces)
        let name = nameText.trimmingCharacters(in: .whitespaces)
        devices.append(AppState.RemoteDevice(name: name.isEmpty ? dest : name, ssh: dest))
        devicesAdded = true
        sshText = ""
        nameText = ""
        state.sshProbe = AppState.SshProbe()
    }

    private func save() {
        state.saveDevices(devices)
        devicesAdded = false
        withAnimation { saved = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { saved = false }
        // 原向导链路：保存 → 派生映射 → 首轮同步（有远端设备时）
        if !devices.isEmpty { state.runMirrorNow() }
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
                if let err = state.serverError {
                    row("监听端口", "启动失败：\(err)")
                } else {
                    row("监听端口", "127.0.0.1:\(state.port)")
                }
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
                        Text("Wattson").font(.system(size: 16, weight: .semibold))
                        Text("多机 AI 编码用量侦探 · Swift 原生版")
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                        Text("v\(WATTSON_VERSION)")
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
