import AppKit
import IOKit
import ServiceManagement

// Lid Awake: menu bar toggle that keeps the Mac running with the lid closed.
// Turning on asks for the admin password once and starts watchdog.sh as root.
// Turning off just drops a flag file the watchdog is watching.

let minBatteryPercent = 15

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private var caffeinate: Process?
    private var deadline: Date?
    private var isOn = false
    private var expected: Bool?
    private var expectedUntil = Date.distantPast
    private var renderedKey = ""
    private var pollTimer: Timer?
    private var lidTimer: Timer?
    private var lastLidClosed = false

    // Lock the Mac the moment the lid closes, so opening it needs the password.
    private var lockOnClose: Bool {
        get { UserDefaults.standard.object(forKey: "lockOnClose") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "lockOnClose") }
    }

    // Mute sound while the lid is closed; restore it when the lid opens.
    private var muteOnClose: Bool {
        get { UserDefaults.standard.object(forKey: "muteOnClose") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "muteOnClose") }
    }
    private var mutedByLid = false
    private var helpWindow: NSWindow?

    // Master Power Mode: with the lid closed, show a virtual monitor so computer use
    // keeps working, and lock when the lid opens (a locked Mac blocks computer use).
    private var masterMode: Bool {
        get { UserDefaults.standard.bool(forKey: "masterMode") }
        set { UserDefaults.standard.set(newValue, forKey: "masterMode") }
    }
    private var virtualDisplay: CGVirtualDisplay?
    private let virtualVendorID: UInt32 = 0x4C41 // "LA"

    private let supportDir: URL = {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/LidAwake")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()
    private var flagURL: URL { supportDir.appendingPathComponent("turn-off") }

    func applicationDidFinishLaunching(_ notification: Notification) {
        refreshState()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            self?.refreshState()
        }
        // open "/Applications/Lid Awake.app" --args --show-help
        if CommandLine.arguments.contains("--show-help") { showHelp() }
        // Recover from a quit or crash that happened while the lid was closed.
        if !lidClosed() { restoreBuiltInScreen() }
        lastLidClosed = lidClosed()
        // Fast poll so the lock lands well under a second after the lid opens.
        lidTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            self?.checkLid()
        }
    }

    // MARK: Lid lock

    private func lidClosed() -> Bool {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard service != 0 else { return false }
        defer { IOObjectRelease(service) }
        let value = IORegistryEntryCreateCFProperty(service, "AppleClamshellState" as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue()
        return value as? Bool ?? false
    }

    // With a real external monitor attached, closing the lid is normal desk use, so skip
    // the lid actions. Our own virtual monitor doesn't count.
    private func externalDisplayAttached() -> Bool {
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        var count: UInt32 = 0
        CGGetOnlineDisplayList(16, &ids, &count)
        return ids.prefix(Int(count)).contains {
            CGDisplayIsBuiltin($0) == 0 && CGDisplayVendorNumber($0) != virtualVendorID
        }
    }

    private func checkLid() {
        let closed = lidClosed()
        defer { lastLidClosed = closed }
        if closed && !lastLidClosed {
            guard isOn, !externalDisplayAttached() else { return }
            if muteOnClose { mutedByLid = muteIfNeeded() }
            if masterMode { startVirtualDisplay() }
            dimBuiltInScreen()
            if !masterMode && lockOnClose { lockScreen() }
        } else if !closed && lastLidClosed {
            if virtualDisplay != nil {
                lockScreen()
                stopVirtualDisplay()
            }
            restoreBuiltInScreen()
            if mutedByLid {
                setMuted(false)
                mutedByLid = false
            }
        }
    }

    // MARK: Built-in screen backlight

    // With sleep disabled, macOS can leave the built-in panel lit behind a closed lid.
    // Brightness 0 turns the backlight off. The saved level lives in UserDefaults so a
    // crash or quit can't strand the screen dark.
    private typealias GetBrightnessFn = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
    private typealias SetBrightnessFn = @convention(c) (CGDirectDisplayID, Float) -> Int32
    private lazy var displayServices = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_NOW)

    private func builtInDisplay() -> CGDirectDisplayID? {
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        var count: UInt32 = 0
        CGGetOnlineDisplayList(16, &ids, &count)
        return ids.prefix(Int(count)).first { CGDisplayIsBuiltin($0) != 0 }
    }

    private func dimBuiltInScreen() {
        guard UserDefaults.standard.object(forKey: "savedBrightness") == nil,
              let display = builtInDisplay(),
              let get = displayServices.flatMap({ dlsym($0, "DisplayServicesGetBrightness") }),
              let set = displayServices.flatMap({ dlsym($0, "DisplayServicesSetBrightness") }) else { return }
        var level: Float = 0
        guard unsafeBitCast(get, to: GetBrightnessFn.self)(display, &level) == 0, level > 0 else { return }
        UserDefaults.standard.set(level, forKey: "savedBrightness")
        _ = unsafeBitCast(set, to: SetBrightnessFn.self)(display, 0)
    }

    private func restoreBuiltInScreen() {
        guard let level = UserDefaults.standard.object(forKey: "savedBrightness") as? Float else { return }
        if let display = builtInDisplay(),
           let set = displayServices.flatMap({ dlsym($0, "DisplayServicesSetBrightness") }) {
            _ = unsafeBitCast(set, to: SetBrightnessFn.self)(display, level)
        }
        UserDefaults.standard.removeObject(forKey: "savedBrightness")
    }

    private func startVirtualDisplay() {
        guard virtualDisplay == nil else { return }
        let descriptor = CGVirtualDisplayDescriptor()
        descriptor.setDispatchQueue(DispatchQueue.main)
        descriptor.name = "Lid Awake Screen"
        descriptor.maxPixelsWide = 1920
        descriptor.maxPixelsHigh = 1080
        descriptor.sizeInMillimeters = CGSize(width: 527, height: 296)
        descriptor.vendorID = virtualVendorID
        descriptor.productID = 0x5741
        descriptor.serialNum = 1
        let display = CGVirtualDisplay(descriptor: descriptor)
        let settings = CGVirtualDisplaySettings()
        settings.hiDPI = 0
        settings.modes = [CGVirtualDisplayMode(width: 1920, height: 1080, refreshRate: 60)]
        if display.apply(settings) { virtualDisplay = display }
    }

    // Releasing the object removes the monitor; windows move back to the built-in screen.
    private func stopVirtualDisplay() {
        virtualDisplay = nil
    }

    // Mutes output and reports whether we did it, so opening the lid only
    // unmutes sound that was playing before the lid closed.
    private func muteIfNeeded() -> Bool {
        let state = NSAppleScript(source: "output muted of (get volume settings)")?.executeAndReturnError(nil)
        if state?.booleanValue == true { return false }
        setMuted(true)
        return true
    }

    private func setMuted(_ muted: Bool) {
        NSAppleScript(source: "set volume output muted \(muted)")?.executeAndReturnError(nil)
    }

    private func lockScreen() {
        // Same lock as Ctrl+Cmd+Q. Apps and background work keep running behind it.
        if let handle = dlopen("/System/Library/PrivateFrameworks/login.framework/Versions/Current/login", RTLD_NOW),
           let sym = dlsym(handle, "SACLockScreenImmediate") {
            typealias LockFn = @convention(c) () -> Int32
            _ = unsafeBitCast(sym, to: LockFn.self)()
            return
        }
        let fallback = "tell application \"System Events\" to keystroke \"q\" using {control down, command down}"
        NSAppleScript(source: fallback)?.executeAndReturnError(nil)
    }

    @objc private func toggleLockOnClose() {
        lockOnClose.toggle()
        refreshState()
    }

    @objc private func toggleMuteOnClose() {
        muteOnClose.toggle()
        refreshState()
    }

    @objc private func toggleMasterMode() {
        masterMode.toggle()
        refreshState()
    }

    func applicationWillTerminate(_ notification: Notification) {
        if virtualDisplay != nil { lockScreen() }
        restoreBuiltInScreen()
        if isOn { requestOff() }
    }

    // MARK: State

    private func sleepDisabled() -> Bool {
        let out = run("/usr/bin/pmset", ["-g"])
        return out.split(separator: "\n").contains { line in
            let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            return parts.count >= 2 && parts[0] == "SleepDisabled" && parts[1] == "1"
        }
    }

    // The watchdog checks every 5s, so hold the expected state briefly to avoid flicker.
    private func expect(_ state: Bool) {
        expected = state
        expectedUntil = Date().addingTimeInterval(15)
    }

    private func refreshState() {
        var now = sleepDisabled()
        if let e = expected {
            if now != e && Date() < expectedUntil { now = e } else { expected = nil }
        }
        let wasOn = isOn
        isOn = now
        if isOn && !wasOn { startCaffeinate() }
        if !isOn && wasOn {
            stopCaffeinate()
            deadline = nil
            // Turned off (or timed out) with the lid closed in Master Power Mode: lock first.
            if virtualDisplay != nil { lockScreen(); stopVirtualDisplay() }
        }
        let key = "\(isOn)|\(deadline?.timeIntervalSince1970 ?? 0)|\(SMAppService.mainApp.status == .enabled)|\(lockOnClose)|\(muteOnClose)|\(masterMode)"
        if key != renderedKey { renderedKey = key; updateUI() }
    }

    // MARK: Actions

    @objc private func turnOn(_ sender: NSMenuItem) {
        let hours = sender.tag
        deadline = hours > 0 ? Date().addingTimeInterval(TimeInterval(hours * 3600)) : nil
        guard let script = Bundle.main.path(forResource: "watchdog", ofType: "sh") else {
            alert("watchdog.sh is missing from the app bundle.")
            return
        }
        try? FileManager.default.removeItem(at: flagURL)
        let deadlineEpoch = deadline.map { Int($0.timeIntervalSince1970) } ?? 0
        let args = [script, flagURL.path, String(ProcessInfo.processInfo.processIdentifier),
                    String(deadlineEpoch), String(minBatteryPercent)]

        // With the optional no-password rule installed, run the helper as this user.
        if passwordlessRuleInstalled() {
            let helper = Process()
            helper.executableURL = URL(fileURLWithPath: "/bin/sh")
            helper.arguments = args
            helper.standardOutput = FileHandle.nullDevice
            helper.standardError = FileHandle.nullDevice
            do {
                try helper.run()
                expect(true)
                refreshState()
                return
            } catch {
                // Fall through to the password prompt.
            }
        }

        let shell = (["/bin/sh"] + args).map(shellQuote).joined(separator: " ") + " >/dev/null 2>&1 &"
        let source = "do shell script \"\(appleScriptEscape(shell))\" with administrator privileges"
        var error: NSDictionary?
        NSAppleScript(source: source)?.executeAndReturnError(&error)
        if let error = error {
            deadline = nil
            if (error[NSAppleScript.errorNumber] as? Int) != -128 { // -128 = user cancelled
                alert("Could not turn on: \(error[NSAppleScript.errorMessage] ?? error)")
            }
            return
        }
        expect(true)
        refreshState()
    }

    // True when the README's /etc/sudoers.d/lid-awake rule is installed and covers this
    // user. The file check matters: any other NOPASSWD rule makes `sudo -n -l` answer too.
    private func passwordlessRuleInstalled() -> Bool {
        FileManager.default.fileExists(atPath: "/etc/sudoers.d/lid-awake")
            && run("/usr/bin/sudo", ["-n", "-l", "/usr/bin/pmset", "-a", "disablesleep", "1"]).contains("pmset")
    }

    @objc private func turnOff() {
        requestOff()
        expect(false)
        refreshState()
    }

    private func requestOff() {
        FileManager.default.createFile(atPath: flagURL.path, contents: Data())
    }

    @objc private func toggleLoginItem() {
        let service = SMAppService.mainApp
        do {
            if service.status == .enabled { try service.unregister() } else { try service.register() }
        } catch {
            alert("Could not change Open at Login: \(error.localizedDescription)")
        }
        refreshState()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    // Keeps the display and system awake while the lid is open, too.
    private func startCaffeinate() {
        guard caffeinate == nil else { return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/caffeinate")
        p.arguments = ["-dims", "-w", String(ProcessInfo.processInfo.processIdentifier)]
        try? p.run()
        caffeinate = p
    }

    private func stopCaffeinate() {
        caffeinate?.terminate()
        caffeinate = nil
    }

    // MARK: UI

    private func updateUI() {
        let on = isOn
        if let button = statusItem.button {
            let name = on ? "sun.max.fill" : "moon.zzz"
            button.image = NSImage(systemSymbolName: name, accessibilityDescription: on ? "Lid Awake on" : "Lid Awake off")
            button.image?.isTemplate = true
        }

        let menu = NSMenu()
        menu.autoenablesItems = false
        let status = NSMenuItem(title: statusText(on: on), action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)
        if masterMode {
            let master = NSMenuItem(title: "Master Power Mode: locks when the lid opens", action: nil, keyEquivalent: "")
            master.isEnabled = false
            menu.addItem(master)
        }
        menu.addItem(.separator())

        if on {
            let offItem = NSMenuItem(title: "Turn Off", action: #selector(turnOff), keyEquivalent: "")
            offItem.target = self
            menu.addItem(offItem)
        } else {
            let forever = NSMenuItem(title: "Turn On (no timer)", action: #selector(turnOn(_:)), keyEquivalent: "")
            forever.tag = 0
            forever.target = self
            menu.addItem(forever)
            let onItem = NSMenuItem(title: "Turn On for…", action: nil, keyEquivalent: "")
            let sub = NSMenu()
            for (title, hours) in [("1 hour", 1), ("2 hours", 2), ("4 hours", 4), ("8 hours", 8)] {
                let item = NSMenuItem(title: title, action: #selector(turnOn(_:)), keyEquivalent: "")
                item.tag = hours
                item.target = self
                sub.addItem(item)
            }
            onItem.submenu = sub
            menu.addItem(onItem)
        }

        menu.addItem(.separator())
        let note = NSMenuItem(title: "Auto-off below \(minBatteryPercent)% battery or if this app quits", action: nil, keyEquivalent: "")
        note.isEnabled = false
        menu.addItem(note)
        let lock = NSMenuItem(title: "Lock When Lid Closes", action: #selector(toggleLockOnClose), keyEquivalent: "")
        lock.target = self
        lock.state = lockOnClose ? .on : .off
        lock.isEnabled = !masterMode // Master Power Mode always locks on open instead
        menu.addItem(lock)
        let mute = NSMenuItem(title: "Mute When Lid Closes", action: #selector(toggleMuteOnClose), keyEquivalent: "")
        mute.target = self
        mute.state = muteOnClose ? .on : .off
        menu.addItem(mute)
        let master = NSMenuItem(title: "Master Power Mode (computer use)", action: #selector(toggleMasterMode), keyEquivalent: "")
        master.target = self
        master.state = masterMode ? .on : .off
        menu.addItem(master)
        let login = NSMenuItem(title: "Open at Login", action: #selector(toggleLoginItem), keyEquivalent: "")
        login.target = self
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)
        let help = NSMenuItem(title: "Help…", action: #selector(showHelp), keyEquivalent: "?")
        help.target = self
        menu.addItem(help)
        let quitItem = NSMenuItem(title: on ? "Quit (turns sleep back on)" : "Quit", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
        statusItem.menu = menu
    }

    private func statusText(on: Bool) -> String {
        guard on else { return "Off: Mac sleeps when the lid closes" }
        guard let deadline = deadline else { return "On: stays awake with the lid closed" }
        let f = DateFormatter()
        f.timeStyle = .short
        return "On until \(f.string(from: deadline))"
    }

    // MARK: Help

    private static let helpSections: [(String, [(String, String)])] = [
        ("What Lid Awake Does", [
            ("", "Keeps your Mac running with the lid closed, so Claude, other AI agents, and anything else you started keep working. The menu bar icon is a moon when it's off and a sun when it's on."),
        ]),
        ("Menu Options", [
            ("Turn On (no timer)", "Keeps the Mac running with the lid closed until you turn it off. Asks for your Mac password once, or never if the optional no-password rule from the README is set up."),
            ("Turn On for…", "The same, and it turns itself off after 1, 2, 4, or 8 hours."),
            ("Turn Off", "Puts normal sleep back. No password needed."),
            ("Lock When Lid Closes", "Locks the Mac the moment the lid shuts, so opening it asks for your password or Touch ID. Work keeps running behind the lock screen. On by default."),
            ("Mute When Lid Closes", "Silences the Mac while the lid is shut and puts sound back when you open it. If you had already muted, it stays muted. On by default."),
            ("Master Power Mode (computer use)", "For long tasks where an AI agent such as Claude clicks around on the screen (computer use). When the lid closes, Lid Awake adds a virtual 1920 by 1080 monitor so the agent still has a screen to see and click, and the Mac stays signed in with no lock screen so computer use can run. The moment the lid opens, the Mac locks and the virtual monitor goes away. Off by default; while it's on, Lock When Lid Closes is replaced by this lock on open."),
            ("Open at Login", "Starts Lid Awake every time you log in."),
            ("Quit", "Closes the app and puts normal sleep back."),
        ]),
        ("Automatic Safety", [
            ("", "Normal sleep comes back by itself when the timer ends, when the battery drops to \(minBatteryPercent)% while unplugged, or when the app quits or crashes."),
            ("", "Lock and mute are skipped when an external monitor is plugged in, because closing the lid at a desk setup is normal use."),
        ]),
        ("Good to Know", [
            ("Dark screen", "When the lid closes, Lid Awake turns the built-in screen's backlight all the way down so it doesn't glow or drain the battery, and puts your brightness back when you open it. Work keeps running, and an external monitor stays fully usable. The virtual monitor in Master Power Mode has no backlight, so it uses no screen power."),
            ("Screen-clicking tasks", "Anything where an AI agent clicks around on the screen pauses while the Mac is locked. Terminal, code, and other background work keep going. Turn on Master Power Mode when a task needs computer use with the lid closed."),
            ("Master Power Mode security", "The Mac has no lock screen up while the lid is closed, so a keyboard or mouse plugged into it could still control it. Use it where the laptop stays with you or somewhere you trust."),
            ("Heat", "Never put the Mac in a bag while Lid Awake is on. A closed laptop working hard with no airflow can overheat. On a desk with the lid shut is fine."),
            ("Updates", "Run the install command from github.com/accountsFON/lid-awake again to get the newest version."),
        ]),
        ("Made by Five One Nine Marketing", [
            ("", "Lid Awake was built by Caleb Cody, founder and CEO of Five One Nine Marketing. Five One Nine is a growth partner for marketing strategy, digital marketing, and AI strategy. Your strategy. Your system. Your growth partner."),
            ("Work with us", "fonmarketing.com"),
        ]),
    ]

    @objc private func showHelp() {
        if helpWindow == nil {
            let text = NSMutableAttributedString()
            let body = NSFont.systemFont(ofSize: 13)
            let para = NSMutableParagraphStyle()
            para.paragraphSpacing = 8
            let heading = NSMutableParagraphStyle()
            heading.paragraphSpacingBefore = 10
            heading.paragraphSpacing = 6
            let color = NSColor.labelColor
            for (title, items) in Self.helpSections {
                text.append(NSAttributedString(string: title + "\n", attributes: [
                    .font: NSFont.boldSystemFont(ofSize: 15), .foregroundColor: color, .paragraphStyle: heading]))
                for (label, detail) in items {
                    if !label.isEmpty {
                        text.append(NSAttributedString(string: label + ": ", attributes: [
                            .font: NSFont.boldSystemFont(ofSize: 13), .foregroundColor: color, .paragraphStyle: para]))
                    }
                    text.append(NSAttributedString(string: detail + "\n", attributes: [
                        .font: body, .foregroundColor: color, .paragraphStyle: para]))
                }
            }

            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 560),
                                  styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            window.title = "Lid Awake Help"
            window.isReleasedWhenClosed = false
            let scroll = NSScrollView(frame: window.contentView!.bounds)
            scroll.autoresizingMask = [.width, .height]
            scroll.hasVerticalScroller = true
            scroll.drawsBackground = false
            let view = NSTextView(frame: scroll.bounds)
            view.autoresizingMask = [.width]
            view.isEditable = false
            view.drawsBackground = false
            view.textContainerInset = NSSize(width: 18, height: 14)
            view.textStorage?.setAttributedString(text)
            scroll.documentView = view
            window.contentView?.addSubview(scroll)
            window.center()
            helpWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        helpWindow?.makeKeyAndOrderFront(nil)
    }

    // MARK: Helpers

    private func run(_ path: String, _ args: [String]) -> String {
        let p = Process()
        let pipe = Pipe()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        p.standardOutput = pipe
        p.standardError = Pipe()
        do { try p.run() } catch { return "" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }

    private func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private func appleScriptEscape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }

    private func alert(_ text: String) {
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.messageText = "Lid Awake"
        a.informativeText = text
        a.runModal()
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
