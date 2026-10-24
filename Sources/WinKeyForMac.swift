import AppKit
import SwiftUI
import ApplicationServices
import Carbon
import ServiceManagement

final class SettingsModel: ObservableObject {
    @Published var enabled = false
    @Published var common = true
    @Published var browser = true
    @Published var navigation = false
    @Published var inputSwitch = false
    @Published var shiftInputSwitch = true
    @Published var capsLockCase = true
    @Published var restoredModifiers = false
    @Published var accessibility = false
    @Published var running = false
    @Published var secureInput = false
    @Published var frontName = ""
    @Published var frontID = ""
    @Published var message = ""
    @Published var exclusions: [String: String] = [:]
    @Published var launchAtLogin = false

    private let monitor = EventMonitor()
    private let defaults = UserDefaults.standard
    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []
    private var reportedFailure = false
    var onChange: (() -> Void)?
    var excluded: Bool { exclusions[frontID] != nil }
    var canEnable: Bool { restoredModifiers && accessibility }
    var statusTitle: String {
        if !enabled { return canEnable ? "已暂停" : "未启用" }
        if !accessibility { return "需要辅助功能权限" }
        if reportedFailure { return "需要检查" }
        if secureInput { return "安全输入期间暂停" }
        if excluded { return "当前应用暂停映射" }
        return running ? "Windows 快捷键已启用" : "正在启动…"
    }
    var statusColor: Color {
        if enabled && running && !excluded && !secureInput && !reportedFailure { return .green }
        return enabled && reportedFailure ? .red : .orange
    }

