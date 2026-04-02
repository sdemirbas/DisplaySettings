// AppDelegate.swift
// Entry point for the menu bar app. No Dock icon (LSUIElement = true in Info.plist).

import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {

    private var statusBarController: StatusBarController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusBarController = StatusBarController()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false  // Never quit when windows close; quit via menu item
    }

    // Handle nit:// URLs from terminal: open "nit://brightness?value=50"
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            guard url.scheme == "nit" else { continue }
            handleNitURL(url)
        }
    }

    private func handleNitURL(_ url: URL) {
        let host = url.host ?? ""
        let queryItems = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []

        func queryValue(_ name: String) -> String? {
            queryItems.first(where: { $0.name == name })?.value
        }

        Task { @MainActor in
            let dm = DisplayManager.shared

            switch host {
            case "brightness":
                if let valueStr = queryValue("value"), let value = Double(valueStr) {
                    dm.setMasterBrightness(max(0, min(100, value)))
                }

            case "preset":
                if let name = queryValue("name") {
                    let settings = SettingsManager.shared
                    if let preset = settings.presets.first(where: { $0.name.lowercased() == name.lowercased() }) {
                        dm.applyPreset(preset)
                    }
                }

            case "display":
                // nit://display/0/brightness?value=75
                let components = url.pathComponents.filter { $0 != "/" }
                if components.count >= 2,
                   let index = Int(components[0]),
                   components[1] == "brightness",
                   let valueStr = queryValue("value"),
                   let value = Double(valueStr) {
                    let displays = dm.displays.filter { $0.ddcSupported || $0.usesSoftwareBrightness }
                    if index < displays.count {
                        dm.setBrightness(max(0, min(100, value)), for: displays[index].id)
                    }
                }

            default:
                break
            }
        }
    }
}
