import Cocoa
import WebKit
import Carbon

// Global reference for hotkey callback
var globalApp: App?

struct Tab {
    let webView: WKWebView
    var title: String = "New Tab"
}

// MARK: - Hotkey Definitions

struct HotkeyConfig: Equatable {
    let label: String
    let keyCode: UInt32
    let carbonModifiers: UInt32
    let displayString: String
}

let presetHotkeys: [HotkeyConfig] = [
    HotkeyConfig(label: "Ctrl + S", keyCode: UInt32(kVK_ANSI_S), carbonModifiers: UInt32(controlKey), displayString: "⌃S"),
    HotkeyConfig(label: "Ctrl + Shift + S", keyCode: UInt32(kVK_ANSI_S), carbonModifiers: UInt32(controlKey | shiftKey), displayString: "⌃⇧S"),
    HotkeyConfig(label: "Ctrl + Shift + H", keyCode: UInt32(kVK_ANSI_H), carbonModifiers: UInt32(controlKey | shiftKey), displayString: "⌃⇧H"),
    HotkeyConfig(label: "Option + Space", keyCode: UInt32(kVK_Space), carbonModifiers: UInt32(optionKey), displayString: "⌥Space"),
    HotkeyConfig(label: "Cmd + Shift + B", keyCode: UInt32(kVK_ANSI_B), carbonModifiers: UInt32(cmdKey | shiftKey), displayString: "⌘⇧B"),
    HotkeyConfig(label: "Ctrl + `", keyCode: UInt32(kVK_ANSI_Grave), carbonModifiers: UInt32(controlKey), displayString: "⌃`"),
]


enum PageOption: String, CaseIterable {
    case claude = "https://claude.ai"
    case chatgpt = "https://chatgpt.com"
    case google = "https://google.com"
    case blank = "about:blank"
    case custom = "custom"

    var label: String {
        switch self {
        case .claude: return "Claude"
        case .chatgpt: return "ChatGPT"
        case .google: return "Google"
        case .blank: return "Blank Page"
        case .custom: return "Custom URL"
        }
    }
}

class App: NSObject, NSApplicationDelegate, WKNavigationDelegate, NSWindowDelegate {
    var statusItem: NSStatusItem!
    var window: NSWindow?
    var urlBar: NSTextField?
    var sTimes: [Date] = []
    var localMon: Any?
    var globalMon: Any?
    var hotKeyRef: EventHotKeyRef?
    var opacity: CGFloat = 0.55
    var settingsWindow: NSWindow?

    // Settings - persisted via UserDefaults
    var homePage: PageOption { PageOption(rawValue: UserDefaults.standard.string(forKey: "homePage") ?? PageOption.claude.rawValue) ?? .claude }
    var homePageCustomURL: String { UserDefaults.standard.string(forKey: "homePageCustomURL") ?? "" }
    var newTabPage: PageOption { PageOption(rawValue: UserDefaults.standard.string(forKey: "newTabPage") ?? PageOption.blank.rawValue) ?? .blank }
    var newTabPageCustomURL: String { UserDefaults.standard.string(forKey: "newTabPageCustomURL") ?? "" }

    func resolvedHomePageURL() -> String {
        homePage == .custom ? (homePageCustomURL.isEmpty ? "about:blank" : homePageCustomURL) : homePage.rawValue
    }

    func resolvedNewTabURL() -> String {
        newTabPage == .custom ? (newTabPageCustomURL.isEmpty ? "about:blank" : newTabPageCustomURL) : newTabPage.rawValue
    }

    var tabs: [Tab] = []
    var activeTabIndex: Int = 0
    var tabBar: NSView?
    var toolbar: NSVisualEffectView?
    var webContainer: NSView?
    var urlBarVisible: Bool = false

    var activeWebView: WKWebView? { tabs.isEmpty ? nil : tabs[activeTabIndex].webView }

