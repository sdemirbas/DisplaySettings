// DDCHelper.swift
// DDC/CI brightness control via IOAVService (Apple Silicon / DisplayPort + HDMI)
// and IOKit I2C fallback (Intel).
//
// Root cause of "not supported" on Apple Silicon:
//   DCPAVServiceProxy IORegistry entries have NO DisplayAttributes.
//   They only carry a "Location" key ("Embedded" / "External").
//   → Match by Location, not by vendor/product. Use EDID for multi-monitor disambiguation.

import Foundation
import CoreGraphics
import IOKit
import IOKit.i2c
import IOKit.graphics

// MARK: - IOAVService typedefs
// macOS 26+: symbols live in IOKit.framework (public)
// macOS 13-15: symbols live in IOAVService.framework (private)

private typealias AVCreateFunc        = @convention(c) (CFAllocator?) -> UnsafeMutableRawPointer?
private typealias AVCreateWithSvcFunc = @convention(c) (CFAllocator?, io_service_t) -> UnsafeMutableRawPointer?
private typealias AVWriteFunc         = @convention(c) (UnsafeMutableRawPointer, UInt32, UInt32, UnsafeMutableRawPointer, UInt32) -> Int32
private typealias AVReadFunc          = @convention(c) (UnsafeMutableRawPointer, UInt32, UInt32, UnsafeMutableRawPointer, UInt32) -> Int32
private typealias AVCopyEDIDFunc      = @convention(c) (UnsafeMutableRawPointer) -> Unmanaged<CFData>?

// MARK: - DDCHelper

final class DDCHelper {

    private static var avLoaded         = false
    private static var avCreate:        AVCreateFunc?        = nil
    private static var avCreateWithSvc: AVCreateWithSvcFunc? = nil
    private static var avWrite:         AVWriteFunc?         = nil
    private static var avRead:          AVReadFunc?          = nil
    private static var avCopyEDID:      AVCopyEDIDFunc?      = nil

    // MARK: - Logging

    private static func ddcLog(_ message: String) {
        Task { @MainActor in DebugLogger.shared.log(message) }
    }

    // MARK: - Framework loading

    private static func loadAVService() {
        guard !avLoaded else { return }
        avLoaded = true

        // macOS 26+ moved IOAVService symbols into the public IOKit.framework.
        // Older macOS keeps them in the private IOAVService.framework.
        let candidates = [
            "/System/Library/Frameworks/IOKit.framework/IOKit",
            "/System/Library/PrivateFrameworks/IOAVService.framework/IOAVService"
        ]

        var handle: UnsafeMutableRawPointer? = nil
        var loadedPath = ""
        for path in candidates {
            if let h = dlopen(path, RTLD_GLOBAL | RTLD_NOW) {
                if dlsym(h, "IOAVServiceWriteI2C") != nil {
                    handle = h
                    loadedPath = path
                    break
                }
                dlclose(h)
            }
        }

        guard let h = handle else {
            ddcLog("[DDC] IOAVService symbols not found in any framework")
            return
        }
        ddcLog("[DDC] Loaded from: \(loadedPath)")

        if let s = dlsym(h, "IOAVServiceCreate")            { avCreate        = unsafeBitCast(s, to: AVCreateFunc.self) }
        if let s = dlsym(h, "IOAVServiceCreateWithService") { avCreateWithSvc = unsafeBitCast(s, to: AVCreateWithSvcFunc.self) }
        if let s = dlsym(h, "IOAVServiceWriteI2C")          { avWrite         = unsafeBitCast(s, to: AVWriteFunc.self) }
        if let s = dlsym(h, "IOAVServiceReadI2C")           { avRead          = unsafeBitCast(s, to: AVReadFunc.self) }
        if let s = dlsym(h, "IOAVServiceCopyEDID")          { avCopyEDID      = unsafeBitCast(s, to: AVCopyEDIDFunc.self) }
        ddcLog("[DDC] write=\(avWrite != nil) read=\(avRead != nil) copyEDID=\(avCopyEDID != nil)")
    }

