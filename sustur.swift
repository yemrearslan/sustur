import Cocoa
import Carbon
import CoreAudio
import os
import UserNotifications

/// Read with: log show --last 1d --predicate 'subsystem == "com.emre.sustur"' --info
let log = Logger(subsystem: "com.emre.sustur", category: "app")

// MARK: - CoreAudio helpers

enum Mic {
    static let system = AudioObjectID(kAudioObjectSystemObject)

    static func addr(_ selector: AudioObjectPropertySelector,
                     _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                     _ element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
    }

    static func defaultInputDevice() -> AudioObjectID? {
        var a = addr(kAudioHardwarePropertyDefaultInputDevice)
        var id = AudioObjectID(0)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &a, 0, nil, &size, &id) == noErr, id != 0 else { return nil }
        return id
    }

    static func channelCount(_ dev: AudioObjectID) -> Int {
        var a = addr(kAudioDevicePropertyStreamConfiguration, kAudioDevicePropertyScopeInput)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(dev, &a, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(dev, &a, 0, nil, &size, raw) == noErr else { return 0 }
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    /// Elements that carry the input volume control: main element if present, otherwise per-channel.
    static func volumeElements(_ dev: AudioObjectID) -> [AudioObjectPropertyElement] {
        var a = addr(kAudioDevicePropertyVolumeScalar, kAudioDevicePropertyScopeInput)
        if AudioObjectHasProperty(dev, &a) { return [kAudioObjectPropertyElementMain] }
        let n = channelCount(dev)
        guard n > 0 else { return [] }
        return (1...n).map { AudioObjectPropertyElement($0) }.filter {
            var c = addr(kAudioDevicePropertyVolumeScalar, kAudioDevicePropertyScopeInput, $0)
            return AudioObjectHasProperty(dev, &c)
        }
    }

    /// Input volume 0...100, or nil if the device has no volume control.
    static func volume(_ dev: AudioObjectID) -> Int? {
        let values: [Float32] = volumeElements(dev).compactMap {
            var a = addr(kAudioDevicePropertyVolumeScalar, kAudioDevicePropertyScopeInput, $0)
            var v: Float32 = 0
            var size = UInt32(MemoryLayout<Float32>.size)
            return AudioObjectGetPropertyData(dev, &a, 0, nil, &size, &v) == noErr ? v : nil
        }
        guard let maxV = values.max() else { return nil }
        return Int((maxV * 100).rounded())
    }

    static func setVolume(_ dev: AudioObjectID, _ percent: Int) {
        var v = Float32(max(0, min(100, percent))) / 100
        for el in volumeElements(dev) {
            var a = addr(kAudioDevicePropertyVolumeScalar, kAudioDevicePropertyScopeInput, el)
            AudioObjectSetPropertyData(dev, &a, 0, nil, UInt32(MemoryLayout<Float32>.size), &v)
        }
    }

    static func hardwareMuted(_ dev: AudioObjectID) -> Bool? {
        var a = addr(kAudioDevicePropertyMute, kAudioDevicePropertyScopeInput)
        guard AudioObjectHasProperty(dev, &a) else { return nil }
        var v: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(dev, &a, 0, nil, &size, &v) == noErr else { return nil }
        return v != 0
    }

    static func canHardwareMute(_ dev: AudioObjectID) -> Bool {
        var a = addr(kAudioDevicePropertyMute, kAudioDevicePropertyScopeInput)
        var settable: DarwinBoolean = false
        return AudioObjectHasProperty(dev, &a)
            && AudioObjectIsPropertySettable(dev, &a, &settable) == noErr && settable.boolValue
    }

    static func setHardwareMute(_ dev: AudioObjectID, _ muted: Bool) {
        guard canHardwareMute(dev) else { return }
        var a = addr(kAudioDevicePropertyMute, kAudioDevicePropertyScopeInput)
        var v: UInt32 = muted ? 1 : 0
        AudioObjectSetPropertyData(dev, &a, 0, nil, UInt32(MemoryLayout<UInt32>.size), &v)
    }
}

// MARK: - App

class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    var statusItem: NSStatusItem!
    var eventTap: CFMachPort?
    var accessibilityPrompted = false
    let volumeKey = "lastMicVolume"
    let pttKey = "pushToTalkEnabled"
    let notifyKey = "notificationsEnabled"
    let notificationID = "sustur.status"
    let notificationLifetime: TimeInterval = 3
    var notificationGeneration = 0

    /// Single source of truth for the mute state (what the user asked for).
    /// The device is forced to follow this, so apps that auto-adjust mic gain can't silently un-mute it.
    var isMuted = true

    var watchedDevice: AudioObjectID?
    var deviceListeners: [(AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []
    let listenerQueue = DispatchQueue(label: "sustur.coreaudio")

    var isPTT: Bool {
        get { UserDefaults.standard.bool(forKey: pttKey) }
        set { UserDefaults.standard.set(newValue, forKey: pttKey) }
    }
    var canNotify: Bool {
        get {
            if UserDefaults.standard.object(forKey: notifyKey) == nil { return true }
            return UserDefaults.standard.bool(forKey: notifyKey)
        }
        set { UserDefaults.standard.set(newValue, forKey: notifyKey) }
    }
    /// PID of the process holding Secure Input (nil when off). While on, event taps see no keys.
    var secureInputHolder: pid_t?
    var healthTimer: Timer?

    var restoreVolume: Int {
        let v = UserDefaults.standard.integer(forKey: volumeKey)
        return v > 0 ? v : 75
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if Bundle.main.bundleIdentifier != nil {
            let center = UNUserNotificationCenter.current()
            center.delegate = self
            center.requestAuthorization(options: [.alert]) { granted, error in
                if let error = error { print("❌ Notification Center Error: \(error.localizedDescription)") }
                if !granted { print("⚠️ Notification permission denied by user") }
            }
        } else {
            print("⚠️ Running in terminal mode. Notifications are disabled (No Bundle ID)")
        }

        if let dev = Mic.defaultInputDevice() {
            if let v = Mic.volume(dev) {
                isMuted = v == 0
            } else {
                isMuted = Mic.hardwareMuted(dev) == true
            }
        }
        if isPTT { isMuted = true }

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.action = #selector(handleMouseClick(_:))
            button.target = self
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }

        log.notice("Launched. muted=\(self.isMuted, privacy: .public) ptt=\(self.isPTT, privacy: .public)")
        watchDefaultInputDevice()
        applyState()
        startEventTap()

        healthTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.checkHealth() }
        healthTimer?.tolerance = 0.5
        checkHealth()
    }

    // MARK: Health checks

    /// Runs every 2s: tracks Secure Input and revives the event tap if macOS disabled it silently.
    func checkHealth() {
        let holder = currentSecureInputHolder()
        if holder != secureInputHolder {
            secureInputHolder = holder
            if let pid = holder {
                log.notice("Secure Input ON (holder: \(self.processName(pid), privacy: .public) pid \(pid, privacy: .public)). F5 cannot be seen.")
            } else {
                log.notice("Secure Input OFF")
            }
            updateIconButton()
        }
        if let tap = eventTap, !CGEvent.tapIsEnabled(tap: tap) {
            log.error("Event tap found disabled; re-enabling")
            CGEvent.tapEnable(tap: tap, enable: true)
            if isPTT { setMuted(true, notify: false) }
        }
    }

    func currentSecureInputHolder() -> pid_t? {
        guard IsSecureEventInputEnabled() else { return nil }
        let dict = CGSessionCopyCurrentDictionary() as? [String: Any]
        let pid = (dict?["kCGSSessionSecureInputPID"] as? NSNumber)?.int32Value ?? 0
        return pid  // 0 = enabled but holder unknown
    }

    func processName(_ pid: pid_t) -> String {
        if pid == 0 { return "unknown" }
        if let name = NSRunningApplication(processIdentifier: pid)?.localizedName { return name }
        var buf = [CChar](repeating: 0, count: 256)
        return proc_name(pid, &buf, UInt32(buf.count)) > 0 ? String(cString: buf) : "pid \(pid)"
    }

    // MARK: Menu

    @objc func handleMouseClick(_ sender: NSStatusBarButton) {
        guard let event = NSApp.currentEvent else { return }
        if event.type == .rightMouseUp {
            let menu = NSMenu()
            if let pid = secureInputHolder {
                let warn = NSMenuItem(title: "⚠️ F5 blocked by Secure Input (\(processName(pid)))", action: nil, keyEquivalent: "")
                warn.isEnabled = false
                menu.addItem(warn)
                let hint = NSMenuItem(title: "Try locking and unlocking the screen, or log out", action: nil, keyEquivalent: "")
                hint.isEnabled = false
                menu.addItem(hint)
                menu.addItem(NSMenuItem.separator())
            }
            let pttItem = NSMenuItem(title: "Push-to-Talk Mode", action: #selector(togglePTTSetting), keyEquivalent: "")
            pttItem.state = isPTT ? .on : .off
            menu.addItem(pttItem)

            let notifyItem = NSMenuItem(title: "Show Notifications", action: #selector(toggleNotifySetting), keyEquivalent: "")
            notifyItem.state = canNotify ? .on : .off
            menu.addItem(notifyItem)

            menu.addItem(NSMenuItem.separator())
            menu.addItem(NSMenuItem(title: "Exit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))

            statusItem.menu = menu
            statusItem.button?.performClick(nil)
            statusItem.menu = nil
        } else {
            toggleMute()
        }
    }

    @objc func togglePTTSetting() {
        isPTT = !isPTT
        if isPTT { setMuted(true, notify: false) }
    }
    @objc func toggleNotifySetting() { canNotify = !canNotify }

    // MARK: State

    @objc func toggleMute() {
        setMuted(!isMuted, notify: true)
    }

    func setMuted(_ muted: Bool, notify: Bool) {
        if muted, !isMuted, let dev = Mic.defaultInputDevice(), let v = Mic.volume(dev), v > 0 {
            UserDefaults.standard.set(v, forKey: volumeKey)
        }
        let changed = muted != isMuted
        if changed { log.notice("\(muted ? "Muted" : "Unmuted", privacy: .public)") }
        isMuted = muted
        applyState()
        if changed && notify { sendNotification(status: muted ? "Muted 🔇" : "Unmuted 🎙️") }
    }

    /// Push `isMuted` to the current input device and refresh the icon.
    func applyState() {
        if let dev = Mic.defaultInputDevice() {
            if Mic.volume(dev) == nil {
                // No volume control on this device: fall back to its mute switch.
                // (Not used otherwise: macOS shows no UI for it, so a leftover mute would be invisible.)
                Mic.setHardwareMute(dev, isMuted)
            } else if isMuted {
                Mic.setVolume(dev, 0)
            } else if Mic.volume(dev) == 0 {
                Mic.setVolume(dev, restoreVolume)
            }
        }
        updateIconButton()
    }

    /// Called when the device's volume/mute changed behind our back.
    func enforceState() {
        guard isMuted, let dev = Mic.defaultInputDevice() else { return }
        let leaked: Bool
        if let v = Mic.volume(dev) {
            leaked = v > 0
        } else {
            leaked = Mic.canHardwareMute(dev) && Mic.hardwareMuted(dev) == false
        }
        if leaked {
            log.notice("Mute Guard: input level changed while muted, forcing back to 0")
            applyState()
        }
    }

    // MARK: CoreAudio listeners

    func watchDefaultInputDevice() {
        var a = Mic.addr(kAudioHardwarePropertyDefaultInputDevice)
        AudioObjectAddPropertyListenerBlock(Mic.system, &a, listenerQueue) { [weak self] _, _ in
            DispatchQueue.main.async {
                log.notice("Default input device changed")
                self?.watchCurrentDevice()
                self?.applyState()
            }
        }
        watchCurrentDevice()
    }

    func watchCurrentDevice() {
        if let old = watchedDevice {
            for (addr, block) in deviceListeners {
                var a = addr
                AudioObjectRemovePropertyListenerBlock(old, &a, listenerQueue, block)
            }
        }
        deviceListeners = []
        watchedDevice = nil
        guard let dev = Mic.defaultInputDevice() else { return }
        watchedDevice = dev

        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            DispatchQueue.main.async { self?.enforceState() }
        }
        var addrs = Mic.volumeElements(dev).map {
            Mic.addr(kAudioDevicePropertyVolumeScalar, kAudioDevicePropertyScopeInput, $0)
        }
        addrs.append(Mic.addr(kAudioDevicePropertyMute, kAudioDevicePropertyScopeInput))
        for addr in addrs {
            var a = addr
            guard AudioObjectHasProperty(dev, &a),
                  AudioObjectAddPropertyListenerBlock(dev, &a, listenerQueue, block) == noErr else { continue }
            deviceListeners.append((addr, block))
        }
    }

    // MARK: UI

    func updateIconButton() {
        guard let button = statusItem?.button else { return }
        let iconName = isMuted ? "mic.slash.fill" : "mic.fill"
        // 13pt keeps the symbol ~17pt tall, like system status items; larger sizes got clipped
        // at the top on shorter menu bars (e.g. external displays).
        var config = NSImage.SymbolConfiguration(pointSize: 13, weight: .semibold)
        if !isMuted {
            // Live: red, like an "on air" light
            config = config.applying(NSImage.SymbolConfiguration(paletteColors: [.systemRed]))
        }
        guard let image = NSImage(systemSymbolName: iconName, accessibilityDescription: isMuted ? "Muted" : "Unmuted")?
                .withSymbolConfiguration(config) else { return }
        // Muted: template image, so it follows the menu bar's own color
        image.isTemplate = isMuted
        button.imageScaling = .scaleProportionallyDown
        button.image = image
        // Secure Input on: F5 can't reach us. Show a small warning next to the icon.
        button.title = secureInputHolder == nil ? "" : "⚠︎"
        button.imagePosition = .imageLeft
        button.toolTip = secureInputHolder.map { "F5 blocked by Secure Input (\(processName($0)))" }
    }

    func sendNotification(status: String) {
        guard canNotify && !isPTT else { return }
        let center = UNUserNotificationCenter.current()
        let content = UNMutableNotificationContent()
        content.title = "Sustur"
        content.body = "Microphone \(status)"
        // Same identifier every time: a new notification replaces the old one instead of piling up.
        center.removeDeliveredNotifications(withIdentifiers: [notificationID])
        center.add(UNNotificationRequest(identifier: notificationID, content: content, trigger: nil))

        // Clear it from Notification Center shortly after the banner is shown.
        notificationGeneration += 1
        let gen = notificationGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + notificationLifetime) { [weak self] in
            guard let self = self, gen == self.notificationGeneration else { return }
            center.removeDeliveredNotifications(withIdentifiers: [self.notificationID])
        }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner])
    }

    // MARK: Keyboard

    func handleKey(type: CGEventType, event: CGEvent) {
        let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
        if !isRepeat {
            log.notice("F5 \(type == .keyDown ? "down" : "up", privacy: .public) (ptt=\(self.isPTT, privacy: .public))")
        }
        if isPTT {
            if type == .keyDown {
                if event.getIntegerValueField(.keyboardEventAutorepeat) != 0 { return }
                setMuted(false, notify: false)
            } else if type == .keyUp {
                setMuted(true, notify: false)
            }
        } else if type == .keyDown {
            // Ignore key auto-repeat; it would toggle twice and leave the mic in the old state.
            if event.getIntegerValueField(.keyboardEventAutorepeat) != 0 { return }
            toggleMute()
        }
    }

    func tapWasDisabled(_ type: CGEventType) {
        log.error("Event tap disabled by macOS (\(type == .tapDisabledByTimeout ? "timeout" : "user input", privacy: .public)); re-enabling")
        if let tap = eventTap { CGEvent.tapEnable(tap: tap, enable: true) }
        // A key-up may have been lost while the tap was off; never leave PTT stuck open.
        if isPTT { setMuted(true, notify: false) }
    }

    func startEventTap() {
        let eventMask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue)
        guard let tap = CGEvent.tapCreate(
            tap: .cghidEventTap, place: .headInsertEventTap, options: .defaultTap,
            eventsOfInterest: CGEventMask(eventMask),
            callback: { (proxy, type, event, userInfo) -> Unmanaged<CGEvent>? in
                guard let userInfo = userInfo else { return Unmanaged.passUnretained(event) }
                let delegate = Unmanaged<AppDelegate>.fromOpaque(userInfo).takeUnretainedValue()

                if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                    delegate.tapWasDisabled(type)
                    return Unmanaged.passUnretained(event)
                }
                if event.getIntegerValueField(.keyboardEventKeycode) == 176 {
                    delegate.handleKey(type: type, event: event)
                    return nil
                }
                return Unmanaged.passUnretained(event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            // No Accessibility permission yet: ask macOS to show its prompt once, then keep retrying
            // quietly so F5 starts working as soon as the user grants it (no restart needed).
            if !accessibilityPrompted {
                accessibilityPrompted = true
                log.error("Could not create event tap (no Accessibility permission?). Requesting it.")
                let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
                _ = AXIsProcessTrustedWithOptions(opts)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.startEventTap() }
            return
        }
        eventTap = tap
        log.notice("Event tap created")
        let runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
