import Cocoa
import WebKit
import CoreGraphics

// Global reference for CGEvent callback
var globalApp: App?

struct Tab {
    let webView: WKWebView
    var title: String = "New Tab"
}

class App: NSObject, NSApplicationDelegate, WKNavigationDelegate {
    var statusItem: NSStatusItem!
    var window: NSWindow?
    var urlBar: NSTextField?
    var sTimes: [Date] = []
    var globalMon: Any?
    var localMon: Any?
    var eventTap: CFMachPort?
    var opacity: CGFloat = 0.55

    var tabs: [Tab] = []
    var activeTabIndex: Int = 0
    var tabBar: NSView?
    var webContainer: NSView?

    var activeWebView: WKWebView? { tabs.isEmpty ? nil : tabs[activeTabIndex].webView }

    func applicationDidFinishLaunching(_ n: Notification) {
        // Prompt for Accessibility permission (needed for global key listening)
        let trusted = AXIsProcessTrustedWithOptions(
            [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
        )
        if !trusted {
            print("⚠️  Please grant Accessibility permission and restart the app!")
        }

        NSApp.setActivationPolicy(.regular)

        statusItem = NSStatusBar.system.statusItem(withLength: 30)
        statusItem.button?.title = "•"
        let m = NSMenu()
        let opacityLabel = NSMenuItem(title: "Opacity", action: nil, keyEquivalent: "")
        opacityLabel.isEnabled = false
        m.addItem(opacityLabel)
        for pct in stride(from: 10, through: 100, by: 10) {
            let item = NSMenuItem(title: "\(pct)%", action: #selector(setOpacity(_:)), keyEquivalent: "")
            item.tag = pct
            if pct == 55 { item.state = .on }
            m.addItem(item)
        }
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

        // Local monitor for when app is focused
        localMon = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in self?.onKey(e, local: true); return e }

        // Global hotkey via CGEvent tap — works even without Accessibility in some cases
        setupGlobalHotkey()

        // Also try NSEvent global monitor as backup
        globalMon = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] e in self?.onKey(e, local: false) }