    // MARK: - Public API

    static func readBrightness(displayID: CGDirectDisplayID) -> (value: Int, max: Int)? {
        loadAVService()
        if let svc = findAVService(for: displayID) {
            let result = readDDCViaAVService(service: svc, vcp: 0x10)
            if result != nil { return result }
        }
        return readDDCViaIOKit(displayID: displayID, vcp: 0x10)
    }

    @discardableResult
    static func writeBrightness(displayID: CGDirectDisplayID, value: Int) -> Bool {
        loadAVService()
        if let svc = findAVService(for: displayID) {
            if writeDDCViaAVService(service: svc, vcp: 0x10, value: value) { return true }
        }
        return writeDDCViaIOKit(displayID: displayID, vcp: 0x10, value: value)
    }

    // Contrast (VCP 0x12)
    static func readContrast(displayID: CGDirectDisplayID) -> (value: Int, max: Int)? {
        loadAVService()
        if let svc = findAVService(for: displayID) {
            if let r = readDDCViaAVService(service: svc, vcp: 0x12) { return r }
        }
        return readDDCViaIOKit(displayID: displayID, vcp: 0x12)
    }

    @discardableResult
    static func writeContrast(displayID: CGDirectDisplayID, value: Int) -> Bool {
        loadAVService()
        if let svc = findAVService(for: displayID) {
            if writeDDCViaAVService(service: svc, vcp: 0x12, value: value) { return true }
        }
        return writeDDCViaIOKit(displayID: displayID, vcp: 0x12, value: value)
    }

    // Power (VCP 0xD6): 1 = on, 4 = standby/sleep
    @discardableResult
    static func setPower(displayID: CGDirectDisplayID, on: Bool) -> Bool {
        loadAVService()
        let value = on ? 1 : 4
        if let svc = findAVService(for: displayID) {
            if writeDDCViaAVService(service: svc, vcp: 0xD6, value: value) { return true }
        }
        return writeDDCViaIOKit(displayID: displayID, vcp: 0xD6, value: value)
    }

    // Input Source (VCP 0x60)
    // Common values: 0x01=VGA, 0x03=DVI-1, 0x04=DVI-2, 0x0F=DP-1, 0x10=DP-2, 0x11=HDMI-1, 0x12=HDMI-2
    static func readInputSource(displayID: CGDirectDisplayID) -> (value: Int, max: Int)? {
        loadAVService()
        if let svc = findAVService(for: displayID) {
            if let r = readDDCViaAVService(service: svc, vcp: 0x60) { return r }
        }
        return readDDCViaIOKit(displayID: displayID, vcp: 0x60)
    }

    @discardableResult
    static func writeInputSource(displayID: CGDirectDisplayID, value: Int) -> Bool {
        loadAVService()
        if let svc = findAVService(for: displayID) {
            if writeDDCViaAVService(service: svc, vcp: 0x60, value: value) { return true }
        }
        return writeDDCViaIOKit(displayID: displayID, vcp: 0x60, value: value)
    }

    // Volume (VCP 0x62) and Mute (VCP 0x8D: 1=unmute, 2=mute)
    static func readVolume(displayID: CGDirectDisplayID) -> (value: Int, max: Int)? {
        loadAVService()
        if let svc = findAVService(for: displayID) {
            if let r = readDDCViaAVService(service: svc, vcp: 0x62) { return r }
        }
        return readDDCViaIOKit(displayID: displayID, vcp: 0x62)
    }

    @discardableResult
    static func writeVolume(displayID: CGDirectDisplayID, value: Int) -> Bool {
        loadAVService()
        if let svc = findAVService(for: displayID) {
            if writeDDCViaAVService(service: svc, vcp: 0x62, value: value) { return true }
        }
        return writeDDCViaIOKit(displayID: displayID, vcp: 0x62, value: value)
    }

