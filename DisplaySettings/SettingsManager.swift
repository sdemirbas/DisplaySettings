// SettingsManager.swift
// Persistent app preferences: launch at login, presets, menu bar indicator, dark mode dim.

import Foundation
import ServiceManagement

struct BrightnessPreset: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var name: String
    var brightness: Double
    var perDisplay: [String: Double] = [:]  // displayName → brightness
}

@MainActor
final class SettingsManager: ObservableObject {
    static let shared = SettingsManager()

    @Published var launchAtLogin: Bool {
        didSet { applyLaunchAtLogin() }
    }
    @Published var showBrightnessInMenuBar: Bool {
        didSet { UserDefaults.standard.set(showBrightnessInMenuBar, forKey: Keys.menuBar) }
    }
    @Published var presets: [BrightnessPreset] {
        didSet { savePresets() }
    }
    @Published var autoDimOnDarkMode: Bool {
        didSet { UserDefaults.standard.set(autoDimOnDarkMode, forKey: Keys.autoDim) }
    }
    @Published var darkModeDimBrightness: Double {
        didSet { UserDefaults.standard.set(darkModeDimBrightness, forKey: Keys.darkBrightness) }
    }
    @Published var lightModeBrightness: Double {
        didSet { UserDefaults.standard.set(lightModeBrightness, forKey: Keys.lightBrightness) }
    }

    private enum Keys {
        static let menuBar        = "showBrightnessInMenuBar"
        static let presets        = "brightnessPresets"
        static let autoDim        = "autoDimOnDarkMode"
        static let darkBrightness = "darkModeDimBrightness"
        static let lightBrightness = "lightModeBrightness"
    }

    private init() {
        launchAtLogin          = SMAppService.mainApp.status == .enabled
        showBrightnessInMenuBar = UserDefaults.standard.bool(forKey: Keys.menuBar)
        presets                = Self.loadPresets()
        autoDimOnDarkMode      = UserDefaults.standard.bool(forKey: Keys.autoDim)
        let dark  = UserDefaults.standard.double(forKey: Keys.darkBrightness)
        let light = UserDefaults.standard.double(forKey: Keys.lightBrightness)
        darkModeDimBrightness  = dark  > 0 ? dark  : 30
        lightModeBrightness    = light > 0 ? light : 80
    }

    // MARK: - Actions

    func addPreset(name: String, brightness: Double, perDisplay: [String: Double] = [:]) {
        presets.append(BrightnessPreset(name: name, brightness: brightness, perDisplay: perDisplay))
    }

    func deletePreset(id: UUID) {
        presets.removeAll { $0.id == id }
    }

    // MARK: - Private

    private func applyLaunchAtLogin() {
        do {
            if launchAtLogin {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            Task { @MainActor in DebugLogger.shared.log("[Settings] Launch at login error: \(error)") }
        }
    }

    private func savePresets() {
        if let data = try? JSONEncoder().encode(presets) {
            UserDefaults.standard.set(data, forKey: Keys.presets)
        }
    }

    private static func loadPresets() -> [BrightnessPreset] {
        if let data = UserDefaults.standard.data(forKey: Keys.presets),
           let saved = try? JSONDecoder().decode([BrightnessPreset].self, from: data) {
            return saved
        }
        return [
            BrightnessPreset(name: "Day",     brightness: 80),
            BrightnessPreset(name: "Evening", brightness: 50),
            BrightnessPreset(name: "Night",   brightness: 20),
        ]
    }
}