        toggle()

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            NSApp.setActivationPolicy(.accessory)
        }

        print("✅ StealthBrowser running!")
        print("   Ctrl+S = toggle (instant) | sss = toggle (triple-press)")
        print("   Cmd+T = new tab | Cmd+W = close tab")
        print("   Cmd+L = URL bar | Cmd+Shift+[/] = switch tabs")
        print("")
        print("⚠️  If hotkeys don't work when other apps are focused:")
        print("   System Settings → Privacy & Security → Accessibility")
        print("   Add StealthBrowser.app (or Terminal if running from terminal)")
    }

    func onKey(_ e: NSEvent, local: Bool) {
        // Esc hides only if window is showing
        if e.keyCode == 53 {
            if let w = window, w.isVisible { w.orderOut(nil) }
            return
        }

        // Ctrl+S → instant toggle (keyCode 1 = 's')
        if e.keyCode == 1,
           e.modifierFlags.contains(.control),
           !e.modifierFlags.contains(.command),
           !e.modifierFlags.contains(.option) {
            DispatchQueue.main.async { [weak self] in self?.toggle() }
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

    func setupGlobalHotkey() {
        globalApp = self

        let eventMask: CGEventMask = (1 << CGEventType.keyDown.rawValue)

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: eventMask,
            callback: { (proxy, type, event, refcon) -> Unmanaged<CGEvent>? in
                if type == .keyDown {
                    let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
                    // 's' key = keycode 1
                    if keyCode == 1 {
                        let flags = event.flags
                        // Ctrl+S → instant toggle
                        if flags.contains(.maskControl) && !flags.contains(.maskCommand) && !flags.contains(.maskAlternate) {
                            DispatchQueue.main.async {
                                globalApp?.toggle()
                            }
                        }
                        // Bare 's' (no modifiers) → triple-press detection
                        let hasModifiers = flags.contains(.maskCommand) || flags.contains(.maskControl) || flags.contains(.maskAlternate)
                        if !hasModifiers {
                            DispatchQueue.main.async {
                                globalApp?.recordSPress()
                            }
                        }
                    }
                }
                return Unmanaged.passRetained(event)
            },
            userInfo: nil
        ) else {
            print("⚠️  Could not create event tap. Grant Accessibility permission!")
            print("   System Settings → Privacy & Security → Accessibility")
            return
        }

        eventTap = tap
        let runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    func recordSPress() {
        let now = Date()
        sTimes.append(now)
        sTimes = sTimes.filter { now.timeIntervalSince($0) < 0.7 }
        if sTimes.count >= 3 {
            sTimes.removeAll()
            toggle()
        }
    }

    @objc func toggle() {
        if let w = window, w.isVisible { w.orderOut(nil); return }
        if window == nil { makeWindow() }
        window?.alphaValue = opacity
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

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

        let box = NSView(frame: NSRect(x: 0, y: 0, width: r.width, height: r.height))
        box.wantsLayer = true
        box.layer?.borderColor = NSColor.white.withAlphaComponent(0.6).cgColor
        box.layer?.borderWidth = 2.0
        box.layer?.cornerRadius = 12

        let titleBarH: CGFloat = 28
        let urlBarH: CGFloat = 44
        let tabBarH: CGFloat = 30

        let toolbar = NSVisualEffectView(frame: NSRect(x: 0, y: r.height - urlBarH - titleBarH, width: r.width, height: urlBarH))
        toolbar.material = .hudWindow
        toolbar.blendingMode = .behindWindow
        toolbar.state = .active
        toolbar.wantsLayer = true
        toolbar.autoresizingMask = [.width, .minYMargin]

        let url = NSTextField(frame: NSRect(x: 10, y: 9, width: r.width - 20, height: 26))
        url.placeholderString = "Search or enter URL..."
        url.stringValue = "https://claude.ai"
        url.bezelStyle = .roundedBezel
        url.font = .systemFont(ofSize: 13)
        url.target = self
        url.action = #selector(go(_:))
        url.autoresizingMask = [.width]
        toolbar.addSubview(url)
        urlBar = url
        box.addSubview(toolbar)

        let tb = NSVisualEffectView(frame: NSRect(x: 0, y: r.height - urlBarH - titleBarH - tabBarH, width: r.width, height: tabBarH))
        tb.material = .hudWindow
        tb.blendingMode = .behindWindow
        tb.state = .active
        tb.wantsLayer = true
        tb.autoresizingMask = [.width, .minYMargin]
        box.addSubview(tb)
        tabBar = tb

        let webH = r.height - urlBarH - titleBarH - tabBarH
        let wc = NSView(frame: NSRect(x: 0, y: 0, width: r.width, height: webH))
        wc.autoresizingMask = [.width, .height]
        box.addSubview(wc)
        webContainer = wc

        w.contentView = box
        window = w

        addNewTab(url: "https://claude.ai")
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
        addNewTab(url: "about:blank")
        focusURLBar()
    }

    @objc func closeTabAction() {
        guard tabs.count > 1 else { return }
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

    @objc func setOpacity(_ sender: NSMenuItem) {
        opacity = CGFloat(sender.tag) / 100.0
        window?.alphaValue = opacity
        if let menu = statusItem.menu {
            for item in menu.items {
                if item.action == #selector(setOpacity(_:)) {
                    item.state = (item.tag == sender.tag) ? .on : .off
                }
            }
        }
    }

    @objc func focusURLBar() {
        window?.makeKeyAndOrderFront(nil)
        urlBar?.selectText(nil)
    }

    @objc func go(_ sender: NSTextField) {
        var t = sender.stringValue.trimmingCharacters(in: .whitespaces)
        if !t.contains("://") {
            t = t.contains(".") && !t.contains(" ") ? "https://\(t)" : "https://claude.ai/search?q=\(t.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? t)"
        }
        if let u = URL(string: t) { activeWebView?.load(URLRequest(url: u)) }
    }
}

let app = NSApplication.shared
let delegate = App()
app.delegate = delegate
app.run()