    init() {
        common = savedBool("common", default: true)
        browser = savedBool("browser", default: true)
        navigation = savedBool("navigation", default: false)
        inputSwitch = savedBool("inputSwitch", default: false)
        shiftInputSwitch = savedBool("shiftInputSwitch", default: true)
        capsLockCase = savedBool("capsLockCase", default: true)
        restoredModifiers = defaults.bool(forKey: "restoredModifiers")
        exclusions = defaults.dictionary(forKey: "exclusions") as? [String: String] ?? [
            "com.apple.Terminal": "终端", "com.googlecode.iterm2": "iTerm2",
            "dev.warp.Warp-Stable": "Warp", "com.microsoft.rdc.macos": "Microsoft 远程桌面",
            "com.microsoft.rdc.mac": "Windows App", "com.parallels.desktop.console": "Parallels Desktop",
            "com.vmware.fusion": "VMware Fusion", "com.anydesk.Anydesk": "AnyDesk",
            "com.teamviewer.TeamViewer": "TeamViewer"
        ]
        accessibility = AXIsProcessTrusted()
        launchAtLogin = SMAppService.mainApp.status == .enabled
        monitor.report = { [weak self] text, ok in
            guard let self else { return }
            self.message = text
            self.running = self.monitor.isRunning && ok
            self.reportedFailure = !ok
            self.onChange?()
        }
        monitor.inputRequested = { [weak self] in
            if let error = InputSources.toggleChineseEnglish() { self?.message = error }
        }
        refreshFrontApp()
        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(forName: NSWorkspace.didActivateApplicationNotification,
            object: nil, queue: .main) { [weak self] _ in self?.refreshFrontApp() })
        observers.append(center.addObserver(forName: NSWorkspace.willSleepNotification,
            object: nil, queue: .main) { [weak self] _ in self?.monitor.stop() })
        observers.append(center.addObserver(forName: NSWorkspace.didWakeNotification,
            object: nil, queue: .main) { [weak self] _ in
                self?.message = "已唤醒，正在检查键盘监听。"
                self?.refreshHealth()
        })
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.refreshHealth() }
        if defaults.bool(forKey: "enabled"), canEnable { setEnabled(true) }
    }

    private func savedBool(_ key: String, default fallback: Bool) -> Bool {
        defaults.object(forKey: key) == nil ? fallback : defaults.bool(forKey: key)
    }

    func setEnabled(_ value: Bool) {
        guard !value || canEnable else {
            message = restoredModifiers ? "请先打开辅助功能权限，再点击启用。" : "请先恢复 Control / Command 默认映射，并勾选确认。"
            return
        }
        enabled = value
        defaults.set(value, forKey: "enabled")
        reportedFailure = false
        syncMonitor()
        if value {
            message = "正在启动键盘监听…"
            monitor.start()
        } else {
            message = "已暂停，使用系统原有快捷键。"
            // Keep the tap running briefly to finish key-up pairing; it passes all new keys through.
        }
        onChange?()
    }

    func saveRules() {
        for (key, value) in [("common", common), ("browser", browser), ("navigation", navigation),
                             ("inputSwitch", inputSwitch),
                             ("shiftInputSwitch", shiftInputSwitch),
                             ("capsLockCase", capsLockCase),
                             ("restoredModifiers", restoredModifiers)] { defaults.set(value, forKey: key) }
        if !restoredModifiers && enabled { setEnabled(false) }
        syncMonitor()
    }

    func refreshHealth() {
        let granted = AXIsProcessTrusted()
        if accessibility && !granted {
            monitor.stop()
            message = "辅助功能权限已关闭。重新授权后，请再次启用。"
            reportedFailure = true
        }
        accessibility = granted
        secureInput = IsSecureEventInputEnabled()
        running = monitor.isRunning
        syncMonitor()
        if enabled && granted && !reportedFailure {
            if !monitor.isRunning { monitor.start() }
            else { monitor.checkHealth() }
        }
        onChange?()
    }

    func retry() {
        reportedFailure = false
        refreshHealth()
        if !enabled { setEnabled(true) }
    }

    private func refreshFrontApp() {
        guard let app = NSWorkspace.shared.frontmostApplication,
              app.bundleIdentifier != Bundle.main.bundleIdentifier else { return }
        frontName = app.localizedName ?? "当前应用"
        frontID = app.bundleIdentifier ?? ""
        syncMonitor()
        onChange?()
    }

    private func syncMonitor() {
        monitor.update(MonitorSnapshot(
            options: ShortcutOptions(common: common, browser: browser, navigation: navigation,
                                     inputSwitch: inputSwitch, shiftInputSwitch: shiftInputSwitch,
                                     capsLockCase: capsLockCase),
            enabled: enabled, excluded: excluded, suspended: secureInput || !accessibility, frontAppID: frontID))
    }

    func excludeCurrent() {
        guard !frontID.isEmpty else { return }
        exclusions[frontID] = frontName
        saveExclusions()
    }

    func removeExclusion(_ id: String) {
        exclusions.removeValue(forKey: id)
        saveExclusions()
    }

    private func saveExclusions() {
        defaults.set(exclusions, forKey: "exclusions")
        syncMonitor(); onChange?()
    }

    func grantAccessibility() {
        openSettings("Privacy_Accessibility")
    }

    func openSettings(_ anchor: String) {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") else { return }
        NSWorkspace.shared.open(url)
    }

    func openKeyboardSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }

    func setLogin(_ value: Bool) {
        do {
            if value { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
            launchAtLogin = SMAppService.mainApp.status == .enabled
            if value && !launchAtLogin { message = "请在系统的登录项设置中允许 WinKeyForMac。" }
        } catch {
            launchAtLogin = SMAppService.mainApp.status == .enabled
            message = "登录启动设置失败。请先将应用放到固定位置，再重试。"
        }
    }

    func shutdown() { timer?.invalidate(); monitor.stop() }
}

