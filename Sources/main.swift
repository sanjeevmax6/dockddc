import Cocoa
import CoreGraphics
import IOKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var autoItem: NSMenuItem!
    private var notifyPort: IONotificationPortRef?
    private var matchIterator: io_iterator_t = 0
    private let queue = DispatchQueue(label: "dockddc.relay")

    private var autoSwitch: Bool {
        get { UserDefaults.standard.object(forKey: "autoSwitch") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "autoSwitch") }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "display", accessibilityDescription: "DockDDC")

        let menu = NSMenu()
        menu.addItem(withTitle: "Switch Monitor to This Mac", action: #selector(switchToPrimary), keyEquivalent: "d").target = self
        menu.addItem(withTitle: "Switch Monitor to Other Input", action: #selector(switchToSecondary), keyEquivalent: "h").target = self
        menu.addItem(withTitle: "Reset External Resolution", action: #selector(resetResolution), keyEquivalent: "r").target = self
        menu.addItem(.separator())
        autoItem = menu.addItem(withTitle: "Auto-switch on Connect", action: #selector(toggleAuto), keyEquivalent: "")
        autoItem.target = self
        autoItem.state = autoSwitch ? .on : .off
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        statusItem.menu = menu

        guard DDCRelay.isSupported else {
            menu.autoenablesItems = false
            menu.items.prefix(2).forEach { $0.isEnabled = false }
            autoItem.isEnabled = false
            return
        }
        watchForDock()
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(didWake), name: NSWorkspace.didWakeNotification, object: nil)
    }

    // The hub shows up for a short window after plug-in before a monitor parked on another
    // input drops DP hot-plug,
    // so the input select must go out the moment the external DP device registers.
    private func watchForDock() {
        notifyPort = IONotificationPortCreate(kIOMainPortDefault)
        IONotificationPortSetDispatchQueue(notifyPort, queue)
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        IOServiceAddMatchingNotification(notifyPort, kIOFirstMatchNotification, IOServiceMatching("DCPDPDeviceProxy"), { ctx, it in
            let me = Unmanaged<AppDelegate>.fromOpaque(ctx!).takeUnretainedValue()
            var external = false
            while case let s = IOIteratorNext(it), s != 0 {
                if DDCRelay.isExternal(s) { external = true }
                IOObjectRelease(s)
            }
            if external { me.dockAppeared() }
        }, ctx, &matchIterator)
        while case let s = IOIteratorNext(matchIterator), s != 0 { IOObjectRelease(s) }
    }

    private func dockAppeared() {
        guard autoSwitch else { return }
        let input = DDCRelay.Config.current.inputPrimary
        DDCRelay.setInput(input)
        queue.asyncAfter(deadline: .now() + 1.5) { DDCRelay.setInput(input) }
    }

    @objc private func didWake() { queue.asyncAfter(deadline: .now() + 1) { self.dockAppeared() } }

    @objc private func switchToPrimary() { send(DDCRelay.Config.current.inputPrimary) }
    @objc private func switchToSecondary() { send(DDCRelay.Config.current.inputSecondary) }

    private func send(_ input: UInt16) {
        queue.async {
            if !DDCRelay.setInput(input) {
                DispatchQueue.main.async {
                    let a = NSAlert()
                    a.messageText = "No MST dock link found"
                    a.informativeText = "The Mac cannot see a dock DisplayPort hub right now. Replug the USB-C cable to the dock."
                    a.runModal()
                }
            }
        }
    }

    @objc private func toggleAuto() {
        autoSwitch.toggle()
        autoItem.state = autoSwitch ? .on : .off
    }

    @objc private func resetResolution() {
        var count: UInt32 = 0
        CGGetOnlineDisplayList(0, nil, &count)
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        CGGetOnlineDisplayList(count, &ids, &count)
        for id in ids where CGDisplayIsBuiltin(id) == 0 {
            guard let modes = CGDisplayCopyAllDisplayModes(id, nil) as? [CGDisplayMode],
                  let native = modes.filter({ $0.isUsableForDesktopGUI() && $0.width == $0.pixelWidth })
                                    .max(by: { ($0.pixelWidth * $0.pixelHeight, $0.refreshRate) < ($1.pixelWidth * $1.pixelHeight, $1.refreshRate) })
            else { continue }
            var config: CGDisplayConfigRef?
            guard CGBeginDisplayConfiguration(&config) == .success else { continue }
            CGConfigureDisplayWithDisplayMode(config, id, native, nil)
            CGCompleteDisplayConfiguration(config, .permanently)
        }
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