    @discardableResult
    static func setMute(displayID: CGDirectDisplayID, muted: Bool) -> Bool {
        loadAVService()
        let value = muted ? 2 : 1
        if let svc = findAVService(for: displayID) {
            if writeDDCViaAVService(service: svc, vcp: 0x8D, value: value) { return true }
        }
        return writeDDCViaIOKit(displayID: displayID, vcp: 0x8D, value: value)
    }

    // Color Temperature (VCP 0xB2) — value in 100K steps, e.g. 50 = 5000K
    static func readColorTemp(displayID: CGDirectDisplayID) -> (value: Int, max: Int)? {
        loadAVService()
        if let svc = findAVService(for: displayID) {
            if let r = readDDCViaAVService(service: svc, vcp: 0xB2) { return r }
        }
        return readDDCViaIOKit(displayID: displayID, vcp: 0xB2)
    }

    @discardableResult
    static func writeColorTemp(displayID: CGDirectDisplayID, value: Int) -> Bool {
        loadAVService()
        if let svc = findAVService(for: displayID) {
            if writeDDCViaAVService(service: svc, vcp: 0xB2, value: value) { return true }
        }
        return writeDDCViaIOKit(displayID: displayID, vcp: 0xB2, value: value)
    }

    // RGB Gain: R=0x16, G=0x18, B=0x1A (0–255, monitor-dependent)
    static func readGain(displayID: CGDirectDisplayID, channel: UInt8) -> (value: Int, max: Int)? {
        loadAVService()
        if let svc = findAVService(for: displayID) {
            if let r = readDDCViaAVService(service: svc, vcp: channel) { return r }
        }
        return readDDCViaIOKit(displayID: displayID, vcp: channel)
    }

    @discardableResult
    static func writeGain(displayID: CGDirectDisplayID, channel: UInt8, value: Int) -> Bool {
        loadAVService()
        if let svc = findAVService(for: displayID) {
            if writeDDCViaAVService(service: svc, vcp: channel, value: value) { return true }
        }
        return writeDDCViaIOKit(displayID: displayID, vcp: channel, value: value)
    }

    // MARK: - IOAVService discovery
    //
    // Strategy:
    //   1. Collect all DCPAVServiceProxy (+ IOAVService) entries where Location = "External".
    //   2. Single external display  → use the first (only) external entry directly.
    //   3. Multiple external displays → read EDID from each service, compare vendor/product
    //      with CGDisplayVendorNumber / CGDisplayModelNumber to find the right one.
    //   4. EDID read fails          → fall back to index-ordering (sort by registry ID).

    static func findAVService(for displayID: CGDirectDisplayID) -> UnsafeMutableRawPointer? {
        guard avWrite != nil || avRead != nil else { return nil }

        var externalEntries: [io_service_t] = []

        for className in ["DCPAVServiceProxy", "IOAVService"] {
            guard let matching = IOServiceMatching(className) else { continue }
            var iter: io_iterator_t = 0
            guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iter) == KERN_SUCCESS else { continue }

            var entry = IOIteratorNext(iter)
            while entry != 0 {
                if ioStringProperty(entry, key: "Location") == "External" {
                    externalEntries.append(entry)
                } else {
                    IOObjectRelease(entry)
                }
                entry = IOIteratorNext(iter)
            }
            IOObjectRelease(iter)

            if !externalEntries.isEmpty { break }
        }

        defer { externalEntries.forEach { IOObjectRelease($0) } }

        guard !externalEntries.isEmpty else {
            ddcLog("[DDC] No external DCPAVServiceProxy found — is the monitor connected?")
            return nil
        }

        // Count active external displays
        var count: UInt32 = 0
        CGGetActiveDisplayList(0, nil, &count)
        var allIDs = [CGDirectDisplayID](repeating: 0, count: max(Int(count), 1))
        CGGetActiveDisplayList(count, &allIDs, &count)
        let externalCount = (0..<Int(count)).filter { CGDisplayIsBuiltin(allIDs[$0]) == 0 }.count