struct SettingsView: View {
    @ObservedObject var model: SettingsModel
    @State private var showExclusions = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 15) {
                    Image(systemName: "keyboard").font(.system(size: 31, weight: .medium))
                        .foregroundStyle(.white).frame(width: 62, height: 62)
                        .background(LinearGradient(colors: [.blue, .indigo], startPoint: .topLeading, endPoint: .bottomTrailing))
                        .clipShape(RoundedRectangle(cornerRadius: 16))
                    VStack(alignment: .leading, spacing: 5) {
                        Text("WinKeyForMac").font(.system(size: 27, weight: .bold))
                        Text("熟悉的快捷键，带到 Mac。").font(.system(size: 14)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text("试用版 0.4.0").font(.caption).foregroundStyle(.secondary)
                }

                card {
                    HStack(alignment: .center) {
                        Circle().fill(model.statusColor).frame(width: 10, height: 10)
                        VStack(alignment: .leading, spacing: 5) {
                            Text(model.enabled ? model.statusTitle : "启用").font(.headline)
                            if !model.message.isEmpty {
                                Text(model.message).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        Spacer(minLength: 12)
                        Toggle("启用", isOn: Binding(get: { model.enabled }, set: { model.setEnabled($0) }))
                            .toggleStyle(.switch).labelsHidden().accessibilityLabel("启用")
                    }
                    if model.enabled && !model.running {
                        Button("重新检查并启用") { model.retry() }
                    }
                }

                if !model.restoredModifiers || !model.accessibility {
                    card {
                        Text("首次使用 · 两步设置").font(.headline)
                        VStack(alignment: .leading, spacing: 10) {
                            Text("1  恢复键盘原有映射").fontWeight(.medium)
                            Text("之前交换过 Control 和 Command？请在“键盘 → 键盘快捷键 → 修饰键”中，对内置和外接键盘分别恢复默认，避免重复改键。")
                                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                            HStack {
                                Button("打开键盘设置") { model.openKeyboardSettings() }
                                Spacer()
                            }
                            Toggle("Control 和 Command 已恢复默认", isOn: Binding(
                                get: { model.restoredModifiers },
                                set: { model.restoredModifiers = $0; model.saveRules() }))
                        }
                        Divider().padding(.vertical, 4)
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("2  允许辅助功能").fontWeight(.medium)
                                Text(model.accessibility ? "已授权" : "用于把指定快捷键转换为 Mac 操作。")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button(model.accessibility ? "已授权 ✓" : "打开授权设置") { model.grantAccessibility() }
                                .disabled(model.accessibility)
                        }
                    }
                }

                card {
                    Text("常用操作").font(.headline)
                    ruleToggle("编辑与文件", detail: "Ctrl+C / V / X / A / Z / Y / W / F / S / N / O / P", value: $model.common)
                    Divider()
                    ruleToggle("浏览器与标签页", detail: "Ctrl+T / L / R / 1–9 / 0 / + / −，Ctrl+Shift+T", value: $model.browser)
                    Divider()
                    VStack(alignment: .leading, spacing: 4) {
                        Text("切换应用")
                        Text("Command（⌘）+Tab；加 Shift 反向切换，松开 Command 确认。保留系统快捷键。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Divider()
                    ruleToggle("按词移动与删除", detail: "Ctrl+← / → / Backspace；Ctrl+Home / End 到文首或文尾", value: $model.navigation)
                    Text("替换模式：列出的 Ctrl 手势会替换对应的 Command 组合。Command+Tab 保留系统行为。暂停或进入例外应用后恢复；其他快捷键保持原样。")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }

                card {
                    Text("大小写与中英文").font(.headline)
                    inputRuleToggle("Caps Lock 切换大小写",
                        detail: "开启时保留大写锁定；关闭时屏蔽大写锁定，Shift+字母仍可输入大写。",
                        prerequisite: "前提：在“键盘 → 文字输入 → 编辑 → 所有输入法”中关闭“使用大写锁定键切换 ABC 输入法”，使 Caps Lock 只控制大小写。",
                        value: $model.capsLockCase)
                    Divider()
                    inputRuleToggle("Shift 切换中英文",
                        detail: "单按左 / 右 Shift，并在半秒内松开；组合键、鼠标操作和长按不触发。",
                        prerequisite: "前提：在“键盘 → 文字输入 → 编辑”中同时添加中文输入法和英文 / ABC 输入法。切换系统输入法，不切换第三方输入法内部的中英模式。",
                        value: $model.shiftInputSwitch)
                    Divider()
                    inputRuleToggle("Ctrl+空格切换中英文",
                        detail: "按 Ctrl+空格切换，可与 Shift 方案分别开启；长按只切换一次。",
                        prerequisite: "前提：在“键盘 → 文字输入 → 编辑”中同时添加中文输入法和英文 / ABC 输入法。与 Shift 使用同一组输入法。",
                        value: $model.inputSwitch)
                    Text("三个开关分别保存；仅在快捷键已启用且当前应用未暂停映射时生效。")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }

                card {
                    HStack {
                        VStack(alignment: .leading, spacing: 5) {
                            Text("应用例外").font(.headline)
                            Text("终端、远程桌面和虚拟机默认保留原有按键。")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button(showExclusions ? "收起" : "管理 \(model.exclusions.count) 项") { showExclusions.toggle() }
                    }
                    if !model.frontName.isEmpty {
                        HStack {
                            Text("最近使用：\(model.frontName)").font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            Button(model.excluded ? "恢复此应用映射" : "暂停此应用映射") {
                                if model.excluded { model.removeExclusion(model.frontID) }
                                else { model.excludeCurrent() }
                            }
                        }
                    }
                    if showExclusions {
                        Divider()
                        ForEach(model.exclusions.keys.sorted(), id: \.self) { id in
                            HStack {
                                Text(model.exclusions[id] ?? id).font(.caption)
                                Spacer()
                                Button("移除") { model.removeExclusion(id) }.controlSize(.small)
                            }
                        }
                    }
                }

                HStack {
                    Toggle("登录时启动", isOn: Binding(get: { model.launchAtLogin }, set: { model.setLogin($0) }))
                    Spacer()
                    Menu("帮助") {
                        Button("辅助功能设置") { model.openSettings("Privacy_Accessibility") }
                        Button("输入监控设置（监听启动失败时检查）") { model.openSettings("Privacy_ListenEvent") }
                        Button("键盘修饰键设置") { model.openKeyboardSettings() }
                    }.fixedSize()
                }.font(.caption).foregroundStyle(.secondary)
                Text("本地运行 · 不读取剪贴板 · 不保存输入内容 · 退出后停止映射")
                    .font(.caption2).foregroundStyle(.secondary).frame(maxWidth: .infinity)
            }
            .padding(26)
        }
        .frame(minWidth: 650, minHeight: 680)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func ruleToggle(_ title: String, detail: String, value: Binding<Bool>) -> some View {
        Toggle(isOn: Binding(get: { value.wrappedValue }, set: { value.wrappedValue = $0; model.saveRules() })) {
            VStack(alignment: .leading, spacing: 5) {
                Text(title).font(.system(size: 13, weight: .medium))
                Text(detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }.toggleStyle(.switch)
    }

    private func inputRuleToggle(_ title: String, detail: String, prerequisite: String,
                                 value: Binding<Bool>) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ruleToggle(title, detail: detail, value: value)
            Text(prerequisite)
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Button("打开键盘设置…") { model.openKeyboardSettings() }
                .controlSize(.small)
                .accessibilityLabel("\(title)：打开键盘设置")
        }
    }

    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 13, content: content)
            .padding(17).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: .controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 13))
            .overlay(RoundedRectangle(cornerRadius: 13).strokeBorder(Color.primary.opacity(0.06)))
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private let model = SettingsModel()
    private var window: NSWindow?
    private var item: NSStatusItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        installMainMenu()
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item?.autosaveName = "WinKeyForMac.StatusItem"
        item?.isVisible = true
        model.onChange = { [weak self] in self?.updateMenu() }
        updateMenu()
        showSettings()
    }

    private func updateMenu() {
        guard let item else { return }
        let symbol = model.enabled && model.running ? "keyboard.fill" : "keyboard"
        if let button = item.button {
            let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "WinKeyForMac")
            image?.size = NSSize(width: 18, height: 18)
            image?.isTemplate = true
            button.image = image
            button.imagePosition = .imageOnly
            button.title = ""
            button.setAccessibilityLabel("WinKeyForMac · 打开快捷键菜单")
        }
        item.button?.toolTip = "WinKeyForMac · \(model.statusTitle)"
        let menu = NSMenu()
        let status = NSMenuItem(title: model.statusTitle, action: nil, keyEquivalent: "")
        status.isEnabled = false; menu.addItem(status)
        menu.addItem(.separator())
        let toggle = NSMenuItem(title: model.enabled ? "暂停 Windows 快捷键" : "启用 Windows 快捷键", action: #selector(toggleEnabled), keyEquivalent: "")
        toggle.target = self; menu.addItem(toggle)
        if !model.frontID.isEmpty {
            let exclusion = NSMenuItem(title: model.excluded ? "恢复 \(model.frontName) 的映射" : "暂停 \(model.frontName) 的映射", action: #selector(toggleExclusion), keyEquivalent: "")
            exclusion.target = self; menu.addItem(exclusion)
        }
        let settings = NSMenuItem(title: "打开设置…", action: #selector(showSettings), keyEquivalent: "")
        settings.target = self; menu.addItem(settings)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "退出 WinKeyForMac", action: #selector(quitApp), keyEquivalent: "")
        quit.target = self; menu.addItem(quit)
        item.menu = menu
    }

    private func installMainMenu() {
        let main = NSMenu()
        let appEntry = NSMenuItem()
        main.addItem(appEntry)
        let appMenu = NSMenu(title: "WinKeyForMac")
        let settings = NSMenuItem(title: "WinKeyForMac 设置…", action: #selector(showSettings), keyEquivalent: ",")
        settings.target = self
        appMenu.addItem(settings)
        appMenu.addItem(.separator())
        let hide = NSMenuItem(title: "隐藏 WinKeyForMac", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        hide.target = NSApp
        appMenu.addItem(hide)
        appMenu.addItem(.separator())
        let quit = NSMenuItem(title: "退出 WinKeyForMac", action: #selector(quitApp), keyEquivalent: "q")
        quit.target = self
        appMenu.addItem(quit)
        appEntry.submenu = appMenu
        NSApp.mainMenu = main
    }

    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let menu = NSMenu()
        let settings = NSMenuItem(title: "打开 WinKeyForMac 设置…", action: #selector(showSettings), keyEquivalent: "")
        settings.target = self
        menu.addItem(settings)
        let toggle = NSMenuItem(title: model.enabled ? "暂停 Windows 快捷键" : "启用 Windows 快捷键", action: #selector(toggleEnabled), keyEquivalent: "")
        toggle.target = self
        menu.addItem(toggle)
        return menu
    }

    @objc private func toggleEnabled() { model.setEnabled(!model.enabled) }
    @objc private func toggleExclusion() {
        if model.excluded { model.removeExclusion(model.frontID) } else { model.excludeCurrent() }
    }
    @objc private func quitApp() { NSApp.terminate(nil) }

    @objc func showSettings() {
        NSApp.setActivationPolicy(.regular)
        if window == nil {
            let content = NSHostingController(rootView: SettingsView(model: model))
            let created = NSWindow(contentViewController: content)
            created.title = "WinKeyForMac · Windows 操作习惯"
            created.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            created.setContentSize(NSSize(width: 700, height: 810))
            created.minSize = NSSize(width: 670, height: 710)
            created.isReleasedWhenClosed = false
            created.delegate = self
            created.center()
            window = created
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        guard let closing = notification.object as? NSWindow, closing === window else { return }
        // Closing settings keeps keyboard mappings and the menu-bar entry alive.
        NSApp.setActivationPolicy(.accessory)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showSettings(); return true
    }

    func applicationWillTerminate(_ notification: Notification) { model.shutdown() }
}

@main
enum WinKeyForMacMain {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
        withExtendedLifetime(delegate) {}
    }
}
