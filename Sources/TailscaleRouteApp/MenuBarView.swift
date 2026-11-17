import AppKit
import TailscaleRouteCore
import SwiftUI

struct MenuBarView: View {
    @ObservedObject var model: AppModel
    let presentation: Presentation

    @State private var showStopConfirmation = false
    @State private var showRestoreDefaultConfirmation = false
    @State private var domainInput = ""
    @State private var domainInputError: String?
    @State private var showDomainIPv6Routes = false
    @State private var dnsServerInput = ""
    @State private var testAddressInput = ""
    @State private var testPortInput = ""
    @State private var testURLInput = ""
    @State private var advancedSettingsError: String?
    @State private var showAdvancedSettings = false

    enum Presentation {
        case menuBar
        case dashboard

        var width: CGFloat {
            switch self {
            case .menuBar: return 430
            case .dashboard: return 680
            }
        }

        var height: CGFloat {
            switch self {
            case .menuBar: return 760
            case .dashboard: return 860
            }
        }
    }

    init(model: AppModel, presentation: Presentation = .menuBar) {
        self.model = model
        self.presentation = presentation
    }

    var body: some View {
        VStack(spacing: 0) {
            topBar
            Divider()

            if let report = model.report {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        statusHero(report)
                        overviewCards(report)
                        networkCard(report)
                        actionCard
                        killSwitchCard
                        settingsCard
                        localSubnetProtectionCard
                        temporaryDomainsCard
                        feedbackCard(report)
                    }
                    .padding(20)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .layoutPriority(1)
            } else {
                loadingView
            }

            Divider()
            bottomBar
        }
        .frame(width: presentation.width, height: presentation.height)
        .background(.regularMaterial)
        .confirmationDialog(
            "确定停止分流？",
            isPresented: $showStopConfirmation,
            titleVisibility: .visible
        ) {
            Button("停止并清理分流路由", role: .destructive) {
                model.pause()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("此操作仅移除由 App 管理的分流路由（中国 IPv4、域名主机路由等）；物理网关与 Tailscale 的基础路由保持不变。")
        }
        .confirmationDialog(
            "恢复系统默认？",
            isPresented: $showRestoreDefaultConfirmation,
            titleVisibility: .visible
        ) {
            Button("恢复系统默认", role: .destructive) {
                model.restoreDefault()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("这会移除 App 管理的分流路由、释放外接网段保护并恢复 Tailscale 原偏好；域名和中国 IP 来源配置会保留供下次启用。")
        }
        .alert(
            "退出清理未完成",
            isPresented: Binding(
                get: { model.quitFailureMessage != nil },
                set: { _ in }
            )
        ) {
            Button("重试") { model.retryQuit() }
            Button("仍然退出", role: .destructive) { model.forceQuit() }
            Button("取消", role: .cancel) { model.cancelQuit() }
        } message: {
            Text("\(model.quitFailureMessage ?? "")\n\n仍然退出时，权限助手会保持运行；可稍后运行 recover-network.command 完成清理。")
        }
    }

    private var topBar: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(model.state.color.opacity(0.14))
                Image(systemName: model.state.symbol)
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(model.state.color)
            }
            .frame(width: 42, height: 42)

            VStack(alignment: .leading, spacing: 2) {
                Text("tailscale-route")
                    .font(.headline)
                Text("macOS 网络分流控制台")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 12)

            if model.isBusy {
                ProgressView()
                    .controlSize(.small)
            }

            Button {
                model.refresh()
            } label: {
                Image(systemName: "arrow.clockwise")
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.borderless)
            .help("刷新当前网络和路由状态")
            .disabled(model.isBusy)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private var loadingView: some View {
        VStack(spacing: 14) {
            ProgressView()
                .controlSize(.large)
            Text("正在读取网络状态…")
                .font(.headline)
            Text("当前只读取系统信息，不会修改路由。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 180)
        .padding(32)
    }

    private func statusHero(_ report: DiagnosticReport) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("路由状态")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text(statusHeadline)
                        .font(.title2.weight(.semibold))
                    Text(statusDetail)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 12)
                StatusBadge(title: model.state.title, color: model.state.color, symbol: model.state.symbol)
            }