        // ── Fast path: only one external display ──────────────────────────────
        if externalCount <= 1 {
            let svc = makeAVService(from: externalEntries[0])
            ddcLog("[DDC] Single external display — fast path, service=\(String(describing: svc))")
            return svc
        }

        // ── Multi-display path: match by EDID ────────────────────────────────
        let targetVendor  = CGDisplayVendorNumber(displayID)
        let targetProduct = CGDisplayModelNumber(displayID)
        ddcLog("[DDC] Multi-display matching vendor=\(targetVendor) product=\(targetProduct)")

        let sorted = externalEntries.sorted {
            var a: UInt64 = 0; var b: UInt64 = 0
            IORegistryEntryGetRegistryEntryID($0, &a)
            IORegistryEntryGetRegistryEntryID($1, &b)
            return a < b
        }

        for entry in sorted {
            guard let svc = makeAVService(from: entry) else { continue }
            if let edid = readEDID(service: svc) {
                let edidVendor  = (UInt32(edid[8]) << 8) | UInt32(edid[9])
                let edidProduct = UInt32(edid[10]) | (UInt32(edid[11]) << 8)
                ddcLog("[DDC] EDID: vendor=\(edidVendor) product=\(edidProduct)")
                if edidVendor == targetVendor && edidProduct == targetProduct {
                    return svc
                }
            }
        }

        // Last resort: index-based fallback
        let extDisplays = (0..<Int(count)).map { allIDs[$0] }.filter { CGDisplayIsBuiltin($0) == 0 }.sorted()
        if let idx = extDisplays.firstIndex(of: displayID), idx < sorted.count {
            return makeAVService(from: sorted[idx])
        }

