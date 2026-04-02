// NitIntents.swift
// Apple Shortcuts / AppIntents integration (macOS 13+)

import AppIntents
import Foundation

// MARK: - Set Brightness

struct SetBrightnessIntent: AppIntent {
    static var title: LocalizedStringResource = "Set Display Brightness"
    static var description = IntentDescription("Sets brightness for all connected displays.")

    @Parameter(title: "Brightness", description: "Brightness percentage (0–100)", inclusiveRange: (0, 100))
    var brightness: Int

    func perform() async throws -> some IntentResult {
        await MainActor.run {
            DisplayManager.shared.setMasterBrightness(Double(brightness))
        }
        return .result()
    }
}

// MARK: - Get Brightness

struct GetBrightnessIntent: AppIntent {
    static var title: LocalizedStringResource = "Get Display Brightness"
    static var description = IntentDescription("Returns the current average brightness across all displays.")

    func perform() async throws -> some IntentResult & ReturnsValue<Int> {
        let value = await MainActor.run { Int(DisplayManager.shared.masterBrightness.rounded()) }
        return .result(value: value)
    }
}

// MARK: - Apply Preset

struct ApplyPresetIntent: AppIntent {
    static var title: LocalizedStringResource = "Apply Display Preset"
    static var description = IntentDescription("Applies a saved brightness preset by name.")

    @Parameter(title: "Preset Name", description: "The exact name of the saved preset")
    var presetName: String

    func perform() async throws -> some IntentResult {
        let applied = await MainActor.run { () -> Bool in
            let settings = SettingsManager.shared
            if let preset = settings.presets.first(where: { $0.name.lowercased() == presetName.lowercased() }) {
                DisplayManager.shared.applyPreset(preset)
                return true
            }
            return false
        }
        if !applied {
            throw IntentError.notFound(presetName)
        }
        return .result()
    }

    enum IntentError: Swift.Error, CustomLocalizedStringResourceConvertible {
        case notFound(String)
        var localizedStringResource: LocalizedStringResource {
            switch self {
            case .notFound(let name):
                return "Preset '\(name)' not found. Check Settings for available presets."
            }
        }
    }
}

// MARK: - Shortcuts App Configuration

@available(macOS 13, *)
struct NitShortcutsProvider: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: SetBrightnessIntent(),
            phrases: ["Set display brightness with \(.applicationName)", "Dim displays with \(.applicationName)"],
            shortTitle: "Set Brightness",
            systemImageName: "sun.max"
        )
        AppShortcut(
            intent: GetBrightnessIntent(),
            phrases: ["Get display brightness with \(.applicationName)"],
            shortTitle: "Get Brightness",
            systemImageName: "sun.min"
        )
    }
}
