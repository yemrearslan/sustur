import Cocoa
import AVFoundation
import UserNotifications

class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    var statusItem: NSStatusItem!
    let volumeKey = "lastMicVolume"
    let pttKey = "pushToTalkEnabled"
    let notifyKey = "notificationsEnabled"
    
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

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let bundleID = Bundle.main.bundleIdentifier {
            print("🆔 Application ID: \(bundleID)") // 🆔 Uygulama Kimliği:
            
            let center = UNUserNotificationCenter.current()
            center.delegate = self
            
            center.requestAuthorization(options: [.alert, .sound]) { granted, error in
                if let error = error {
                    print("❌ Notification Center Error: \(error.localizedDescription)") // ❌ Bildirim Merkezi Hatası:
                }
                if granted {
                    print("🔔 Notification permission acquired") // 🔔 Bildirim izni verildi.
                } else {
                    print("⚠️ Notification permission denied by user") // ⚠️ Bildirim izni kullanıcı tarafından reddedildi.
                }
            }
        } else {
            print("⚠️ Running in terminal mode. Notifications are disabled (No Bundle ID)") // ⚠️ Terminal modunda çalışıyor: Bildirimler devre dışı (Bundle ID yok).
        }

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        
        if let button = statusItem.button {
            button.action = #selector(handleMouseClick(_:))
            button.target = self
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            
            updateIconButton(isMuted: (getCurrentVolume() == 0))
        }
        
        startEventTap()
    }

    @objc func handleMouseClick(_ sender: NSStatusBarButton) {
        let event = NSApp.currentEvent!
        if event.type == .rightMouseUp {
            let menu = NSMenu()
            let pttItem = NSMenuItem(title: "Push-to-Talk Mode", action: #selector(togglePTTSetting), keyEquivalent: "") // Bas-Konuş Modu
            pttItem.state = isPTT ? .on : .off
            menu.addItem(pttItem)
            
            let notifyItem = NSMenuItem(title: "Show Notifications", action: #selector(toggleNotifySetting), keyEquivalent: "") // Bildirimleri Göster
            notifyItem.state = canNotify ? .on : .off
            menu.addItem(notifyItem)
            
            menu.addItem(NSMenuItem.separator())
            menu.addItem(NSMenuItem(title: "Exit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")) // Çıkış
            
            statusItem.menu = menu
            statusItem.button?.performClick(nil)
            statusItem.menu = nil
        } else {
            toggleMute()
        }
    }

    @objc func togglePTTSetting() { isPTT = !isPTT }
    @objc func toggleNotifySetting() { canNotify = !canNotify }

    func getCurrentVolume() -> Int {
        let script = NSAppleScript(source: "get input volume of (get volume settings)")
        return Int(script?.executeAndReturnError(nil).int32Value ?? 0)
    }

    func sendNotification(status: String) {
        guard canNotify && !isPTT else { return }
        let content = UNMutableNotificationContent()
        content.title = "Sustur"
        content.body = "Microphone \(status)" // Mikrofon
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    func updateIconButton(isMuted: Bool) {
        guard let button = statusItem.button else { return }
        let config = NSImage.SymbolConfiguration(pointSize: 15, weight: .bold)
        let iconName = isMuted ? "mic.slash.fill" : "mic.fill"
        
        if let image = NSImage(systemSymbolName: iconName, accessibilityDescription: nil),
           let finalImage = image.withSymbolConfiguration(config) {
            if isMuted {
                button.image = finalImage.tinted(with: .systemRed)
                button.image?.isTemplate = false
            } else {
                button.image = finalImage
                button.image?.isTemplate = true
            }
        }
    }

    func setVolume(_ volume: Int) {
        NSAppleScript(source: "set volume input volume \(volume)")?.executeAndReturnError(nil)
        DispatchQueue.main.async { self.updateIconButton(isMuted: (volume == 0)) }
    }

    @objc func toggleMute() {
        let currentVol = getCurrentVolume()
        if currentVol > 0 {
            UserDefaults.standard.set(currentVol, forKey: volumeKey)
            setVolume(0)
            sendNotification(status: "Muted 🔴")  // Kapatıldı 🔴
        } else {
            let lastVol = UserDefaults.standard.integer(forKey: volumeKey)
            setVolume(lastVol > 0 ? lastVol : 75)
            sendNotification(status: "Unmuted 🟢") // Açıldı 🟢
        }
    }

    func startEventTap() {
        let eventMask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue) | (1 << 14)
        guard let eventTap = CGEvent.tapCreate(
            tap: .cghidEventTap, place: .headInsertEventTap, options: .defaultTap,
            eventsOfInterest: CGEventMask(eventMask),
            callback: { (proxy, type, event, userInfo) -> Unmanaged<CGEvent>? in
                let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
                guard let userInfo = userInfo else { return Unmanaged.passRetained(event) }
                let delegate = Unmanaged<AppDelegate>.fromOpaque(userInfo).takeUnretainedValue()

                if keyCode == 176 {
                    if delegate.isPTT {
                        if type == .keyDown { 
                            let lastVol = UserDefaults.standard.integer(forKey: delegate.volumeKey)
                            delegate.setVolume(lastVol > 0 ? lastVol : 75) 
                        }
                        else if type == .keyUp { delegate.setVolume(0) }
                    } else if type == .keyDown {
                        delegate.toggleMute()
                    }
                    return nil
                }
                return Unmanaged.passRetained(event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else { return }
        let runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, eventTap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: eventTap, enable: true)
    }
}

extension NSImage {
    func tinted(with color: NSColor) -> NSImage {
        let newImage = NSImage(size: size)
        newImage.lockFocus()
        color.set()
        let rect = NSRect(origin: .zero, size: size)
        rect.fill() 
        self.draw(in: rect, from: .zero, operation: .destinationIn, fraction: 1.0)
        newImage.unlockFocus()
        newImage.isTemplate = false
        return newImage
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