            HStack(spacing: 10) {
                CompactValue(
                    label: "本地网关",
                    value: report.snapshot.gateway ?? "未识别",
                    symbol: "network"
                )
                CompactValue(
                    label: "物理接口",
                    value: interfaceValue(report),
                    symbol: "cable.connector.horizontal"
                )
                CompactValue(
                    label: "Exit Node",
                    value: report.snapshot.tailscaleExitNode ?? "未确认",
                    symbol: "arrow.up.forward.app"
                )
            }

            if let progress = model.routeProgress {
                progressView(progress)
            }

            if let layeredStatus = model.layeredStatus,
               layeredStatus.overall != .ok
            {
                Text("分层状态：路由 \(layerStatusTitle(layeredStatus.route)) · 外接保护 \(layerStatusTitle(layeredStatus.externalProtection)) · 域名解析 \(layerStatusTitle(layeredStatus.domainResolution))")
                    .font(.caption2)
                    .foregroundStyle(layeredStatus.overall == .failed ? .red : .orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(18)
        .background(
            LinearGradient(
                colors: [model.state.color.opacity(0.18), Color.primary.opacity(0.04)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            ), in: RoundedRectangle(cornerRadius: 18, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(model.state.color.opacity(0.18), lineWidth: 1)
        }
    }

    private func overviewCards(_ report: DiagnosticReport) -> some View {
        HStack(spacing: 10) {
            OverviewCard(
                value: model.helperAvailable ? "\(model.routeState.appliedRouteCount)" : "—",
                label: "已应用 IPv4",
                symbol: "arrow.right.circle",
                tint: .blue
            )
            OverviewCard(
                value: "\(report.managedTargets.count)",
                label: "目标 CIDR",
                symbol: "list.bullet.rectangle",
                tint: .indigo
            )
            OverviewCard(
                value: "\(model.detectedDirectRouteCount)",
                label: "系统直连",
                symbol: "point.3.connected.trianglepath.dotted",
                tint: .orange
            )
        }
    }

    private func networkCard(_ report: DiagnosticReport) -> some View {
        DashboardCard(title: "网络环境", symbol: "wifi") {
            VStack(spacing: 0) {
                DetailRow(
                    label: "网络接口",
                    value: interfaceValue(report),
                    symbol: "cable.connector.horizontal"
                )
                DetailRow(
                    label: "默认网关",
                    value: report.snapshot.gateway ?? "未识别",
                    symbol: "arrow.triangle.branch"
                )
                DetailRow(
                    label: "Tailscale",
                    value: tailscaleValue(report),
                    symbol: "shield.lefthalf.filled"
                )
                DetailRow(
                    label: "Exit Node 端点",
                    value: endpointValue(report),
                    symbol: "arrow.up.forward.app"
                )
                DetailRow(
                    label: "域名解析 DNS",
                    value: dnsServerPinValue,
                    symbol: "server.rack"
                )
                DetailRow(
                    label: "LAN access",
                    value: lanAccessValue(report),
                    symbol: "lock.open"
                )
                DetailRow(
                    label: "上次成功应用",
                    value: lastSuccessValue,
                    symbol: "clock"
                )
            }
        }
    }

    private var actionCard: some View {
        DashboardCard(title: "路由操作", symbol: "switch.2") {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    Button {
                        model.enable()
                    } label: {
                        Label(
                            model.state == .enabled ? "分流已启用" : model.state == .paused ? "恢复分流" : "开始分流",
                            systemImage: "play.fill"
                        )
                        .frame(maxWidth: .infinity, minHeight: 38)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.blue)
                    .disabled(!model.helperAvailable || model.isBusy || model.state == .enabled)

                    Button {
                        model.reapply()
                    } label: {
                        Label("更新分流", systemImage: "arrow.clockwise")
                            .frame(maxWidth: .infinity, minHeight: 38)
                    }
                    .buttonStyle(.bordered)
                    .disabled(!model.helperAvailable || model.isBusy || !canReapply)
                }

                HStack(spacing: 10) {
                    Text("开始：应用当前中国 IPv4 清单")
                    Spacer()
                    Text("更新：重新检查网关和路由")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 4)

                Button {
                    model.preview()
                } label: {
                    Label("预览路由计划与变更摘要", systemImage: "list.bullet.rectangle")
                        .frame(maxWidth: .infinity, minHeight: 34)
                }
                .buttonStyle(.bordered)
                .disabled(!model.helperAvailable || model.isBusy)

                if let plan = model.routePlanPreview {
                    routePlanSummary(plan)
                }

                Button(role: .destructive) {
                    showStopConfirmation = true
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "stop.fill")
                        Text("停止分流")
                        Spacer()
                        Text("仅移除受管分流路由")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, minHeight: 38, alignment: .leading)
                }
                .buttonStyle(.bordered)
                .tint(.red)
                .disabled(!model.helperAvailable || model.isBusy)

                Button {
                    showRestoreDefaultConfirmation = true
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "arrow.uturn.backward.circle")
                        Text("恢复系统默认")
                        Spacer()
                        Text("释放外接保护并恢复 Tailscale 原设置")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, minHeight: 38, alignment: .leading)
                }
                .buttonStyle(.bordered)
                .disabled(!model.helperAvailable || model.isBusy)

