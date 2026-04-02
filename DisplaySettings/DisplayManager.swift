// DisplayManager.swift
// Discovers connected external displays, reads/writes brightness & contrast via DDCHelper.

import Foundation
import AppKit
import CoreGraphics
import IOKit
import IOKit.graphics

@MainActor
final class DisplayManager: ObservableObject {

    static let shared = DisplayManager()

    @Published var displays: [DisplayModel] = []
    @Published var isRefreshing: Bool = false

    private var pendingWrites:        [CGDirectDisplayID: DispatchWorkItem] = [:]
    private var pendingContrastWrites:[CGDirectDisplayID: DispatchWorkItem] = [:]
    private var pendingVolumeWrites:  [CGDirectDisplayID: DispatchWorkItem] = [:]
    private var pendingColorTempWrites:[CGDirectDisplayID: DispatchWorkItem] = [:]
    private var pendingGainWrites:    [CGDirectDisplayID: DispatchWorkItem] = [:]

    init() {
        Task { await refresh() }
        setupScreenChangeObserver()
        setupAppearanceObserver()
    }

    // MARK: - Computed

    var masterBrightness: Double {
        let active = displays.filter { $0.ddcSupported || $0.usesSoftwareBrightness }
        guard !active.isEmpty else { return 50 }
        return active.map(\.brightness).reduce(0, +) / Double(active.count)
    }

    func capturedPerDisplayBrightness() -> [String: Double] {
        var dict: [String: Double] = [:]
        for display in displays where display.ddcSupported || display.usesSoftwareBrightness {
            dict[display.uniqueID.isEmpty ? display.name : display.uniqueID] = display.brightness
        }
        return dict
    }

    func capturedPerDisplayNames() -> [String: String] {
        var dict: [String: String] = [:]
        for display in displays where display.ddcSupported || display.usesSoftwareBrightness {
            let key = display.uniqueID.isEmpty ? display.name : display.uniqueID
            dict[key] = display.name
        }
        return dict
    }

    // MARK: - Screen connect/disconnect

