import AppKit
import BeamlyKit
import ServiceManagement

/// Menu bar UI: lists TVs, starts/stops streaming and exposes the settings.
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem?
    private let menu = NSMenu()
    private let browser = TVBrowser()
    private var browseError: String?
    private var displays: [DisplayInfo] = []
    private let settings = Settings()

    private var session: StreamSession?
    /// Identifies the current session so events from a replaced session are ignored.
    private var sessionID = UUID()
    private var activeTV: String?
    private var status = L("status.idle")
    private var isStreaming = false
    /// `--connect NAME`: start streaming to NAME as soon as it is discovered (used for automation and testing).
    private var pendingConnect: String?
    /// True while the pairing-code alert is on screen, so it can be dismissed if the session ends.
    private var pairingAlertVisible = false

    // MARK: Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem = item
        menu.delegate = self
        menu.autoenablesItems = false
        item.menu = menu
        updateIcon()

        DebugLog.write("Launched with arguments \(CommandLine.arguments.dropFirst())")
        LegacyMuteRecovery.run()
        if let index = CommandLine.arguments.firstIndex(of: "--connect"), index + 1 < CommandLine.arguments.count {
            pendingConnect = CommandLine.arguments[index + 1]
        }

        browser.onChange = { [weak self] tvs in
            guard let self else { return }
            DebugLog.write("TVs: \(tvs.map(\.name))")
            if let name = pendingConnect, tvs.contains(where: { $0.name == name }) {
                pendingConnect = nil
                startStreaming(to: name)
            }
            browseError = nil
            rebuildMenu()
        }
        browser.onError = { [weak self] message in
            DebugLog.write("Browse error: \(message)")
            self?.browseError = message
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
            guard let list = try? await listDisplays() else { return }
            displays = list
            if settings.display >= list.count { settings.display = 0 }
            rebuildMenu()
        }
    }

    private func updateIcon() {
        let image = NSImage(systemSymbolName: isStreaming ? "tv.fill" : "tv", accessibilityDescription: "Beamly")
        image?.isTemplate = true
        statusItem?.button?.image = image
        statusItem?.button?.toolTip = "Beamly — \(status)"
    }

    // MARK: Menu

    private func item(
        _ title: String, _ action: Selector?, key: String = "", checked: Bool = false, enabled: Bool = true,
        tag: Int = 0
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        item.state = checked ? .on : .off
        item.isEnabled = enabled
        item.tag = tag
        return item
    }

    private func submenu(_ title: String, _ items: [NSMenuItem], enabled: Bool = true) -> NSMenuItem {
        let parent = item(title, nil, enabled: enabled)
        let menu = NSMenu()
        items.forEach(menu.addItem)
        parent.submenu = menu
        return parent
    }

    private func rebuildMenu() {
        menu.removeAllItems()

        menu.addItem(item(status, nil, enabled: false))
        if session != nil {
            menu.addItem(item(L("menu.stop"), #selector(stopStreaming), key: "s"))
        }

        menu.addItem(.separator())
        menu.addItem(NSMenuItem.sectionHeader(title: L("menu.section.tvs")))
        if let browseError {
            menu.addItem(item(browseError, nil, enabled: false))
        } else if browser.tvs.isEmpty {
            menu.addItem(item(L("menu.noTV"), nil, enabled: false))
        }
        for tv in browser.tvs {
            let tvItem = item(tv.name, #selector(selectTV(_:)), checked: session != nil && activeTV == tv.name)
            tvItem.representedObject = tv.name
            tvItem.image = NSImage(systemSymbolName: "tv", accessibilityDescription: nil)
            menu.addItem(tvItem)
        }

        menu.addItem(.separator())
        menu.addItem(
            submenu(
                L("menu.quality"),
                Settings.qualities.enumerated().map { index, quality in
                    item(quality.label, #selector(setQuality(_:)), checked: settings.width == quality.width, tag: index)
                }))
        menu.addItem(
            submenu(
                L("menu.frameRate"),
                Settings.frameRates.map { fps in
                    item("\(fps) fps", #selector(setFrameRate(_:)), checked: settings.fps == fps, tag: fps)
                }))
        if displays.count > 1 {
            menu.addItem(
                submenu(
                    L("menu.display"),
                    displays.map { display in
                        item(
                            "\(display.name) (\(display.width)×\(display.height))", #selector(setDisplay(_:)),
                            checked: settings.display == display.index, tag: display.index)
                    }))
        }

        menu.addItem(item(L("menu.audio"), #selector(toggleAudio), checked: settings.audio))
        let tvOnly = item(
            L("menu.tvOnly"), #selector(toggleAudioOnTVOnly), checked: settings.audio && settings.audioOnTVOnly,
            enabled: settings.audio)
        tvOnly.indentationLevel = 1
        menu.addItem(tvOnly)

        menu.addItem(.separator())
        menu.addItem(
            item(L("menu.forgetTVs"), #selector(forgetPairedTVs), enabled: !TrustStore.shared.pairedTVs.isEmpty))
        menu.addItem(
            item(
                L("menu.launchAtLogin"), #selector(toggleLaunchAtLogin),
                checked: SMAppService.mainApp.status == .enabled))
        menu.addItem(.separator())
        menu.addItem(item(L("menu.quit"), #selector(quit), key: "q"))
    }

    // MARK: Actions

    @objc private func selectTV(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        DebugLog.write("Selected TV \(name)")
        if session != nil && activeTV == name {
            stopStreaming()
        } else {
            startStreaming(to: name)
        }
    }

    private func startStreaming(to name: String) {
        guard let tv = browser.tvs.first(where: { $0.name == name }) else {
            status = L("status.notFound", name)
            rebuildMenu()
            return
        }
        session?.stop()

        var options = StreamOptions()
        options.width = settings.width
        options.fps = settings.fps
        options.bitrate = settings.bitrate
        options.display = settings.display
        options.audio = settings.audio
        options.muteMacOutput = settings.audioOnTVOnly

        let id = UUID()
        sessionID = id
        activeTV = name
        isStreaming = false
        status = L("status.connecting", name)
        session = StreamSession(endpoint: tv.endpoint, options: options) { [weak self] event in
            guard let self, self.sessionID == id else { return }
            self.handle(event, tvName: name)
        }
        session?.start()
        updateIcon()
        rebuildMenu()
    }

    private func handle(_ event: StreamEvent, tvName: String) {
        DebugLog.write("Event: \(event)")
        if pairingAlertVisible {
            switch event {
            case .streaming, .stopped: NSApp.abortModal()
            default: break
            }
        }
        switch event {
        case .pairing(let code, let pairingTVName, let respond):
            status = L("status.pairing", pairingTVName)
            updateIcon()
            rebuildMenu()
            showPairingAlert(code: code, tvName: pairingTVName, respond: respond)
            return
        case .connected:
            status = L("status.connected", tvName)
        case .streaming:
            isStreaming = true
            status = L("status.streaming", tvName)
        case .stats(let fps, _):
            status = L("status.streamingFps", tvName, fps)
        case .stopped(let reason):
            session = nil
            isStreaming = false
            switch reason {
            case .user:
                status = L("status.idle")
            case .permission:
                status = L("status.permission")
                showPermissionAlert()
            case .error(let message):
                status = L("status.stopped", message)
            }
        }
        updateIcon()
        rebuildMenu()
    }

    @objc private func stopStreaming() {
        session?.stop()
    }

    /// Settings changed while streaming: restart with the new settings.
    private func restartIfStreaming() {
        if session != nil, let name = activeTV { startStreaming(to: name) } else { rebuildMenu() }
    }

    @objc private func setQuality(_ sender: NSMenuItem) {
        settings.width = Settings.qualities[sender.tag].width
        restartIfStreaming()
    }

    @objc private func setFrameRate(_ sender: NSMenuItem) {
        settings.fps = sender.tag
        restartIfStreaming()
    }

    @objc private func setDisplay(_ sender: NSMenuItem) {
        settings.display = sender.tag
        restartIfStreaming()
    }

    @objc private func toggleAudio() {
        settings.audio.toggle()
        restartIfStreaming()
    }

    @objc private func toggleAudioOnTVOnly() {
        settings.audioOnTVOnly.toggle()
        restartIfStreaming()
    }

    /// Asks the user to compare the code with the one on the TV. Runs modally on the main thread; the alert is
    /// aborted if the session ends meanwhile (for example, when the TV declines).
    private func showPairingAlert(code: String, tvName: String, respond: @escaping (Bool) -> Void) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = L("alert.pairing.title", tvName)
        alert.informativeText = L("alert.pairing.body", code)
        alert.addButton(withTitle: L("alert.pairing.confirm"))
        alert.addButton(withTitle: L("alert.pairing.cancel"))
        pairingAlertVisible = true
        let response = alert.runModal()
        pairingAlertVisible = false
        switch response {
        case .alertFirstButtonReturn: respond(true)
        case .alertSecondButtonReturn: respond(false)
        default: break  // aborted: the session already ended
        }
    }

    @objc private func forgetPairedTVs() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = L("alert.forget.title")
        alert.informativeText = L("alert.forget.body")
        alert.addButton(withTitle: L("alert.forget.confirm"))
        alert.addButton(withTitle: L("alert.pairing.cancel"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            try TrustStore.shared.forgetAllTVs()
        } catch {
            status = L("status.stopped", error.localizedDescription)
        }
        rebuildMenu()
    }

    @objc private func toggleLaunchAtLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            NSApp.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            alert.messageText = L("alert.loginItem.title")
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
        rebuildMenu()
    }

    @objc private func quit() {
        session?.stop()
        // Give the session a moment to send BYE to the TV.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { NSApp.terminate(nil) }
    }

    private func showPermissionAlert() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = L("alert.permission.title")
        alert.informativeText = L("alert.permission.body")
        alert.addButton(withTitle: L("alert.permission.open"))
        alert.addButton(withTitle: L("alert.permission.later"))
        if alert.runModal() == .alertFirstButtonReturn,
            let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
        {
            NSWorkspace.shared.open(url)
        }
    }
}
