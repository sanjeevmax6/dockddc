import Cocoa
import CoreGraphics
import IOKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var autoItem: NSMenuItem!
    private var notifyPort: IONotificationPortRef?
    private var matchIterator: io_iterator_t = 0
    private let queue = DispatchQueue(label: "dockddc.relay")
    private var pending: [UInt8: DispatchWorkItem] = [:]

    private static let inputs: [(String, UInt16)] = [
        ("DisplayPort 1", 15), ("DisplayPort 2", 16), ("HDMI 1", 17), ("HDMI 2", 18), ("USB-C", 27),
    ]
    private static let sliders: [(String, UInt8)] = [("Brightness", 0x10), ("Contrast", 0x12), ("Volume", 0x62)]

    private var autoSwitch: Bool {
        get { UserDefaults.standard.object(forKey: "autoSwitch") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "autoSwitch") }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "display", accessibilityDescription: "DockDDC")

        let menu = NSMenu()
        menu.autoenablesItems = false
        add(menu, "Switch Monitor to This Mac", #selector(switchToPrimary), "d")

        let inputMenu = NSMenu()
        for (name, code) in Self.inputs {
            let item = add(inputMenu, name, #selector(switchInput(_:)), "")
            item.tag = Int(code)
        }
        menu.addItem(withTitle: "Input Source", action: nil, keyEquivalent: "").submenu = inputMenu

        menu.addItem(.separator())
        for (name, vcp) in Self.sliders { menu.addItem(sliderItem(name, vcp: vcp)) }

        let presets = NSMenu()
        for (name, b, c) in [("Day", 80, 75), ("Evening", 40, 60), ("Night", 10, 50)] {
            let item = add(presets, name, #selector(applyPreset(_:)), "")
            item.representedObject = [b, c]
        }
        menu.addItem(withTitle: "Presets", action: nil, keyEquivalent: "").submenu = presets

        menu.addItem(.separator())
        add(menu, "Reset External Resolution", #selector(resetResolution), "r")
        autoItem = add(menu, "Auto-switch on Connect", #selector(toggleAuto), "")
        autoItem.state = autoSwitch ? .on : .off
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        statusItem.menu = menu

        guard DDCRelay.isSupported else {
            menu.items.filter { $0.target === self && $0.action != #selector(resetResolution) }.forEach { $0.isEnabled = false }
            return
        }
        watchForDock()
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(didWake), name: NSWorkspace.didWakeNotification, object: nil)
    }

    @discardableResult
    private func add(_ menu: NSMenu, _ title: String, _ action: Selector, _ key: String) -> NSMenuItem {
        let item = menu.addItem(withTitle: title, action: action, keyEquivalent: key)
        item.target = self
        return item
    }

    // DDC writes through the hub are blind, so sliders show the last value this app sent.
    private func sliderItem(_ name: String, vcp: UInt8) -> NSMenuItem {
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 240, height: 44))
        let label = NSTextField(labelWithString: "")
        label.frame = NSRect(x: 18, y: 24, width: 210, height: 16)
        label.font = .menuFont(ofSize: 12)
        label.textColor = .secondaryLabelColor
        let slider = NSSlider(value: Double(storedValue(vcp)), minValue: 0, maxValue: 100, target: self, action: #selector(sliderMoved(_:)))
        slider.frame = NSRect(x: 16, y: 2, width: 210, height: 22)
        slider.tag = Int(vcp)
        slider.isContinuous = true
        label.stringValue = "\(name)  \(storedValue(vcp))%"
        label.identifier = NSUserInterfaceItemIdentifier(name)
        view.addSubview(label)
        view.addSubview(slider)
        let item = NSMenuItem()
        item.view = view
        return item
    }

    private func storedValue(_ vcp: UInt8) -> Int {
        UserDefaults.standard.object(forKey: "vcp\(vcp)") as? Int ?? 50
    }

    @objc private func sliderMoved(_ slider: NSSlider) {
        let vcp = UInt8(slider.tag), value = Int(slider.doubleValue.rounded())
        if let label = slider.superview?.subviews.compactMap({ $0 as? NSTextField }).first, let name = label.identifier?.rawValue {
            label.stringValue = "\(name)  \(value)%"
        }
        setVCPDebounced(vcp, value)
    }

    private func setVCPDebounced(_ vcp: UInt8, _ value: Int) {
        UserDefaults.standard.set(value, forKey: "vcp\(vcp)")
        pending[vcp]?.cancel()
        let work = DispatchWorkItem { DDCRelay.setVCP(vcp, UInt16(value), attempts: 1) }
        pending[vcp] = work
        queue.asyncAfter(deadline: .now() + 0.15, execute: work)
    }

    @objc private func applyPreset(_ item: NSMenuItem) {
        guard let values = item.representedObject as? [Int] else { return }
        setVCPDebounced(0x10, values[0])
        setVCPDebounced(0x12, values[1])
        refreshSliders()
    }

    private func refreshSliders() {
        for item in statusItem.menu?.items ?? [] {
            guard let view = item.view,
                  let slider = view.subviews.compactMap({ $0 as? NSSlider }).first,
                  let label = view.subviews.compactMap({ $0 as? NSTextField }).first,
                  let name = label.identifier?.rawValue else { continue }
            let value = storedValue(UInt8(slider.tag))
            slider.doubleValue = Double(value)
            label.stringValue = "\(name)  \(value)%"
        }
    }

    // The hub shows up for a short window after plug-in before a monitor parked on another
    // input drops DP hot-plug, so the input select must go out the moment the hub registers.
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
    @objc private func switchInput(_ item: NSMenuItem) { send(UInt16(item.tag)) }

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
