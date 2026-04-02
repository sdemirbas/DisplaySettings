// AmbientLightManager.swift
// Reads the ambient light sensor via IOKit AppleLMUController and adjusts brightness.

import Foundation
import IOKit

@MainActor
final class AmbientLightManager: ObservableObject {
    static let shared = AmbientLightManager()

    @Published var isEnabled: Bool = false {
        didSet {
            UserDefaults.standard.set(isEnabled, forKey: "alsSync")
            isEnabled ? startPolling() : stopPolling()
        }
    }

    private var timer: Timer?
    private weak var displayManager: DisplayManager?

    private init() {
        isEnabled = UserDefaults.standard.bool(forKey: "alsSync")
    }

    func start(with dm: DisplayManager) {
        displayManager = dm
        if isEnabled { startPolling() }
    }

    private func startPolling() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.applyALS() }
        }
    }

    private func stopPolling() {
        timer?.invalidate()
        timer = nil
    }

    private func applyALS() {
        guard let lux = readAmbientLight() else { return }
        // Logarithmic mapping: 0 lux → 5%, ~1000 lux → 100%
        let brightness = min(max(log10(lux + 1) / 3.0 * 100.0, 5.0), 100.0)
        displayManager?.setMasterBrightness(brightness)
    }

    private func readAmbientLight() -> Double? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault,
                                                  IOServiceMatching("AppleLMUController"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }

        var properties: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(service, &properties, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let props = properties?.takeRetainedValue() as? [String: Any] else { return nil }

        // The sensor values are under "IOReports" or direct keys depending on hardware
        // Try multiple known key patterns
        if let left = props["IOALSLux"] as? Double {
            return left
        }
        if let sensorData = props["IOALSSensor"] as? [String: Any],
           let value = sensorData["Lux"] as? Double {
            return value
        }
        // Fallback: try raw sensor readings (returned as an array of two UInt32)
        if let rawData = props["IOReports"] as? [[String: Any]] {
            let values = rawData.compactMap { $0["CurrentValue"] as? Double }
            if !values.isEmpty {
                return values.reduce(0, +) / Double(values.count) / 1000.0
            }
        }
        return nil
    }
}
