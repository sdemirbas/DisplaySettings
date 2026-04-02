// AppBrightnessManager.swift
// Monitors app activation and applies per-app brightness rules.

import Foundation
import AppKit

struct AppBrightnessRule: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var bundleID: String   // e.g. "com.apple.QuickTimePlayer"
    var appName: String    // e.g. "QuickTime Player"
    var brightness: Double // 0–100 direct brightness override
}

@MainActor
final class AppBrightnessManager: ObservableObject {
    static let shared = AppBrightnessManager()

    @Published var rules: [AppBrightnessRule] = [] {
        didSet { saveRules() }
    }
    @Published var isEnabled: Bool = false {
        didSet { UserDefaults.standard.set(isEnabled, forKey: "appAwareBrightness") }
    }

    private weak var displayManager: DisplayManager?
    private var previousBrightness: Double = 50

    private init() {
        isEnabled = UserDefaults.standard.bool(forKey: "appAwareBrightness")
        rules = loadRules()
    }

    func start(with dm: DisplayManager) {
        displayManager = dm
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self,
                  let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  let bundleID = app.bundleIdentifier else { return }
            Task { @MainActor in self.applyRule(for: bundleID, appName: app.localizedName ?? bundleID) }
        }
    }

    private func applyRule(for bundleID: String, appName: String) {
        guard isEnabled else { return }
        if let rule = rules.first(where: { $0.bundleID == bundleID }) {
            if let dm = displayManager {
                previousBrightness = dm.masterBrightness
                dm.setMasterBrightness(rule.brightness)
            }
        }
    }

    func addRule(bundleID: String, appName: String, brightness: Double) {
        rules.removeAll { $0.bundleID == bundleID }
        rules.append(AppBrightnessRule(bundleID: bundleID, appName: appName, brightness: brightness))
    }

    func removeRule(id: UUID) {
        rules.removeAll { $0.id == id }
    }

    private func saveRules() {
        if let data = try? JSONEncoder().encode(rules) {
            UserDefaults.standard.set(data, forKey: "appBrightnessRules")
        }
    }

    private func loadRules() -> [AppBrightnessRule] {
        guard let data = UserDefaults.standard.data(forKey: "appBrightnessRules"),
              let saved = try? JSONDecoder().decode([AppBrightnessRule].self, from: data)
        else { return [] }
        return saved
    }
}