        return makeAVService(from: sorted[0])
    }

    private static func makeAVService(from entry: io_service_t) -> UnsafeMutableRawPointer? {
        if let fn = avCreateWithSvc { return fn(kCFAllocatorDefault, entry) }
        if let fn = avCreate        { return fn(kCFAllocatorDefault) }
        return nil
    }

    // MARK: - EDID reading (for multi-monitor matching)

    static func readEDID(service: UnsafeMutableRawPointer) -> [UInt8]? {
        if let copyFn = avCopyEDID, let cfData = copyFn(service)?.takeRetainedValue() {
            let bytes = Array(cfData as Data)
            if bytes.count >= 8 && bytes[0] == 0x00 && bytes[1] == 0xFF { return bytes }
        }
        guard let readFn = avRead else { return nil }
        var edid = [UInt8](repeating: 0, count: 128)
        let ret = edid.withUnsafeMutableBytes { ptr -> Int32 in
            readFn(service, 0x50, 0x00, ptr.baseAddress!, 128)
        }
        guard ret == 0, edid[0] == 0x00, edid[1] == 0xFF else { return nil }
        return edid
    }

    /// Extracts the serial number string from EDID descriptor blocks (bytes 54-125).
    /// Each descriptor is 18 bytes. Type 0xFF = serial number descriptor.
    static func extractEDIDSerial(edid: [UInt8]) -> String? {
        guard edid.count >= 128 else { return nil }
        for blockStart in stride(from: 54, to: 126, by: 18) {
            guard edid[blockStart]     == 0x00,
                  edid[blockStart + 1] == 0x00,
                  edid[blockStart + 2] == 0x00,
                  edid[blockStart + 3] == 0xFF else { continue }
            let serialBytes = edid[(blockStart + 5)..<min(blockStart + 18, edid.count)]
            let chars = serialBytes
                .prefix(while: { $0 != 0x0A && $0 != 0x00 })
                .compactMap { $0 > 31 ? Character(UnicodeScalar($0)) : nil }
            return chars.isEmpty ? nil : String(chars)
        }
        return nil
    }

    /// Returns a stable string identifier for an external display using EDID vendor, product, and serial.
    /// Format: "V<vendor>_P<product>_S<serial>" or "V<vendor>_P<product>" if serial not available.
    static func stableDisplayID(displayID: CGDirectDisplayID) -> String {
        loadAVService()
        let vendor  = CGDisplayVendorNumber(displayID)
        let product = CGDisplayModelNumber(displayID)
        var serialPart = ""
        if let svc = findAVService(for: displayID),
           let edid = readEDID(service: svc),
           let serial = extractEDIDSerial(edid: edid) {
            serialPart = "_S\(serial)"
        }
        return "V\(vendor)_P\(product)\(serialPart)"
    }

    // MARK: - IOAVService DDC write / read

    private static func writeDDCViaAVService(service: UnsafeMutableRawPointer, vcp: UInt8, value: Int) -> Bool {
        guard let writeFn = avWrite else { return false }
        let hi = UInt8((value >> 8) & 0xFF)
        let lo = UInt8(value & 0xFF)
        var p: [UInt8] = [0x84, 0x03, vcp, hi, lo, 0x00]
        p[5] = ddcChecksum(dest: 0x6E, src: 0x51, bytes: Array(p.prefix(5)))
        let pLen = UInt32(p.count)
        return p.withUnsafeMutableBytes { ptr in
            writeFn(service, 0x37, 0x51, ptr.baseAddress!, pLen) == 0
        }
    }

    private static func readDDCViaAVService(service: UnsafeMutableRawPointer, vcp: UInt8) -> (value: Int, max: Int)? {
        guard let writeFn = avWrite, let readFn = avRead else { return nil }

        let cs = ddcChecksum(dest: 0x6E, src: 0x51, bytes: [0x82, 0x01, vcp])
        var req: [UInt8] = [0x82, 0x01, vcp, cs]
        let reqLen = UInt32(req.count)
        let wRet = req.withUnsafeMutableBytes { ptr -> Int32 in
            writeFn(service, 0x37, 0x51, ptr.baseAddress!, reqLen)
        }
        guard wRet == 0 else {
            ddcLog("[DDC] AVService write failed: \(wRet) vcp=0x\(String(vcp, radix: 16))")
            return nil
        }

        Thread.sleep(forTimeInterval: 0.05)

        var reply = [UInt8](repeating: 0, count: 12)
        let replyLen = UInt32(reply.count)
        let rRet = reply.withUnsafeMutableBytes { ptr -> Int32 in
            readFn(service, 0x37, 0x51, ptr.baseAddress!, replyLen)
        }
        guard rRet == 0 else {
            ddcLog("[DDC] AVService read failed: \(rRet) vcp=0x\(String(vcp, radix: 16))")
            return nil
        }
        return parseDDCReply(reply)
    }

    // MARK: - IOKit I2C fallback (Intel Macs)

    private static func writeDDCViaIOKit(displayID: CGDirectDisplayID, vcp: UInt8, value: Int) -> Bool {
        guard let fb = framebufferForDisplay(displayID) else { return false }
        defer { IOObjectRelease(fb) }
        var busCount: UInt32 = 0
        guard IOFBGetI2CInterfaceCount(fb, &busCount) == KERN_SUCCESS, busCount > 0 else { return false }

        for bus: UInt32 in 0..<busCount {
            var intf: io_service_t = 0
            guard IOFBCopyI2CInterfaceForBus(fb, bus, &intf) == KERN_SUCCESS else { continue }
            defer { IOObjectRelease(intf) }
            var conn: OpaquePointer? = nil
            guard IOI2CInterfaceOpen(intf, 0, &conn) == KERN_SUCCESS, let c = conn else { continue }
            defer { IOI2CInterfaceClose(c, 0) }

            let hi = UInt8((value >> 8) & 0xFF)
            let lo = UInt8(value & 0xFF)
            var p: [UInt8] = [0x84, 0x03, vcp, hi, lo, 0x00]
            p[5] = ddcChecksum(dest: 0x6E, src: 0x51, bytes: Array(p.prefix(5)))

            var req = IOI2CRequest()
            req.sendTransactionType  = UInt32(kIOI2CSimpleTransactionType)
            req.replyTransactionType = UInt32(kIOI2CNoTransactionType)
            req.sendAddress = 0x6E
            req.commFlags   = 0
            req.replyBytes  = 0
            req.sendBytes   = UInt32(p.count)
            req.minReplyDelay = 0
            let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: p.count)
            buf.initialize(from: p, count: p.count)
            defer { buf.deallocate() }
            req.sendBuffer = UInt(bitPattern: buf)
            if IOI2CSendRequest(c, 0, &req) == KERN_SUCCESS && req.result == KERN_SUCCESS { return true }
        }
        return false
    }

    private static func readDDCViaIOKit(displayID: CGDirectDisplayID, vcp: UInt8) -> (value: Int, max: Int)? {
        guard let fb = framebufferForDisplay(displayID) else { return nil }
        defer { IOObjectRelease(fb) }
        var busCount: UInt32 = 0
        guard IOFBGetI2CInterfaceCount(fb, &busCount) == KERN_SUCCESS, busCount > 0 else { return nil }

        for bus: UInt32 in 0..<busCount {
            var intf: io_service_t = 0
            guard IOFBCopyI2CInterfaceForBus(fb, bus, &intf) == KERN_SUCCESS else { continue }
            defer { IOObjectRelease(intf) }
            var conn: OpaquePointer? = nil
            guard IOI2CInterfaceOpen(intf, 0, &conn) == KERN_SUCCESS, let c = conn else { continue }
            defer { IOI2CInterfaceClose(c, 0) }

            let cs = ddcChecksum(dest: 0x6E, src: 0x51, bytes: [0x82, 0x01, vcp])
            var reqBytes: [UInt8] = [0x82, 0x01, vcp, cs]
            var sendReq = IOI2CRequest()
            sendReq.sendTransactionType  = UInt32(kIOI2CSimpleTransactionType)
            sendReq.replyTransactionType = UInt32(kIOI2CNoTransactionType)
            sendReq.sendAddress = 0x6E
            sendReq.commFlags   = 0
            sendReq.replyBytes  = 0
            sendReq.sendBytes   = UInt32(reqBytes.count)
            sendReq.minReplyDelay = 0
            let sBuf = UnsafeMutablePointer<UInt8>.allocate(capacity: reqBytes.count)
            sBuf.initialize(from: reqBytes, count: reqBytes.count)
            defer { sBuf.deallocate() }
            sendReq.sendBuffer = UInt(bitPattern: sBuf)
            guard IOI2CSendRequest(c, 0, &sendReq) == KERN_SUCCESS && sendReq.result == KERN_SUCCESS else { continue }

            Thread.sleep(forTimeInterval: 0.05)

            var replyBuf = [UInt8](repeating: 0, count: 12)
            var recvReq = IOI2CRequest()
            recvReq.sendTransactionType  = UInt32(kIOI2CNoTransactionType)
            recvReq.replyTransactionType = UInt32(kIOI2CDDCciReplyTransactionType)
            recvReq.replyAddress  = 0x6F
            recvReq.commFlags     = 0
            recvReq.sendBytes     = 0
            recvReq.replyBytes    = UInt32(replyBuf.count)
            recvReq.minReplyDelay = 50_000_000
            let rBuf = UnsafeMutablePointer<UInt8>.allocate(capacity: replyBuf.count)
            rBuf.initialize(from: replyBuf, count: replyBuf.count)
            defer { rBuf.deallocate() }
            recvReq.replyBuffer = UInt(bitPattern: rBuf)
            guard IOI2CSendRequest(c, 0, &recvReq) == KERN_SUCCESS && recvReq.result == KERN_SUCCESS else { continue }
            for i in 0..<replyBuf.count { replyBuf[i] = rBuf[i] }
            if let parsed = parseDDCReply(replyBuf) { return parsed }
        }
        return nil
    }

    // MARK: - Display name (for DisplayManager)

    static func serviceForDisplay(_ displayID: CGDirectDisplayID) -> io_service_t {
        let vendor  = CGDisplayVendorNumber(displayID)
        let product = CGDisplayModelNumber(displayID)
        let serial  = CGDisplaySerialNumber(displayID)

        for className in ["IOMobileFramebufferAP", "AppleCLCD2"] {
            guard let matching = IOServiceMatching(className) else { continue }
            var iter: io_iterator_t = 0
            guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iter) == KERN_SUCCESS else { continue }
            defer { IOObjectRelease(iter) }

            var entry = IOIteratorNext(iter)
            while entry != 0 {
                if matchesDisplayAttributes(entry, vendor: vendor, product: product, serial: serial) {
                    return entry
                }
                IOObjectRelease(entry)
                entry = IOIteratorNext(iter)
            }
        }
        return 0
    }

    private static func matchesDisplayAttributes(_ entry: io_service_t, vendor: UInt32, product: UInt32, serial: UInt32) -> Bool {
        var raw: Unmanaged<CFMutableDictionary>? = nil
        guard IORegistryEntryCreateCFProperties(entry, &raw, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let props = raw?.takeRetainedValue() as? [String: Any],
              let attrs = props["DisplayAttributes"] as? [String: Any],
              let prod  = attrs["ProductAttributes"]  as? [String: Any] else { return false }

        let v = nsNumberUInt32(prod["LegacyManufacturerID"])
        let p = nsNumberUInt32(prod["ProductID"])
        let s = nsNumberUInt32(prod["SerialNumber"])
        return v == vendor && p == product && (s == serial || serial == 0 || s == 0)
    }

    // MARK: - Helpers

    private static func framebufferForDisplay(_ displayID: CGDirectDisplayID) -> io_service_t? {
        let unit = CGDisplayUnitNumber(displayID)
        var iter: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault,
                IOServiceMatching("IOFramebuffer"), &iter) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iter) }

        var entry = IOIteratorNext(iter)
        while entry != 0 {
            var raw: Unmanaged<CFMutableDictionary>? = nil
            if IORegistryEntryCreateCFProperties(entry, &raw, kCFAllocatorDefault, 0) == KERN_SUCCESS,
               let props = raw?.takeRetainedValue() as? [String: Any],
               let fbUnit = props["IOFramebufferOpenGLIndex"] as? UInt32,
               fbUnit == unit {
                return entry
            }
            IOObjectRelease(entry)
            entry = IOIteratorNext(iter)
        }
        return nil
    }

    private static func ioStringProperty(_ entry: io_service_t, key: String) -> String? {
        var raw: Unmanaged<CFMutableDictionary>? = nil
        guard IORegistryEntryCreateCFProperties(entry, &raw, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let props = raw?.takeRetainedValue() as? [String: Any] else { return nil }
        return props[key] as? String
    }

    private static func nsNumberUInt32(_ val: Any?) -> UInt32 {
        switch val {
        case let n as UInt32:  return n
        case let n as Int:     return UInt32(bitPattern: Int32(truncatingIfNeeded: n))
        case let n as Int32:   return UInt32(bitPattern: n)
        case let n as NSNumber: return n.uint32Value
        default: return 0
        }
    }

    private static func ddcChecksum(dest: UInt8, src: UInt8, bytes: [UInt8]) -> UInt8 {
        var cs = dest ^ src
        for b in bytes { cs ^= b }
        return cs
    }

    private static func parseDDCReply(_ bytes: [UInt8]) -> (value: Int, max: Int)? {
        guard bytes.count >= 8 else { return nil }
        var off = 0
        for i in 0...(bytes.count - 8) { if bytes[i] == 0x02 { off = i; break } }
        guard off + 7 < bytes.count, bytes[off + 1] == 0x00 else { return nil }
        let maxVal = (Int(bytes[off + 4]) << 8) | Int(bytes[off + 5])
        let curVal = (Int(bytes[off + 6]) << 8) | Int(bytes[off + 7])
        guard maxVal > 0 else { return nil }
        return (value: curVal, max: maxVal)
    }
}
