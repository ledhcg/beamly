// Mac2TV: app thanh menu phát màn hình Mac lên Android TV.
import AppKit
import ServiceManagement

/// Ghi log ra ~/Library/Logs/Mac2TV.log để chẩn đoán.
let logURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Mac2TV.log")
func log(_ msg: String) {
    let line = "\(ISO8601DateFormatter().string(from: Date())) \(msg)\n"
    if let h = try? FileHandle(forWritingTo: logURL) {
        h.seekToEndOfFile(); h.write(line.data(using: .utf8)!); try? h.close()
    } else {
        try? line.write(to: logURL, atomically: true, encoding: .utf8)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private let menu = NSMenu()
    private let browser = TVBrowser()
    private var browseError: String?
    private var displays: [DisplayInfo] = []

    private var session: StreamSession?
    private var sessionID = UUID()
    private var activeTV: String?
    private var status = "Chưa phát"
    private var isStreaming = false
    private var pendingConnect: String?

    // MARK: Cài đặt (lưu trong UserDefaults)

    private let defaults = UserDefaults.standard
    private var width: Int {
        get { defaults.object(forKey: "width") as? Int ?? 1920 }
        set { defaults.set(newValue, forKey: "width") }
    }
    private var fps: Int {
        get { defaults.object(forKey: "fps") as? Int ?? 60 }
        set { defaults.set(newValue, forKey: "fps") }
    }
    private var audio: Bool {
        get { defaults.object(forKey: "audio") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "audio") }
    }
    /// Tạm tắt loa Mac khi phát để âm thanh chỉ phát ở TV.
    private var muteMac: Bool {
        get { defaults.object(forKey: "muteMac") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "muteMac") }
    }
    private var display: Int {
        get { defaults.object(forKey: "display") as? Int ?? 0 }
        set { defaults.set(newValue, forKey: "display") }
    }

    private let qualities: [(width: Int, label: String)] = [(1280, "720p"), (1920, "1080p"), (2560, "1440p")]

    private func bitrate() -> Int {
        let base: Double = width <= 1280 ? 6 : (width <= 1920 ? 12 : 20)
        return Int(base * (fps <= 30 ? 0.6 : 1.0) * 1_000_000)
    }

    // MARK: Vòng đời

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        menu.delegate = self
        menu.autoenablesItems = false
        statusItem.menu = menu
        updateIcon()

        log("Khởi động, args=\(CommandLine.arguments.dropFirst())")
        // Lần trước bị tắt đột ngột khi loa Mac đang bị tắt tiếng: bật lại.
        SystemAudioMuter.recoverIfNeeded()
        if let i = CommandLine.arguments.firstIndex(of: "--connect"), i + 1 < CommandLine.arguments.count {
            pendingConnect = CommandLine.arguments[i + 1]
        }
        browser.onChange = { [weak self] tvs in
            log("Danh sách TV: \(tvs.map(\.name))")
            if let self, let name = self.pendingConnect, tvs.contains(where: { $0.name == name }) {
                self.pendingConnect = nil
                self.startStreaming(to: name)
            }
            self?.browseError = nil
            self?.rebuildMenu()
        }
        browser.onError = { [weak self] msg in
            log("Lỗi dò TV: \(msg)")
            self?.browseError = msg
            self?.rebuildMenu()
        }
        browser.start()
        refreshDisplays()
        rebuildMenu()
    }

    func applicationWillTerminate(_ notification: Notification) {
        session?.stop()
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        rebuildMenu()
    }

    private func refreshDisplays() {
        Task { @MainActor in
            if let list = try? await listDisplays() {
                displays = list
                if display >= list.count { display = 0 }
                rebuildMenu()
            }
        }
    }

    private func updateIcon() {
        let name = isStreaming ? "tv.fill" : "tv"
        let img = NSImage(systemSymbolName: name, accessibilityDescription: "Mac2TV")
        img?.isTemplate = true
        statusItem.button?.image = img
        statusItem.button?.toolTip = "Mac2TV — \(status)"
    }

    // MARK: Menu

    private func item(_ title: String, _ action: Selector?, key: String = "", state: Bool = false,
                      enabled: Bool = true, tag: Int = 0) -> NSMenuItem {
        let it = NSMenuItem(title: title, action: action, keyEquivalent: key)
        it.target = self
        it.state = state ? .on : .off
        it.isEnabled = enabled
        it.tag = tag
        return it
    }

    private func rebuildMenu() {
        menu.removeAllItems()

        menu.addItem(item(status, nil, enabled: false))
        if session != nil {
            menu.addItem(item("Dừng phát", #selector(stopStreaming), key: "s"))
        }

        menu.addItem(.separator())
        menu.addItem(NSMenuItem.sectionHeader(title: "Phát tới TV"))
        if let browseError {
            menu.addItem(item(browseError, nil, enabled: false))
        } else if browser.tvs.isEmpty {
            menu.addItem(item("Không thấy TV — hãy mở app Mac2TV trên TV", nil, enabled: false))
        }
        for tv in browser.tvs {
            let it = item(tv.name, #selector(selectTV(_:)), state: session != nil && activeTV == tv.name)
            it.representedObject = tv.name
            it.image = NSImage(systemSymbolName: "tv", accessibilityDescription: nil)
            menu.addItem(it)
        }

        menu.addItem(.separator())

        let q = NSMenu()
        for (i, qa) in qualities.enumerated() {
            q.addItem(item(qa.label, #selector(setQuality(_:)), state: width == qa.width, tag: i))
        }
        let qItem = item("Chất lượng", nil); qItem.submenu = q; menu.addItem(qItem)

        let f = NSMenu()
        for v in [30, 60] { f.addItem(item("\(v) fps", #selector(setFPS(_:)), state: fps == v, tag: v)) }
        let fItem = item("Khung hình", nil); fItem.submenu = f; menu.addItem(fItem)

        if displays.count > 1 {
            let d = NSMenu()
            for di in displays {
                d.addItem(item("\(di.name) (\(di.width)×\(di.height))", #selector(setDisplay(_:)),
                               state: display == di.index, tag: di.index))
            }
            let dItem = item("Màn hình", nil); dItem.submenu = d; menu.addItem(dItem)
        }

        menu.addItem(item("Truyền âm thanh", #selector(toggleAudio), state: audio))
        let mute = item("Chỉ phát tiếng ở TV (tắt loa Mac)", #selector(toggleMuteMac), state: audio && muteMac, enabled: audio)
        mute.indentationLevel = 1
        menu.addItem(mute)

        menu.addItem(.separator())
        menu.addItem(item("Mở cùng macOS", #selector(toggleLoginItem),
                          state: SMAppService.mainApp.status == .enabled))
        menu.addItem(.separator())
        menu.addItem(item("Thoát Mac2TV", #selector(quit), key: "q"))
    }

    // MARK: Hành động

    @objc private func selectTV(_ sender: NSMenuItem) {
        log("Bấm menu TV: \(sender.representedObject ?? "nil")")
        guard let name = sender.representedObject as? String else { return }
        if session != nil && activeTV == name {
            stopStreaming()
        } else {
            startStreaming(to: name)
        }
    }

    private func startStreaming(to name: String) {
        log("Bắt đầu phát tới \(name)")
        guard let tv = browser.tvs.first(where: { $0.name == name }) else {
            log("Không thấy TV \(name) trong \(browser.tvs.map(\.name))")
            status = "Không thấy \(name)"
            rebuildMenu()
            return
        }
        session?.stop()

        var o = StreamOptions()
        o.width = width
        o.fps = fps
        o.bitrate = bitrate()
        o.display = display
        o.audio = audio
        o.muteMacOutput = muteMac

        let id = UUID()
        sessionID = id
        activeTV = name
        isStreaming = false
        status = "Đang kết nối tới \(name)…"
        session = StreamSession(endpoint: tv.endpoint, options: o) { [weak self] event in
            guard let self, self.sessionID == id else { return }   // bỏ qua sự kiện của phiên cũ
            self.handle(event, tvName: name)
        }
        session?.start()
        updateIcon()
        rebuildMenu()
    }

    private func handle(_ event: StreamEvent, tvName: String) {
        log("Sự kiện: \(event)")
        switch event {
        case .connected:
            status = "Đã kết nối \(tvName), đang khởi động…"
        case .streaming:
            isStreaming = true
            status = "Đang phát tới \(tvName)"
        case .stats(let f, _):
            status = String(format: "Đang phát tới %@ · %.0f fps", tvName, f)
        case .stopped(let reason):
            session = nil
            isStreaming = false
            switch reason {
            case .user:
                status = "Chưa phát"
            case .permission:
                status = "Cần quyền ghi màn hình"
                showPermissionAlert()
            case .error(let msg):
                status = "Đã dừng: \(msg)"
            }
        }
        updateIcon()
        rebuildMenu()
    }

    @objc private func stopStreaming() {
        session?.stop()
    }

    /// Đổi cài đặt khi đang phát thì phát lại với cài đặt mới.
    private func restartIfStreaming() {
        if session != nil, let name = activeTV { startStreaming(to: name) } else { rebuildMenu() }
    }

    @objc private func setQuality(_ sender: NSMenuItem) { width = qualities[sender.tag].width; restartIfStreaming() }
    @objc private func setFPS(_ sender: NSMenuItem) { fps = sender.tag; restartIfStreaming() }
    @objc private func setDisplay(_ sender: NSMenuItem) { display = sender.tag; restartIfStreaming() }
    @objc private func toggleAudio() { audio.toggle(); restartIfStreaming() }
    @objc private func toggleMuteMac() { muteMac.toggle(); restartIfStreaming() }

    @objc private func toggleLoginItem() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            NSApp.activate(ignoringOtherApps: true)
            let a = NSAlert()
            a.messageText = "Không thay đổi được mục mở cùng macOS"
            a.informativeText = error.localizedDescription
            a.runModal()
        }
        rebuildMenu()
    }

    @objc private func quit() {
        session?.stop()
        // Chờ chút để kịp gửi gói bye cho TV.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { NSApp.terminate(nil) }
    }

    private func showPermissionAlert() {
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.messageText = "Mac2TV cần quyền ghi màn hình"
        a.informativeText = "Mở System Settings › Privacy & Security › Screen & System Audio Recording, bật Mac2TV, rồi mở lại app."
        a.addButton(withTitle: "Mở System Settings")
        a.addButton(withTitle: "Để sau")
        if a.runModal() == .alertFirstButtonReturn,
           let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
