import Foundation
import IOKit

// Many USB-C docks route DisplayPort through an MST hub that drops plain DDC/CI
// (I2C-over-AUX). The hub still forwards DDC when it is wrapped as a DP sideband
// REMOTE_I2C_WRITE addressed to the downstream port the monitor sits on.
enum DDCRelay {
    struct Config {
        var hubPort: UInt8
        var inputPrimary: UInt16

        static var current: Config {
            let d = UserDefaults.standard
            return Config(
                hubPort: UInt8(clamping: d.object(forKey: "hubPort") as? Int ?? 2),
                inputPrimary: UInt16(clamping: d.object(forKey: "inputPrimary") as? Int ?? 15)
            )
        }
    }

    static let vcpInputSource: UInt8 = 0x60

    private typealias CreateWithService = @convention(c) (CFAllocator?, io_service_t) -> Unmanaged<CFTypeRef>?
    private typealias DPCDIO = @convention(c) (CFTypeRef, UInt32, UnsafeMutableRawPointer, UInt32) -> IOReturn

    private struct API {
        let create: CreateWithService
        let read: DPCDIO
        let write: DPCDIO
    }

    // Private IOKit symbols: resolved at runtime so a missing symbol disables the feature instead of crashing.
    private static let api: API? = {
        guard let h = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW),
              let c = dlsym(h, "IODPDeviceCreateWithService"),
              let r = dlsym(h, "IODPDeviceReadDPCD"),
              let w = dlsym(h, "IODPDeviceWriteDPCD") else { return nil }
        return API(create: unsafeBitCast(c, to: CreateWithService.self),
                   read: unsafeBitCast(r, to: DPCDIO.self),
                   write: unsafeBitCast(w, to: DPCDIO.self))
    }()

    static var isSupported: Bool { api != nil }

    static func isExternal(_ s: io_service_t) -> Bool {
        (IORegistryEntryCreateCFProperty(s, "Location" as CFString, nil, 0)?.takeRetainedValue() as? String) == "External"
    }

    @discardableResult
    static func setInput(_ value: UInt16, config: Config = .current) -> Bool {
        setVCP(vcpInputSource, value, config: config)
    }

    @discardableResult
    static func setVCP(_ vcp: UInt8, _ value: UInt16, config: Config = .current, attempts: Int = 2) -> Bool {
        guard let api, let dp = mstHub(api) else { return false }
        let hi = UInt8(value >> 8), lo = UInt8(value & 0xff)
        let ddc: [UInt8] = [0x51, 0x84, 0x03, vcp, hi, lo, 0x6E ^ 0x51 ^ 0x84 ^ 0x03 ^ vcp ^ hi ^ lo]
        let body: [UInt8] = [0x23, (config.hubPort & 0x0f) << 4, 0x37, UInt8(ddc.count)] + ddc
        var sent = false
        for _ in 0..<attempts {
            var msg = header(bodyLength: body.count + 1) + body + [crc8(body)]
            if api.write(dp, 0x1000, &msg, UInt32(msg.count)) == kIOReturnSuccess { sent = true }
            usleep(80_000)
            var ack: [UInt8] = [0x10]
            _ = api.write(dp, 0x201, &ack, 1)
            _ = api.write(dp, 0x2003, &ack, 1)
            usleep(220_000)
        }
        return sent
    }

    // Only talk to an external DP device that advertises MST (DPCD 0x021 bit 0), so
    // plain monitors, projectors and adapters never receive sideband writes.
    private static func mstHub(_ api: API) -> CFTypeRef? {
        var it: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("DCPDPDeviceProxy"), &it) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(it) }
        while case let s = IOIteratorNext(it), s != 0 {
            defer { IOObjectRelease(s) }
            guard isExternal(s), let dp = api.create(kCFAllocatorDefault, s)?.takeRetainedValue() else { continue }
            var cap: UInt8 = 0
            if api.read(dp, 0x021, &cap, 1) == kIOReturnSuccess, cap & 0x01 != 0 { return dp }
        }
        return nil
    }

    private static func header(bodyLength: Int) -> [UInt8] {
        var h: [UInt8] = [0x10, UInt8(bodyLength & 0x3f), 0xC0]
        h[2] |= crc4([h[0], h[1], h[2] & 0xf0], nibbles: 5)
        return h
    }

    private static func crc4(_ data: [UInt8], nibbles: Int) -> UInt8 {
        var mask: UInt8 = 0x80, shift: UInt8 = 7, rem: UInt8 = 0, idx = 0, n = nibbles * 4
        while n > 0 {
            n -= 1; rem <<= 1; rem |= (data[idx] & mask) >> shift; mask >>= 1; shift = shift &- 1
            if mask == 0 { mask = 0x80; shift = 7; idx += 1 }
            if rem & 0x10 != 0 { rem ^= 0x13 }
        }
        for _ in 0..<4 { rem <<= 1; if rem & 0x10 != 0 { rem ^= 0x13 } }
        return rem & 0x0f
    }

    private static func crc8(_ data: [UInt8]) -> UInt8 {
        var mask: UInt8 = 0x80, shift: UInt8 = 7, rem: UInt16 = 0, idx = 0, n = data.count * 8
        while n > 0 {
            n -= 1; rem <<= 1; rem |= UInt16((data[idx] & mask) >> shift); mask >>= 1; shift = shift &- 1
            if mask == 0 { mask = 0x80; shift = 7; idx += 1 }
            if rem & 0x100 != 0 { rem ^= 0xd5 }
        }
        for _ in 0..<8 { rem <<= 1; if rem & 0x100 != 0 { rem ^= 0xd5 } }
        return UInt8(rem & 0xff)
    }
}