    func applicationDidFinishLaunching(_ n: Notification) {
        NSApp.setActivationPolicy(.regular)

        statusItem = NSStatusBar.system.statusItem(withLength: 30)
        statusItem.button?.title = "•"
        let m = NSMenu()
        let opacityLabel = NSMenuItem(title: "Opacity", action: nil, keyEquivalent: "")
        opacityLabel.isEnabled = false
        m.addItem(opacityLabel)

        let sliderItem = NSMenuItem()
        let sliderView = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 30))
        let slider = NSSlider(frame: NSRect(x: 16, y: 5, width: 168, height: 20))
        slider.minValue = 10
        slider.maxValue = 100
        slider.doubleValue = 55
        slider.isContinuous = true
        slider.target = self
        slider.action = #selector(sliderChanged(_:))
        sliderView.addSubview(slider)
        sliderItem.view = sliderView
        m.addItem(sliderItem)

        m.addItem(.separator())
        m.addItem(NSMenuItem(title: "Settings", action: #selector(openSettings), keyEquivalent: ","))
        m.addItem(.separator())
        m.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem.menu = m

        let mainMenu = NSMenu()

        let editMenuItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editMenuItem.submenu = editMenu
        mainMenu.addItem(editMenuItem)

        let navMenuItem = NSMenuItem()
        let navMenu = NSMenu(title: "Nav")
        navMenu.addItem(withTitle: "Focus URL Bar", action: #selector(focusURLBar), keyEquivalent: "l")
        navMenu.addItem(withTitle: "New Tab", action: #selector(newTabAction), keyEquivalent: "t")
        navMenu.addItem(withTitle: "Close Tab", action: #selector(closeTabAction), keyEquivalent: "w")
        let nextTab = NSMenuItem(title: "Next Tab", action: #selector(nextTabAction), keyEquivalent: "]")
        nextTab.keyEquivalentModifierMask = [.command, .shift]
        navMenu.addItem(nextTab)
        let prevTab = NSMenuItem(title: "Prev Tab", action: #selector(prevTabAction), keyEquivalent: "[")
        prevTab.keyEquivalentModifierMask = [.command, .shift]
        navMenu.addItem(prevTab)
        navMenuItem.submenu = navMenu
        mainMenu.addItem(navMenuItem)

        NSApp.mainMenu = mainMenu

        // Local monitor for Esc and triple-press 's' when app is focused
        localMon = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in self?.onKey(e, local: true); return e }

        // Global monitor for triple-press 's' when other apps are focused
        globalMon = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] e in self?.onKey(e, local: false) }

        // Carbon global hotkey — works from ANY app, no accessibility needed
        registerHotkey()

        toggle()

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            NSApp.setActivationPolicy(.accessory)
        }

        print("✅ ShyftBrowser running!")
        print("   Ctrl+S = toggle (instant) | sss = toggle (triple-press)")
        print("   Cmd+T = new tab | Cmd+W = close tab")
        print("   Cmd+L = URL bar | Cmd+Shift+[/] = switch tabs")
    }

    // MARK: - Carbon Global Hotkey

    var eventHandlerInstalled = false

    func savedHotkeyKeyCode() -> UInt32 {
        let val = UserDefaults.standard.integer(forKey: "hotkeyKeyCode")
        return val == 0 ? UInt32(kVK_ANSI_S) : UInt32(val)
    }

    func savedHotkeyModifiers() -> UInt32 {
        let val = UserDefaults.standard.integer(forKey: "hotkeyModifiers")
        return val == 0 ? UInt32(controlKey) : UInt32(val)
    }

    func savedHotkeyPresetIndex() -> Int {
        UserDefaults.standard.integer(forKey: "hotkeyPresetIndex") // 0 = Ctrl+S (default)
    }


    func registerHotkey() {
        globalApp = self

        // Install event handler only once
        if !eventHandlerInstalled {
            var eventType = EventTypeSpec(
                eventClass: OSType(kEventClassKeyboard),
                eventKind: UInt32(kEventHotKeyPressed)
            )
            InstallEventHandler(
                GetApplicationEventTarget(),
                { (_: EventHandlerCallRef?, _: EventRef?, _: UnsafeMutableRawPointer?) -> OSStatus in
                    DispatchQueue.main.async { globalApp?.toggle() }
                    return noErr
                },
                1,
                &eventType,
                nil,
                nil
            )
            eventHandlerInstalled = true
        }

        // Unregister previous hotkey if any
        if let ref = hotKeyRef {
            UnregisterEventHotKey(ref)
            hotKeyRef = nil
        }

        var hotKeyID = EventHotKeyID()
        hotKeyID.signature = OSType(0x53485946) // "SHYF"
        hotKeyID.id = 1

        let kc = savedHotkeyKeyCode()
        let mods = savedHotkeyModifiers()

        let status = RegisterEventHotKey(
            kc, mods, hotKeyID,
            GetApplicationEventTarget(), 0, &hotKeyRef
        )

        if status != noErr {
            print("⚠️  Failed to register hotkey (status: \(status))")
        } else {
            print("✅ Global hotkey registered (keyCode: \(kc), modifiers: \(mods))")
        }
    }

    func updateHotkey(keyCode: UInt32, modifiers: UInt32) {
        UserDefaults.standard.set(Int(keyCode), forKey: "hotkeyKeyCode")
        UserDefaults.standard.set(Int(modifiers), forKey: "hotkeyModifiers")
        registerHotkey()
    }

    // MARK: - Local/Global Key Monitor (Esc + triple-press 's')

    func onKey(_ e: NSEvent, local: Bool) {
        // Esc: if URL bar is visible, hide it first. Otherwise hide the window.
        if e.keyCode == 53 {
            if urlBarVisible {
                hideURLBar()
            } else if let w = window, w.isVisible {
                w.orderOut(nil)
            }
            return
        }

        // Only bare 's' key (no Cmd/Ctrl/Option) for triple-press
        guard e.keyCode == 1,
              e.modifierFlags.intersection(.deviceIndependentFlagsMask)
                  .subtracting([.capsLock, .numericPad, .function]).isEmpty
        else { return }

        // Skip if typing in URL bar (only for local events)
        if local, let w = window, w.isVisible,
           let fr = w.firstResponder as? NSTextView, fr.delegate is NSTextField { return }

        let now = Date()
        sTimes.append(now)
        sTimes = sTimes.filter { now.timeIntervalSince($0) < 0.7 }
        if sTimes.count >= 3 {
            sTimes.removeAll()
            DispatchQueue.main.async { [weak self] in self?.toggle() }
        }
    }

    // MARK: - Toggle

    @objc func toggle() {
        if let w = window, w.isVisible { w.orderOut(nil); return }
        if window == nil { makeWindow() }
        window?.alphaValue = opacity
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate()
        NSRunningApplication.current.activate()
    }

    // MARK: - Window

    func makeWindow() {
        let sf = NSScreen.main!.visibleFrame
        let r = NSRect(x: sf.midX - 500, y: sf.midY - 350, width: 1000, height: 700)

        let w = NSWindow(contentRect: r, styleMask: [.titled, .closable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        w.sharingType = .none
        w.level = .floating
        w.titlebarAppearsTransparent = true
        w.titleVisibility = .hidden
        w.backgroundColor = .clear
        w.isOpaque = false
        w.hasShadow = false
        w.isMovableByWindowBackground = true
        w.collectionBehavior = [.canJoinAllSpaces]

        // Style the system titlebar to match the rest of the window
        if let titlebarView = w.standardWindowButton(.closeButton)?.superview {
            let titlebarEffect = NSVisualEffectView(frame: titlebarView.bounds)
            titlebarEffect.material = .hudWindow
            titlebarEffect.blendingMode = .behindWindow
            titlebarEffect.state = .active
            titlebarEffect.autoresizingMask = [.width, .height]
            titlebarView.addSubview(titlebarEffect, positioned: .below, relativeTo: titlebarView.subviews.first)
        }

        let box = NSView(frame: NSRect(x: 0, y: 0, width: r.width, height: r.height))
        box.wantsLayer = true
        box.layer?.borderColor = NSColor.white.withAlphaComponent(0.6).cgColor
        box.layer?.borderWidth = 2.0
        box.layer?.cornerRadius = 12

        let titleBarH: CGFloat = 28
        let urlBarH: CGFloat = 44
        let tabBarH: CGFloat = 30

        let tb_toolbar = NSVisualEffectView(frame: NSRect(x: 0, y: r.height - urlBarH - titleBarH, width: r.width, height: urlBarH))
        tb_toolbar.material = .hudWindow
        tb_toolbar.blendingMode = .behindWindow
        tb_toolbar.state = .active
        tb_toolbar.wantsLayer = true
        tb_toolbar.autoresizingMask = [.width, .minYMargin]
        tb_toolbar.isHidden = true  // Start hidden
        urlBarVisible = false

        let url = NSTextField(frame: NSRect(x: 10, y: 9, width: r.width - 20, height: 26))
        url.placeholderString = "Search or enter URL..."
        url.stringValue = "https://claude.ai"
        url.bezelStyle = .roundedBezel
        url.font = .systemFont(ofSize: 13)
        url.target = self
        url.action = #selector(go(_:))
        url.autoresizingMask = [.width]
        tb_toolbar.addSubview(url)
        urlBar = url
        toolbar = tb_toolbar
        box.addSubview(tb_toolbar)

        let tabBarH_actual: CGFloat = tabBarH
        let tb = NSVisualEffectView(frame: NSRect(x: 0, y: r.height - titleBarH - tabBarH_actual, width: r.width, height: tabBarH_actual))
        tb.material = .hudWindow
        tb.blendingMode = .behindWindow
        tb.state = .active
        tb.wantsLayer = true
        tb.autoresizingMask = [.width, .minYMargin]
        box.addSubview(tb)
        tabBar = tb

        let webH = r.height - titleBarH - tabBarH
        let wc = NSView(frame: NSRect(x: 0, y: 0, width: r.width, height: webH))
        wc.autoresizingMask = [.width, .height]
        box.addSubview(wc)
        webContainer = wc

        w.contentView = box
        window = w

        addNewTab(url: resolvedHomePageURL())
    }

    func createWebView() -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        let wv = WKWebView(frame: webContainer?.bounds ?? .zero, configuration: config)
        wv.autoresizingMask = [.width, .height]
        wv.allowsBackForwardNavigationGestures = true
        wv.wantsLayer = true
        wv.layer?.cornerRadius = 8
        wv.navigationDelegate = self
        return wv
    }

    func addNewTab(url: String) {
        let wv = createWebView()
        if let u = URL(string: url) { wv.load(URLRequest(url: u)) }
        tabs.append(Tab(webView: wv, title: "New Tab"))
        activeTabIndex = tabs.count - 1
        showActiveTab()
    }

    func showActiveTab() {
        guard !tabs.isEmpty else { return }
        webContainer?.subviews.forEach { $0.removeFromSuperview() }
        let wv = tabs[activeTabIndex].webView
        wv.frame = webContainer?.bounds ?? .zero
        webContainer?.addSubview(wv)
        urlBar?.stringValue = wv.url?.absoluteString ?? ""
        rebuildTabBar()
    }

    func rebuildTabBar() {
        guard let tb = tabBar else { return }
        tb.subviews.forEach { $0.removeFromSuperview() }

        let tabW: CGFloat = min(150, (tb.bounds.width - 30) / CGFloat(max(tabs.count, 1)))
        let h: CGFloat = 24

        for (i, tab) in tabs.enumerated() {
            let x = CGFloat(i) * (tabW + 2) + 4
            let btn = NSButton(frame: NSRect(x: x, y: 3, width: tabW, height: h))
            let title = tab.title.count > 18 ? String(tab.title.prefix(18)) + "…" : tab.title
            btn.title = title
            btn.font = NSFont.systemFont(ofSize: 10)
            btn.bezelStyle = .inline
            btn.tag = i
            btn.target = self
            btn.action = #selector(switchTab(_:))

            if i == activeTabIndex {
                btn.wantsLayer = true
                btn.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.2).cgColor
                btn.layer?.cornerRadius = 4
            }
            tb.addSubview(btn)
        }

        let plusX = CGFloat(tabs.count) * (tabW + 2) + 4
        let plus = NSButton(frame: NSRect(x: plusX, y: 3, width: 24, height: h))
        plus.title = "+"
        plus.font = NSFont.systemFont(ofSize: 13, weight: .bold)
        plus.bezelStyle = .inline
        plus.target = self
        plus.action = #selector(newTabAction)
        tb.addSubview(plus)
    }

    @objc func switchTab(_ sender: NSButton) {
        activeTabIndex = sender.tag
        showActiveTab()
    }

    @objc func newTabAction() {
        let newTabURL = resolvedNewTabURL()
        addNewTab(url: newTabURL)
        if newTabURL == "about:blank" {
            showURLBar()
            urlBar?.stringValue = ""
            urlBar?.selectText(nil)
        }
    }

    @objc func closeTabAction() {
        if tabs.count <= 1 {
            // Last tab — hide the window
            if let w = window, w.isVisible { w.orderOut(nil) }
            return
        }
        tabs[activeTabIndex].webView.removeFromSuperview()
        tabs.remove(at: activeTabIndex)
        if activeTabIndex >= tabs.count { activeTabIndex = tabs.count - 1 }
        showActiveTab()
    }

    @objc func nextTabAction() {
        guard tabs.count > 1 else { return }
        activeTabIndex = (activeTabIndex + 1) % tabs.count
        showActiveTab()
    }

    @objc func prevTabAction() {
        guard tabs.count > 1 else { return }
        activeTabIndex = (activeTabIndex - 1 + tabs.count) % tabs.count
        showActiveTab()
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        if let idx = tabs.firstIndex(where: { $0.webView === webView }) {
            tabs[idx].title = webView.title ?? webView.url?.host ?? "Tab"
            if idx == activeTabIndex {
                urlBar?.stringValue = webView.url?.absoluteString ?? ""
            }
            rebuildTabBar()
        }
    }

    @objc func sliderChanged(_ sender: NSSlider) {
        opacity = CGFloat(sender.doubleValue) / 100.0
        window?.alphaValue = opacity
        settingsWindow?.alphaValue = opacity
    }

    @objc func focusURLBar() {
        window?.makeKeyAndOrderFront(nil)
        showURLBar()
        urlBar?.selectText(nil)
    }

    func showURLBar() {
        guard !urlBarVisible else { return }
        urlBarVisible = true
        toolbar?.isHidden = false
        relayout()
    }

    func hideURLBar() {
        guard urlBarVisible else { return }
        urlBarVisible = false
        toolbar?.isHidden = true
        relayout()
    }

    func relayout() {
        guard let w = window, let box = w.contentView else { return }
        let r = box.bounds
        let titleBarH: CGFloat = 28
        let urlBarH: CGFloat = urlBarVisible ? 44 : 0
        let tabBarH: CGFloat = 30

        toolbar?.frame = NSRect(x: 0, y: r.height - urlBarH - titleBarH, width: r.width, height: 44)
        tabBar?.frame = NSRect(x: 0, y: r.height - urlBarH - titleBarH - tabBarH, width: r.width, height: tabBarH)
        webContainer?.frame = NSRect(x: 0, y: 0, width: r.width, height: r.height - urlBarH - titleBarH - tabBarH)

        // Resize active webview to match
        if let wv = activeWebView {
            wv.frame = webContainer?.bounds ?? .zero
        }
    }

    // MARK: - Settings Window

    // Tag constants for settings UI
    static let opacityValueTag = 999
    static let homeCustomFieldTag = 1001
    static let newTabCustomFieldTag = 1002
    var hotkeyDisplayLabel: NSTextField?

    @objc func openSettings() {
        if let sw = settingsWindow {
            sw.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let w: CGFloat = 400
        let h: CGFloat = 500
        let sf = NSScreen.main!.visibleFrame
        let r = NSRect(x: sf.midX - w / 2, y: sf.midY - h / 2, width: w, height: h)

        let sw = NSWindow(contentRect: r, styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        sw.sharingType = .none
        sw.level = .floating
        sw.titlebarAppearsTransparent = true
        sw.titleVisibility = .hidden
        sw.backgroundColor = .clear
        sw.isOpaque = false
        sw.hasShadow = false
        sw.title = "Settings"
        sw.alphaValue = opacity

        let content = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: w, height: h))
        content.material = .hudWindow
        content.blendingMode = .behindWindow
        content.state = .active
        content.wantsLayer = true
        content.layer?.cornerRadius = 12
        content.layer?.borderColor = NSColor.white.withAlphaComponent(0.4).cgColor
        content.layer?.borderWidth = 1.5

        var y = h - 55

        // Title
        let title = NSTextField(labelWithString: "Settings")
        title.frame = NSRect(x: 20, y: y, width: w - 40, height: 24)
        title.font = .systemFont(ofSize: 18, weight: .semibold)
        title.textColor = .white
        content.addSubview(title)

        // --- Opacity Section ---
        y -= 45
        let opacityLabel = NSTextField(labelWithString: "Window Opacity")
        opacityLabel.frame = NSRect(x: 20, y: y, width: 140, height: 18)
        opacityLabel.font = .systemFont(ofSize: 13)
        opacityLabel.textColor = .secondaryLabelColor
        content.addSubview(opacityLabel)

        let opacityValue = NSTextField(labelWithString: "\(Int(opacity * 100))%")
        opacityValue.frame = NSRect(x: w - 60, y: y, width: 40, height: 18)
        opacityValue.font = .monospacedDigitSystemFont(ofSize: 13, weight: .medium)
        opacityValue.textColor = .white
        opacityValue.alignment = .right
        opacityValue.tag = App.opacityValueTag
        content.addSubview(opacityValue)

        y -= 28
        let slider = NSSlider(frame: NSRect(x: 20, y: y, width: w - 40, height: 20))
        slider.minValue = 10
        slider.maxValue = 100
        slider.doubleValue = Double(opacity * 100)
        slider.isContinuous = true
        slider.target = self
        slider.action = #selector(settingsSliderChanged(_:))
        content.addSubview(slider)

        // --- Toggle Shortcut Section ---
        y -= 40
        let hotkeyLabel = NSTextField(labelWithString: "Toggle Shortcut")
        hotkeyLabel.frame = NSRect(x: 20, y: y, width: 150, height: 18)
        hotkeyLabel.font = .systemFont(ofSize: 13, weight: .medium)
        hotkeyLabel.textColor = .white
        content.addSubview(hotkeyLabel)

        let hotkeyDisplay = NSTextField(labelWithString: "")
        hotkeyDisplay.frame = NSRect(x: w - 80, y: y, width: 60, height: 18)
        hotkeyDisplay.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        hotkeyDisplay.textColor = NSColor.white.withAlphaComponent(0.6)
        hotkeyDisplay.alignment = .right
        hotkeyDisplayLabel = hotkeyDisplay
        content.addSubview(hotkeyDisplay)

        y -= 5
        let hotkeyPopup = NSPopUpButton(frame: NSRect(x: 20, y: y - 26, width: w - 40, height: 26), pullsDown: false)
        for preset in presetHotkeys { hotkeyPopup.addItem(withTitle: preset.label) }
        hotkeyPopup.selectItem(at: savedHotkeyPresetIndex())
        hotkeyPopup.target = self
        hotkeyPopup.action = #selector(hotkeyPresetChanged(_:))
        content.addSubview(hotkeyPopup)
        y -= 26

        updateHotkeyDisplayLabel()

        // --- Home Page Section ---
        y -= 30
        let homeLabel = NSTextField(labelWithString: "Home Page")
        homeLabel.frame = NSRect(x: 20, y: y, width: w - 40, height: 18)
        homeLabel.font = .systemFont(ofSize: 13, weight: .medium)
        homeLabel.textColor = .white
        content.addSubview(homeLabel)

        y -= 5
        let homeOptions: [PageOption] = [.claude, .chatgpt, .google, .custom]
        let homePopup = NSPopUpButton(frame: NSRect(x: 20, y: y - 26, width: w - 40, height: 26), pullsDown: false)
        for opt in homeOptions { homePopup.addItem(withTitle: opt.label) }
        // Select current
        if let idx = homeOptions.firstIndex(of: homePage) { homePopup.selectItem(at: idx) }
        homePopup.target = self
        homePopup.action = #selector(homePageChanged(_:))
        homePopup.tag = 2000
        content.addSubview(homePopup)
        y -= 26

        y -= 6
        let homeCustomField = NSTextField(frame: NSRect(x: 20, y: y - 26, width: w - 40, height: 26))
        homeCustomField.placeholderString = "Enter custom URL..."
        homeCustomField.stringValue = homePageCustomURL
        homeCustomField.bezelStyle = .roundedBezel
        homeCustomField.font = .systemFont(ofSize: 13)
        homeCustomField.tag = App.homeCustomFieldTag
        homeCustomField.target = self
        homeCustomField.action = #selector(homeCustomURLChanged(_:))
        homeCustomField.isHidden = homePage != .custom
        content.addSubview(homeCustomField)
        y -= (homePage == .custom ? 32 : 0)

        // --- New Tab Page Section ---
        y -= 30
        let newTabLabel = NSTextField(labelWithString: "New Tab Page")
        newTabLabel.frame = NSRect(x: 20, y: y, width: w - 40, height: 18)
        newTabLabel.font = .systemFont(ofSize: 13, weight: .medium)
        newTabLabel.textColor = .white
        content.addSubview(newTabLabel)

        y -= 5
        let newTabOptions: [PageOption] = [.blank, .claude, .chatgpt, .google, .custom]
        let newTabPopup = NSPopUpButton(frame: NSRect(x: 20, y: y - 26, width: w - 40, height: 26), pullsDown: false)
        for opt in newTabOptions { newTabPopup.addItem(withTitle: opt.label) }
        if let idx = newTabOptions.firstIndex(of: newTabPage) { newTabPopup.selectItem(at: idx) }
        newTabPopup.target = self
        newTabPopup.action = #selector(newTabPageChanged(_:))
        newTabPopup.tag = 3000
        content.addSubview(newTabPopup)
        y -= 26

        y -= 6
        let newTabCustomField = NSTextField(frame: NSRect(x: 20, y: y - 26, width: w - 40, height: 26))
        newTabCustomField.placeholderString = "Enter custom URL..."
        newTabCustomField.stringValue = newTabPageCustomURL
        newTabCustomField.bezelStyle = .roundedBezel
        newTabCustomField.font = .systemFont(ofSize: 13)
        newTabCustomField.tag = App.newTabCustomFieldTag
        newTabCustomField.target = self
        newTabCustomField.action = #selector(newTabCustomURLChanged(_:))
        newTabCustomField.isHidden = newTabPage != .custom
        content.addSubview(newTabCustomField)

        // Info label
        let info = NSTextField(labelWithString: "⌃S or sss to toggle • Invisible in screen share")
        info.frame = NSRect(x: 20, y: 15, width: w - 40, height: 16)
        info.font = .systemFont(ofSize: 10)
        info.textColor = NSColor.white.withAlphaComponent(0.4)
        content.addSubview(info)

        sw.contentView = content
        sw.delegate = self
        sw.isReleasedWhenClosed = false
        settingsWindow = sw

        sw.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        if let closingWindow = notification.object as? NSWindow, closingWindow === settingsWindow {
            settingsWindow = nil
            hotkeyDisplayLabel = nil
        }
    }

    @objc func settingsSliderChanged(_ sender: NSSlider) {
        opacity = CGFloat(sender.doubleValue) / 100.0
        window?.alphaValue = opacity
        settingsWindow?.alphaValue = opacity

        if let content = settingsWindow?.contentView {
            for subview in content.subviews where subview.tag == App.opacityValueTag {
                if let label = subview as? NSTextField {
                    label.stringValue = "\(Int(sender.doubleValue))%"
                }
            }
        }
    }

    @objc func homePageChanged(_ sender: NSPopUpButton) {
        let options: [PageOption] = [.claude, .chatgpt, .google, .custom]
        let selected = options[sender.indexOfSelectedItem]
        UserDefaults.standard.set(selected.rawValue, forKey: "homePage")

        // Show/hide custom URL field
        if let content = settingsWindow?.contentView {
            for subview in content.subviews where subview.tag == App.homeCustomFieldTag {
                subview.isHidden = selected != .custom
            }
        }
    }

    @objc func homeCustomURLChanged(_ sender: NSTextField) {
        var url = sender.stringValue.trimmingCharacters(in: .whitespaces)
        if !url.isEmpty && !url.contains("://") { url = "https://\(url)" }
        UserDefaults.standard.set(url, forKey: "homePageCustomURL")
    }

    @objc func newTabPageChanged(_ sender: NSPopUpButton) {
        let options: [PageOption] = [.blank, .claude, .chatgpt, .google, .custom]
        let selected = options[sender.indexOfSelectedItem]
        UserDefaults.standard.set(selected.rawValue, forKey: "newTabPage")

        if let content = settingsWindow?.contentView {
            for subview in content.subviews where subview.tag == App.newTabCustomFieldTag {
                subview.isHidden = selected != .custom
            }
        }
    }

    @objc func newTabCustomURLChanged(_ sender: NSTextField) {
        var url = sender.stringValue.trimmingCharacters(in: .whitespaces)
        if !url.isEmpty && !url.contains("://") { url = "https://\(url)" }
        UserDefaults.standard.set(url, forKey: "newTabPageCustomURL")
    }

    // MARK: - Hotkey Settings Actions

    func updateHotkeyDisplayLabel() {
        guard let label = hotkeyDisplayLabel else { return }
        let idx = savedHotkeyPresetIndex()
        if idx < presetHotkeys.count {
            label.stringValue = presetHotkeys[idx].displayString
        }
    }

    @objc func hotkeyPresetChanged(_ sender: NSPopUpButton) {
        let idx = sender.indexOfSelectedItem
        guard idx < presetHotkeys.count else { return }
        let preset = presetHotkeys[idx]
        UserDefaults.standard.set(idx, forKey: "hotkeyPresetIndex")
        updateHotkey(keyCode: preset.keyCode, modifiers: preset.carbonModifiers)
        updateHotkeyDisplayLabel()
    }

    @objc func go(_ sender: NSTextField) {
        var t = sender.stringValue.trimmingCharacters(in: .whitespaces)
        if !t.contains("://") {
            t = t.contains(".") && !t.contains(" ") ? "https://\(t)" : "https://claude.ai/search?q=\(t.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? t)"
        }
        if let u = URL(string: t) { activeWebView?.load(URLRequest(url: u)) }
        hideURLBar()
    }
}

let app = NSApplication.shared
let delegate = App()
app.delegate = delegate
app.run()