    private func setupScreenChangeObserver() {
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.refresh()
            }
        }
    }

    // MARK: - Dark mode auto-dim

    private func setupAppearanceObserver() {
        DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("AppleInterfaceThemeChangedNotification"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handleAppearanceChange()
            }
        }
    }

    private func handleAppearanceChange() {
        let settings = SettingsManager.shared
        guard settings.autoDimOnDarkMode else { return }
        let isDark = NSApp.effectiveAppearance.name == .darkAqua ||
                     NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let targetBrightness = isDark ? settings.darkModeDimBrightness : settings.lightModeBrightness
        DebugLogger.shared.log("[DarkMode] Switched to \(isDark ? "dark" : "light"), setting brightness to \(Int(targetBrightness))%")
        setMasterBrightness(targetBrightness)
    }

    // MARK: - Refresh

    func refresh() async {
        isRefreshing = true
        defer { isRefreshing = false }
        displays = await discoverDisplays()
    }

    private func discoverDisplays() async -> [DisplayModel] {
        var models = await Task.detached(priority: .userInitiated) {
            var result: [DisplayModel] = []

            var displayCount: UInt32 = 0
            CGGetActiveDisplayList(0, nil, &displayCount)
            guard displayCount > 0 else { return [DisplayModel]() }
            var displayIDs = [CGDirectDisplayID](repeating: 0, count: Int(displayCount))
            CGGetActiveDisplayList(displayCount, &displayIDs, &displayCount)

            for i in 0..<Int(displayCount) {
                let id = displayIDs[i]
                let isBuiltin = CGDisplayIsBuiltin(id) != 0
                let name = DisplayManager.displayName(for: id)
                var model = DisplayModel(id: id, name: name, isBuiltin: isBuiltin)

                if isBuiltin {
                    // Built-in displays (MacBook Retina, iMac) never use DDC.
                    let swBrightness = SoftwareBrightnessHelper.getBrightness(displayID: id) ?? 100.0
                    model.brightness = min(swBrightness, 100.0)
                    model.ddcSupported = false
                    model.usesSoftwareBrightness = true
                    let serial = CGDisplaySerialNumber(id)
                    model.uniqueID = "BUILTIN_\(serial > 0 ? serial : id)"
                    result.append(model)
                    continue
                }

                if let (val, maxVal) = DDCHelper.readBrightness(displayID: id), maxVal > 0 {
                    model.brightness    = min(max(Double(val) / Double(maxVal) * 100.0, 0), 100)
                    model.maxBrightness = Double(maxVal)
                    model.ddcSupported  = true

                    if let (cVal, cMax) = DDCHelper.readContrast(displayID: id), cMax > 0 {
                        model.contrast    = min(max(Double(cVal) / Double(cMax) * 100.0, 0), 100)
                        model.maxContrast = Double(cMax)
                    }
                    if let (vVal, vMax) = DDCHelper.readVolume(displayID: id), vMax > 0 {
                        model.volume    = min(max(Double(vVal) / Double(vMax) * 100.0, 0), 100)
                        model.maxVolume = Double(vMax)
                    }
                    if let (src, _) = DDCHelper.readInputSource(displayID: id) {
                        model.inputSource = src
                    }
                    if let (ctVal, ctMax) = DDCHelper.readColorTemp(displayID: id), ctMax > 0 {
                        model.colorTemp = min(max(Double(ctVal) / Double(ctMax) * 100.0, 0), 100)
                    }
                    // RGB gains
                    if let (rVal, rMax) = DDCHelper.readGain(displayID: id, channel: 0x16), rMax > 0 {
                        model.gainR = min(max(Double(rVal) / Double(rMax) * 100.0, 0), 100)
                    }
                    if let (gVal, gMax) = DDCHelper.readGain(displayID: id, channel: 0x18), gMax > 0 {
                        model.gainG = min(max(Double(gVal) / Double(gMax) * 100.0, 0), 100)
                    }
                    if let (bVal, bMax) = DDCHelper.readGain(displayID: id, channel: 0x1A), bMax > 0 {
                        model.gainB = min(max(Double(bVal) / Double(bMax) * 100.0, 0), 100)
                    }
                } else {
                    model.ddcSupported = false
                    // Fallback: software brightness via CoreDisplay or gamma table
                    let swBrightness = SoftwareBrightnessHelper.getBrightness(displayID: id) ?? 100.0
                    model.brightness = swBrightness
                    model.usesSoftwareBrightness = true
                }
                // Assign stable unique ID for external displays (used as preset key)
                let stableID = DDCHelper.stableDisplayID(displayID: id)
                model.uniqueID = stableID.isEmpty ? "EXT_\(id)" : stableID
                result.append(model)
            }
            return result
        }.value

        enrichDisplayNames(&models)
        return models
    }

    // MARK: - Brightness

    func setBrightness(_ brightness: Double, for displayID: CGDirectDisplayID) {
        let usesSoftware = displays.first(where: { $0.id == displayID })?.usesSoftwareBrightness ?? false
        if let idx = displays.firstIndex(where: { $0.id == displayID }) {
            displays[idx].brightness = brightness
        }
        pendingWrites[displayID]?.cancel()
        let item = DispatchWorkItem {
            if usesSoftware {
                SoftwareBrightnessHelper.setBrightness(displayID: displayID, value: brightness)
            } else {
                DDCHelper.writeBrightness(displayID: displayID, value: Int(brightness.rounded()))
            }
        }
        pendingWrites[displayID] = item
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 0.3, execute: item)
    }

    func setMasterBrightness(_ brightness: Double) {
        for display in displays where display.ddcSupported || display.usesSoftwareBrightness {
            setBrightness(brightness, for: display.id)
        }
    }

    // MARK: - Contrast

    func setContrast(_ contrast: Double, for displayID: CGDirectDisplayID) {
        if let idx = displays.firstIndex(where: { $0.id == displayID }) {
            displays[idx].contrast = contrast
        }
        pendingContrastWrites[displayID]?.cancel()
        let item = DispatchWorkItem {
            DDCHelper.writeContrast(displayID: displayID, value: Int(contrast.rounded()))
        }
        pendingContrastWrites[displayID] = item
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 0.3, execute: item)
    }

    // MARK: - Volume

    func setVolume(_ volume: Double, for displayID: CGDirectDisplayID) {
        if let idx = displays.firstIndex(where: { $0.id == displayID }) {
            displays[idx].volume = volume
        }
        pendingVolumeWrites[displayID]?.cancel()
        let item = DispatchWorkItem {
            DDCHelper.writeVolume(displayID: displayID, value: Int(volume.rounded()))
        }
        pendingVolumeWrites[displayID] = item
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 0.3, execute: item)
    }

    // MARK: - Color Temperature

    func setColorTemp(_ value: Double, for displayID: CGDirectDisplayID) {
        if let idx = displays.firstIndex(where: { $0.id == displayID }) {
            displays[idx].colorTemp = value
        }
        pendingColorTempWrites[displayID]?.cancel()
        guard let maxVal = displays.first(where: { $0.id == displayID }).map({ $0.maxBrightness }) else { return }
        let rawVal = Int((value / 100.0 * maxVal).rounded())
        let item = DispatchWorkItem {
            DDCHelper.writeColorTemp(displayID: displayID, value: rawVal)
        }
        pendingColorTempWrites[displayID] = item
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 0.3, execute: item)
    }

    // MARK: - RGB Gain

    func setGain(_ value: Double, channel: UInt8, for displayID: CGDirectDisplayID) {
        if let idx = displays.firstIndex(where: { $0.id == displayID }) {
            switch channel {
            case 0x16: displays[idx].gainR = value
            case 0x18: displays[idx].gainG = value
            case 0x1A: displays[idx].gainB = value
            default: break
            }
        }
        pendingGainWrites[displayID]?.cancel()
        let item = DispatchWorkItem {
            DDCHelper.writeGain(displayID: displayID, channel: channel, value: Int(value.rounded()))
        }
        pendingGainWrites[displayID] = item
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 0.3, execute: item)
    }

    // MARK: - Input Source

    func setInputSource(_ source: Int, for displayID: CGDirectDisplayID) {
        if let idx = displays.firstIndex(where: { $0.id == displayID }) {
            displays[idx].inputSource = source
        }
        DispatchQueue.global(qos: .userInitiated).async {
            DDCHelper.writeInputSource(displayID: displayID, value: source)
        }
    }

    // MARK: - Presets

    func applyPreset(_ preset: BrightnessPreset) {
        if preset.perDisplay.isEmpty {
            setMasterBrightness(preset.brightness)
        } else {
            for display in displays where display.ddcSupported || display.usesSoftwareBrightness {
                let key = display.uniqueID.isEmpty ? display.name : display.uniqueID
                let brightness = preset.perDisplay[key] ?? preset.perDisplay[display.name] ?? preset.brightness
                setBrightness(brightness, for: display.id)
            }
        }
    }

    // MARK: - Power

    func setPower(on: Bool, for displayID: CGDirectDisplayID) {
        DispatchQueue.global(qos: .userInitiated).async {
            DDCHelper.setPower(displayID: displayID, on: on)
        }
    }

    // MARK: - Display name resolution

    nonisolated static func displayName(for displayID: CGDirectDisplayID) -> String {
        if let name = ioKitDisplayName(for: displayID), !name.isEmpty { return name }
        return "External Display \(displayID)"
    }

    @MainActor
    func enrichDisplayNames(_ displays: inout [DisplayModel]) {
        for i in displays.indices {
            let id = displays[i].id
            if let screen = NSScreen.screens.first(where: {
                ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID) == id
            }) {
                let localizedName = screen.localizedName
                if !localizedName.isEmpty {
                    displays[i].name = localizedName
                }
                let frame = screen.frame
                displays[i].resolution = "\(Int(frame.width))×\(Int(frame.height))"
            }
        }
    }

    private nonisolated static func ioKitDisplayName(for displayID: CGDirectDisplayID) -> String? {
        let service = DDCHelper.serviceForDisplay(displayID)
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }

        let opts = IOOptionBits(kIODisplayOnlyPreferredName)
        guard let rawInfo = IODisplayCreateInfoDictionary(service, opts) else { return nil }
        let info = rawInfo.takeRetainedValue() as? [String: Any]
        guard let names = info?[kDisplayProductName] as? [String: String],
              let firstName = names.values.first,
              !firstName.isEmpty else { return nil }
        return firstName
    }
}