                if !model.helperAvailable {
                    helperNotice
                }
            }
        }
    }

    private func routePlanSummary(_ plan: RoutePlanPreview) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("只读预览 · \(plan.networkFingerprint.physicalInterface ?? "未知接口") / \(plan.networkFingerprint.gateway ?? "未知网关")")
                .font(.caption.weight(.medium))
            Text("目标 \(plan.desiredRoutes.count) · 新增 \(plan.additions.count) · 切换 \(plan.replacements.count) · 保留 \(plan.alreadyCorrect.count) · 清理旧账本 \(plan.cleanup.count)")
                .font(.caption.monospacedDigit())
            if let error = plan.errors.first {
                Text(error).font(.caption).foregroundStyle(.red)
            } else if let warning = plan.warnings.first {
                Text(warning).font(.caption).foregroundStyle(.orange).lineLimit(3)
            }
            if !plan.additions.isEmpty {
                Text("新增示例：\(plan.additions.prefix(3).map(\.cidr).joined(separator: "、"))")
                    .font(.caption2).foregroundStyle(.secondary).lineLimit(2)
            }
            if !plan.cleanup.isEmpty {
                Text("待清理示例：\(plan.cleanup.prefix(3).map(\.cidr).joined(separator: "、"))")
                    .font(.caption2).foregroundStyle(.secondary).lineLimit(2)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
    }

    private var helperNotice: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "lock.shield")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 4) {
                Text("需要权限助手")
                    .font(.callout.weight(.medium))
                Text(model.helperConnectionState == .reloading
                    ? "正在更新权限助手；协议确认前不会执行新的写路由操作。"
                    : "当前仍可查看诊断；修改系统路由前需要安装并确认受保护的 Helper。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("安装或更新 Helper") {
                    model.installHelper()
                }
                .buttonStyle(.link)
                .font(.caption)
                .padding(.leading, -5)
            }
        }
        .padding(12)
        .background(Color.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var killSwitchCard: some View {
        let status = model.killSwitchStatus
        let blocking = status?.blocking == true
        let tint: Color = blocking ? .red : (status?.enabled == true && status?.armed == true ? .green : .secondary)
        return DashboardCard(title: "断网保护", symbol: blocking ? "lock.shield.fill" : "lock.shield") {
            VStack(alignment: .leading, spacing: 12) {
                Toggle(isOn: Binding(
                    get: { model.killSwitchStatus?.enabled ?? false },
                    set: { model.setKillSwitchEnabled($0) }
                )) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Tailscale 断开时禁止联网")
                            .font(.callout.weight(.medium))
                        Text("Tailscale 断开、Exit Node 离线或经节点无法访问外网时，拦截所有不经过 Tailscale 的流量（含国内分流、局域网和 DNS）。恢复正常、退出 Tailscale 或手动解除后放行；重启 Mac 后自动解除。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(.switch)
                .disabled(!model.helperAvailable || model.killSwitchRequestInFlight || status == nil)

                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: blocking ? "xmark.octagon.fill" : "info.circle")
                        .foregroundStyle(tint)
                    Text(status?.message ?? "正在读取断网保护状态…")
                        .font(.caption)
                        .foregroundStyle(blocking ? Color.red : Color.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if blocking {
                    Button(role: .destructive) {
                        model.releaseKillSwitch()
                    } label: {
                        Label("手动解除断网保护", systemImage: "lock.open")
                    }
                    .disabled(model.killSwitchRequestInFlight)
                }
            }
        }
    }

    private var settingsCard: some View {
        DashboardCard(title: "自动化与工具", symbol: "gearshape.2") {
            VStack(spacing: 12) {
                Toggle(isOn: Binding(
                    get: { model.configuration.autoFollowNetwork },
                    set: { model.setAutoFollow($0) }
                )) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("自动跟随网络变化")
                            .font(.callout.weight(.medium))
                        Text("切换 Wi‑Fi、网线或热点后，等待网络稳定再重建路由")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(.switch)

                Divider()

                HStack(spacing: 10) {
                    ToolButton(title: "更新中国 IP 清单", symbol: "arrow.down.circle") {
                        model.updateList()
                    }
                    .disabled(!model.helperAvailable || model.isBusy || model.chinaListRefreshState.isRefreshing)

                    ToolButton(title: "打开日志", symbol: "doc.text.magnifyingglass") {
                        NSWorkspace.shared.open(model.logURL)
                    }

                    Spacer(minLength: 0)
                }

                if let progress = model.listProgress {
                    progressView(progress)
                }

                DisclosureGroup("高级设置", isExpanded: $showAdvancedSettings) {
                    advancedSettings
                        .padding(.top, 6)
                }
                .font(.caption.weight(.medium))
                .onChange(of: showAdvancedSettings) { expanded in
                    if expanded { loadAdvancedSettingsInputs() }
                }
                if let metadata = model.targetList?.sourceMetadata {
                    Text("中国清单：\(metadata.entryCount) 条源记录 · 目标 \(model.targetList?.cidrs.count ?? 0) 条 · 抓取于 \(metadata.fetchedAt.formatted(date: .abbreviated, time: .shortened)) · SHA \(metadata.sourceSHA256.prefix(12))")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                if let error = model.chinaListRefreshState.lastError {
                    Text("中国清单更新失败：\(error)")
                        .font(.caption2)
                        .foregroundStyle(.red)
                        .lineLimit(2)
                } else if model.chinaListRefreshState.manualUpdateRequired {
                    Text("需要手动更新中国 IP 清单")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                } else if let warning = model.chinaListRefreshState.warning {
                    Text(warning)
                        .font(.caption2)
                        .foregroundStyle(.orange)
                        .lineLimit(2)
                }
            }
        }
    }

    private var advancedSettings: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text("临时域名解析 DNS（IPv4，逗号分隔，最多 4 个）")
                    .font(.caption)
                HStack(spacing: 8) {
                    TextField(DirectDNSDomainResolver.defaultServers.joined(separator: ", "), text: $dnsServerInput)
                        .textFieldStyle(.roundedBorder)
                    Button("保存") {
                        advancedSettingsError = model.saveDNSServers(dnsServerInput)
                        if advancedSettingsError == nil { loadAdvancedSettingsInputs() }
                    }
                    Button("默认") {
                        dnsServerInput = ""
                        advancedSettingsError = model.saveDNSServers("")
                        loadAdvancedSettingsInputs()
                    }
                }
                Text("用于解析临时域名；每个地址都会被钉到当前物理网关。留空恢复默认。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("一键测试目标")
                    .font(.caption)
                HStack(spacing: 8) {
                    TextField("IPv4 地址", text: $testAddressInput)
                        .textFieldStyle(.roundedBorder)
                    TextField("端口", text: $testPortInput)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 70)
                }
                TextField("HTTP URL（可选，例如 https://example.com）", text: $testURLInput)
                    .textFieldStyle(.roundedBorder)
                HStack {
                    Button("保存测试目标") {
                        advancedSettingsError = model.saveConnectivityTest(
                            address: testAddressInput,
                            port: testPortInput,
                            url: testURLInput
                        )
                    }
                    Button("默认") {
                        let defaults = ConnectivityTestSettings()
                        testAddressInput = defaults.address
                        testPortInput = String(defaults.port)
                        testURLInput = defaults.url
                        advancedSettingsError = model.saveConnectivityTest(
                            address: defaults.address,
                            port: String(defaults.port),
                            url: defaults.url
                        )
                    }
                }
            }

            if let advancedSettingsError {
                Text(advancedSettingsError)
                    .font(.caption2)
                    .foregroundStyle(.red)
            }
        }
    }

    private func loadAdvancedSettingsInputs() {
        dnsServerInput = model.configuration.effectiveDNSServers.joined(separator: ", ")
        let test = model.configuration.connectivityTest
        testAddressInput = test.address
        testPortInput = String(test.port)
        testURLInput = test.url
    }

    private var temporaryDomainsCard: some View {
        DashboardCard(title: "临时域名分流", symbol: "globe") {
            VStack(alignment: .leading, spacing: 10) {
                Text("添加根域名会一并解析它和对应 www 子域名（例如 example.com 包含 www.example.com），解析通过国内公共 DNS 完成，并写入系统 hosts；浏览器因此拿到国内边缘 IP 直连。按需刷新：启动时、增删域名时、网络切换或唤醒后重新解析，另外每 30 分钟兜底一次；失败会退避重试，并保留上次有效解析。其他 IPv6 流量仍走 Tailscale；本功能只影响你添加的临时域名，不会更改其他站点的 DNS 或出口设置。")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                HStack(spacing: 8) {
                    TextField("例如：example.com", text: $domainInput)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(addDomain)

                    Button(model.state == .paused || model.state == .disabled ? "添加并缓存" : "添加并应用", action: addDomain)
                        .buttonStyle(.borderedProminent)
                        .disabled(domainInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            || !model.helperAvailable || model.isBusy)
                }

                if let domainInputError {
                    Text(domainInputError)
                        .font(.caption)
                        .foregroundStyle(.red)
                }

                if model.configuration.domainNames.isEmpty {
                    Text("尚未添加临时域名")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    VStack(spacing: 0) {
                        ForEach(model.configuration.domainNames, id: \.self) { domain in
                            HStack(spacing: 8) {
                                Image(systemName: "point.topleft.down.curvedto.point.bottomright.up")
                                    .foregroundStyle(.blue)
                                Text(domain)
                                    .font(.callout.monospaced())
                                Spacer()
                                Button(role: .destructive) {
                                    model.removeDomain(domain)
                                } label: {
                                    Image(systemName: "minus.circle")
                                }
                                .buttonStyle(.borderless)
                                .help("移除并更新分流")
                                .disabled(model.isBusy)
                            }
                            .padding(.vertical, 6)
                        }
                    }
                }

                if !model.configuration.domainNames.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) {
                            Image(systemName: domainRefreshSymbol)
                                .foregroundStyle(domainRefreshColor)
                            Text(domainRefreshSummary)
                                .font(.caption2)
                            if isDomainRefreshRunning {
                                ProgressView()
                                    .controlSize(.mini)
                                    .accessibilityLabel("临时域名刷新进行中")
                            }
                        }
                        if let error = model.domainRefreshState.lastError {
                            Text("保留上次有效解析；本轮失败：\(error)")
                                .font(.caption2)
                                .foregroundStyle(.orange)
                                .lineLimit(2)
                        }
                    }
                }

                DisclosureGroup(isExpanded: $showDomainIPv6Routes) {
                    VStack(alignment: .leading, spacing: 5) {
                        ForEach(model.routeState.managedIPv6Routes.sorted { $0.address < $1.address }, id: \.address) { route in
                            HStack(spacing: 8) {
                                Text(route.address)
                                    .font(.system(size: 10, design: .monospaced))
                                    .textSelection(.enabled)
                                Spacer(minLength: 8)
                                Text(route.interfaceName)
                                    .font(.caption2.monospaced())
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .padding(.top, 5)
                } label: {
                    Text("当前由 App 管理的域名 IPv6 主机路由：\(model.routeState.managedIPv6Routes.count) 条")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .disabled(model.routeState.managedIPv6Routes.isEmpty)
            }
        }
    }

    private var localSubnetProtectionCard: some View {
        DashboardCard(title: "外接网段保护", symbol: "cable.connector") {
            VStack(alignment: .leading, spacing: 10) {
                let networks = model.report?.externalDirectNetworks ?? []
                let active = model.report?.externalSubnetProtectionActive
                HStack(spacing: 8) {
                    Image(systemName: active == true ? "checkmark.circle.fill" : active == false ? "exclamationmark.triangle.fill" : "arrow.triangle.2.circlepath")
                        .foregroundStyle(active == true ? .green : active == false ? .orange : .secondary)
                    Text(model.report?.externalSubnetProtectionMessage ?? "正在自动识别外接网卡…")
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if networks.isEmpty {
                    Text("连接外接网卡后会自动显示其 IPv4 地址和直连网段。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(networks) { network in
                        HStack(spacing: 8) {
                            Image(systemName: "point.topleft.down.curvedto.point.bottomright.up")
                                .foregroundStyle(active == true ? .green : .orange)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("\(network.hardwarePortName) · \(network.interfaceName)")
                                    .font(.caption)
                                Text("\(network.address)  /  \(network.cidr)")
                                    .font(.callout.monospaced())
                                    .textSelection(.enabled)
                            }
                            Spacer()
                        }
                        .padding(.vertical, 3)
                    }
                }

                if model.routeState.tailscalePreferenceLease != nil {
                    let lease = model.routeState.tailscalePreferenceLease
                    let lanAccessNotice = lease?.managedLANAccess == true
                        ? "并暂时启用 Exit Node LAN access 直连本地网段；"
                        : ""
                    Text("自动保护期间暂不接收其他 Tailscale 子网路由；\(lanAccessNotice)Exit Node 默认路由保持连接。拔出外接网卡后会恢复原设置。")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func addDomain() {
        guard let error = model.addDomain(domainInput) else {
            domainInput = ""
            domainInputError = nil
            return
        }
        domainInputError = error
    }

    private var domainRefreshSummary: String {
        let state = model.domainRefreshState
        if isDomainRefreshRunning {
            return "正在刷新临时域名… · A \(state.resolvedIPv4Count) 条 · AAAA \(state.resolvedIPv6Count) 条"
        }
        if state.pending {
            return "等待路由操作结束后刷新临时域名… · A \(state.resolvedIPv4Count) 条 · AAAA \(state.resolvedIPv6Count) 条"
        }
        if state.lastError != nil {
            let next = state.nextRefreshAt?.formatted(date: .omitted, time: .shortened) ?? "稍后"
            return "本轮刷新失败 · 下次约 \(next) · A \(state.resolvedIPv4Count) 条 · AAAA \(state.resolvedIPv6Count) 条"
        }
        if let last = state.lastSuccessAt {
            let next = state.nextRefreshAt?.formatted(date: .omitted, time: .shortened) ?? "稍后"
            return "上次刷新 \(last.formatted(date: .omitted, time: .shortened)) · 下次约 \(next) · A \(state.resolvedIPv4Count) 条 · AAAA \(state.resolvedIPv6Count) 条"
        }
        return "等待首次自动刷新… · A \(state.resolvedIPv4Count) 条 · AAAA \(state.resolvedIPv6Count) 条"
    }

    private var isDomainRefreshRunning: Bool {
        model.activeOperation == .domainRefresh
    }

    private var domainRefreshSymbol: String {
        if isDomainRefreshRunning { return "arrow.triangle.2.circlepath" }
        if model.domainRefreshState.pending { return "clock.arrow.circlepath" }
        if model.domainRefreshState.lastError != nil { return "exclamationmark.triangle" }
        return "checkmark.circle"
    }

    private var domainRefreshColor: Color {
        if isDomainRefreshRunning { return .blue }
        if model.domainRefreshState.pending { return .orange }
        if model.domainRefreshState.lastError != nil { return .orange }
        return .green
    }

    private func feedbackCard(_ report: DiagnosticReport) -> some View {
        DashboardCard(title: "诊断反馈", symbol: "waveform.path.ecg") {
            VStack(alignment: .leading, spacing: 10) {
                if let error = report.errors.first {
                    FeedbackRow(message: error, symbol: "xmark.octagon.fill", tint: .red)
                } else if let warning = report.warnings.first {
                    FeedbackRow(message: warning, symbol: "exclamationmark.triangle.fill", tint: .orange)
                } else if let message = model.lastMessage {
                    FeedbackRow(message: message, symbol: "checkmark.circle.fill", tint: .green)
                } else {
                    FeedbackRow(message: "未发现新的诊断信息", symbol: "checkmark.circle", tint: .secondary)
                }

                if model.routeState.lifecycle == .partial {
                    FeedbackRow(
                        message: "检测到部分目标未完成保护；更新分流后会按当前清单重新校验。",
                        symbol: "info.circle.fill",
                        tint: .orange
                    )
                }

                Button {
                    model.runOneClickTest()
                } label: {
                    HStack(spacing: 6) {
                        if model.isCheckingConnectivity {
                            ProgressView().controlSize(.small)
                        }
                        Label("一键测试（分流状态 + 分层连通性）", systemImage: "checkmark.shield")
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .disabled(model.isBusy || model.isCheckingConnectivity)

                Text("测试目标：\(connectivityTargetSummary)（在“自动化与工具 › 高级设置”中修改）")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                if let connectivity = model.connectivityReport {
                    VStack(alignment: .leading, spacing: 4) {
                        if let explanation = model.routeExplanation {
                            Text("路由解释：\(explanation.summary)")
                                .font(.caption2.weight(.medium))
                                .padding(.bottom, 2)
                                .textSelection(.enabled)
                        }
                        ForEach(Array(connectivity.layers.enumerated()), id: \.offset) { _, layer in
                            HStack(alignment: .top, spacing: 6) {
                                Image(systemName: connectivitySymbol(layer.status))
                                    .foregroundStyle(connectivityColor(layer.status))
                                Text("\(layer.layer)：\(layer.detail)")
                                    .font(.caption2)
                                    .textSelection(.enabled)
                            }
                        }
                    }
                    .padding(9)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
            }
        }
    }

    private var connectivityTargetSummary: String {
        let settings = model.configuration.connectivityTest
        let url = settings.url.trimmingCharacters(in: .whitespacesAndNewlines)
        return "\(settings.address):\(settings.port)" + (url.isEmpty ? "" : " · \(url)")
    }

    private func connectivitySymbol(_ status: ConnectivityLayerStatus) -> String {
        switch status {
        case .passed: return "checkmark.circle.fill"
        case .failed: return "xmark.circle.fill"
        case .unknown: return "questionmark.circle"
        case .skipped: return "minus.circle"
        case .serviceError: return "exclamationmark.triangle.fill"
        }
    }

    private func connectivityColor(_ status: ConnectivityLayerStatus) -> Color {
        switch status {
        case .passed: return .green
        case .failed: return .red
        case .unknown, .skipped: return .secondary
        case .serviceError: return .orange
        }
    }

    private func progressView(_ progress: RouteProgress) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text(progress.message)
                Spacer()
                Text("\(Int((progress.fraction * 100).rounded()))%")
                    .monospacedDigit()
            }
            .font(.caption.weight(.medium))

            GeometryReader { geometry in
                let fraction = min(max(progress.fraction, 0), 1)
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.primary.opacity(0.10))
                    Capsule()
                        .fill(model.state.color)
                        .frame(width: geometry.size.width * fraction)
                }
            }
            .frame(height: 7)
            .accessibilityLabel("操作进度")
            .accessibilityValue("\(Int((progress.fraction * 100).rounded()))%")
        }
        .padding(11)
        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var bottomBar: some View {
        HStack(spacing: 12) {
            HStack(spacing: 6) {
                Circle()
                    .fill(model.state.color)
                    .frame(width: 7, height: 7)
                Text(model.state.title)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button {
                NSWorkspace.shared.open(model.logURL)
            } label: {
                Label("日志", systemImage: "doc.text")
            }
            .buttonStyle(.plain)
            .font(.caption)

            Button(model.isQuitting ? "正在退出…" : "退出并移除分流") {
                model.quitApp()
            }
            .buttonStyle(.plain)
            .font(.caption)
            .foregroundStyle(.secondary)
            // Quitting waits for any running operation itself; only block a
            // second click while a quit is already in progress.
            .disabled(model.isQuitting)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 11)
    }

    private func interfaceValue(_ report: DiagnosticReport) -> String {
        let interfaceName = report.snapshot.physicalInterface ?? "—"
        guard let portName = report.snapshot.physicalPortName else { return interfaceName }
        return "\(portName) · \(interfaceName)"
    }

    private func layerStatusTitle(_ status: LayerStatus) -> String {
        switch status {
        case .notEvaluated: return "未评估"
        case .ok: return "正常"
        case .degraded: return "降级"
        case .failed: return "失败"
        case .unknown: return "未知"
        }
    }

    private func tailscaleValue(_ report: DiagnosticReport) -> String {
        if !report.tailscale.isInstalled { return "未安装" }
        if !report.tailscale.isRunning { return "未运行" }
        let interfaceName = report.snapshot.tailscaleInterface ?? "接口未识别"
        return "\(interfaceName) · 已连接"
    }

    private func lanAccessValue(_ report: DiagnosticReport) -> String {
        guard report.snapshot.tailscaleExitNode != nil else { return "不适用" }
        guard let enabled = report.tailscale.exitNodeAllowLANAccess else { return "未确认" }
        return enabled ? "已开启" : "未开启"
    }

    /// Whether the resolver DNS servers are pinned to the physical adapter.
    private var dnsServerPinValue: String {
        let servers = model.configuration.effectiveDNSServers
        let pinned = model.routeState.managedDNSServerRoutes
        let pinnedServers = servers.filter { server in
            pinned.contains { $0.cidr == "\(server)/32" }
        }
        guard !pinnedServers.isEmpty else { return "未钉路由" }
        let interfaces = Array(Set(pinned.map(\.interfaceName))).sorted().joined(separator: "/")
        if pinnedServers.count == servers.count {
            return "\(servers.count) 个已钉 \(interfaces)"
        }
        return "\(pinnedServers.count)/\(servers.count) 个已钉 \(interfaces)"
    }

    private func endpointValue(_ report: DiagnosticReport) -> String {
        guard let endpoint = report.snapshot.tailscaleExitNodeEndpoint else { return "未确认" }
        if let route = model.routeState.managedExitNodeEndpointRoutes
            .first(where: { $0.cidr == "\(endpoint)/32" })
        {
            return "\(endpoint)（已钉 \(route.interfaceName)）"
        }
        return "\(endpoint)（未钉路由）"
    }

    private var lastSuccessValue: String {
        guard let date = model.routeState.lastSuccessAt else { return "尚未应用" }
        return date.formatted(date: .abbreviated, time: .shortened)
    }

    private var canReapply: Bool {
        switch model.routeState.lifecycle {
        case .enabled, .partial, .networkChanging, .error:
            return true
        case .disabled, .applying, .paused, .unavailable:
            return false
        }
    }

    private var statusHeadline: String {
        switch model.state {
        case .enabled: return "IPv4 与域名分流正常"
        case .partial: return "分流部分生效"
        case .networkChanging: return "正在等待网络稳定"
        case .applying: return "正在更新路由"
        case .error: return "分流需要处理"
        case .paused: return "分流已停止，基础路由保留"
        case .unavailable: return "权限助手未连接"
        case .disabled: return "分流尚未启用"
        }
    }

    private var statusDetail: String {
        switch model.state {
        case .enabled: return "国内 IPv4 和临时域名 A/AAAA 按规则分流；未指定的 IPv6 继续走 Tailscale。"
        case .partial: return "部分目标或自动保护尚未完成，正在等待下一次网络稳定后重试。"
        case .networkChanging: return "检测到网关或接口变化，应用前会重新检查。"
        case .applying: return "正在安全地重建、验证并保存路由状态。"
        case .error: return model.routeState.lastError ?? "请查看下方诊断反馈。"
        case .paused: return "分流已停止，受管理路由已移除；物理与 Tailscale 基础路由保留。"
        case .unavailable: return "只读诊断仍可用，修改路由需要安装 Helper。"
        case .disabled: return "点击“开始分流”应用当前中国 IPv4 清单。"
        }
    }
}

private struct DashboardCard<Content: View>: View {
    let title: String
    let symbol: String
    let content: Content

    init(title: String, symbol: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.symbol = symbol
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(title, systemImage: symbol)
                .font(.headline)
            content
        }
        .padding(16)
        .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.primary.opacity(0.07), lineWidth: 1)
        }
    }
}

private struct StatusBadge: View {
    let title: String
    let color: Color
    let symbol: String

    var body: some View {
        Label(title, systemImage: symbol)
            .font(.caption.weight(.semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(color.opacity(0.13), in: Capsule())
    }
}

private struct CompactValue: View {
    let label: String
    let value: String
    let symbol: String

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Image(systemName: symbol)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.caption.weight(.medium).monospaced())
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(Color.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
    }
}

private struct OverviewCard: View {
    let value: String
    let label: String
    let symbol: String
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Image(systemName: symbol)
                .foregroundStyle(tint)
            Text(value)
                .font(.title3.weight(.semibold).monospacedDigit())
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

private struct DetailRow: View {
    let label: String
    let value: String
    let symbol: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .frame(width: 18)
                .foregroundStyle(.secondary)
            Text(label)
                .foregroundStyle(.secondary)
                .frame(width: 88, alignment: .leading)
            Text(value)
                .font(.callout.monospaced())
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 6)
    }
}

private struct ToolButton: View {
    let title: String
    let symbol: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
        }
        .buttonStyle(.borderless)
        .font(.caption)
    }
}

private struct FeedbackRow: View {
    let message: String
    let symbol: String
    let tint: Color

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: symbol)
                .foregroundStyle(tint)
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }
}
