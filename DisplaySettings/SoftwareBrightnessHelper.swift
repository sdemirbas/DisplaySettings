// SoftwareBrightnessHelper.swift
// Software brightness fallback for displays that do not support DDC/CI
// (e.g. Samsung Smart M-series over USB-C).
//
// Strategy:
//   1. Try CoreDisplay.framework DisplayServicesSetBrightness — works on some USB-C monitors.
//   2. Fall back to CGSetDisplayTransferByFormula (gamma-table dimming, works everywhere).

import Foundation
import CoreGraphics

final class SoftwareBrightnessHelper {

    // MARK: - CoreDisplay private symbols

    private typealias CDGetFunc = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
    private typealias CDSetFunc = @convention(c) (CGDirectDisplayID, Float) -> Int32

    private static var cdLoaded = false
    private static var cdGet: CDGetFunc? = nil
    private static var cdSet: CDSetFunc? = nil

    private static func loadCoreDisplay() {
        guard !cdLoaded else { return }
        cdLoaded = true
        guard let h = dlopen(
            "/System/Library/Frameworks/CoreDisplay.framework/CoreDisplay",
            RTLD_GLOBAL | RTLD_NOW
        ) else { return }
        if let s = dlsym(h, "DisplayServicesGetBrightness") {
            cdGet = unsafeBitCast(s, to: CDGetFunc.self)
        }
        if let s = dlsym(h, "DisplayServicesSetBrightness") {
            cdSet = unsafeBitCast(s, to: CDSetFunc.self)
        }
    }

    // MARK: - Public API

    /// Returns current software brightness (0–100), or nil if unreadable.
    static func getBrightness(displayID: CGDirectDisplayID) -> Double? {
        loadCoreDisplay()
        if let fn = cdGet {
            var val: Float = 0
            if fn(displayID, &val) == 0, val > 0 {
                return Double(val) * 100.0
            }
        }
        return gammaBasedBrightness(displayID: displayID)
    }

    /// Sets brightness (0–100) via CoreDisplay or CGGamma. Returns true on success.
    @discardableResult
    static func setBrightness(displayID: CGDirectDisplayID, value: Double) -> Bool {
        loadCoreDisplay()
        let clamped = max(0.0, min(100.0, value))
        if let fn = cdSet {
            if fn(displayID, Float(clamped / 100.0)) == 0 { return true }
        }
        return setGammaBrightness(displayID: displayID, value: clamped)
    }

    /// Resets gamma table to default (call on app quit or display disconnect).
    static func reset(displayID: CGDirectDisplayID) {
        CGDisplayRestoreColorSyncSettings()
    }

    // MARK: - Gamma helpers

    private static func setGammaBrightness(displayID: CGDirectDisplayID, value: Double) -> Bool {
        let cap = CGGammaValue(value / 100.0)
        let err = CGSetDisplayTransferByFormula(
            displayID,
            0, cap, 1,   // red:   min, max, gamma
            0, cap, 1,   // green
            0, cap, 1    // blue
        )
        return err == .success
    }

    private static func gammaBasedBrightness(displayID: CGDirectDisplayID) -> Double? {
        var rMin: CGGammaValue = 0, rMax: CGGammaValue = 1, rGamma: CGGammaValue = 1
        var gMin: CGGammaValue = 0, gMax: CGGammaValue = 1, gGamma: CGGammaValue = 1
        var bMin: CGGammaValue = 0, bMax: CGGammaValue = 1, bGamma: CGGammaValue = 1
        let err = CGGetDisplayTransferByFormula(
            displayID,
            &rMin, &rMax, &rGamma,
            &gMin, &gMax, &gGamma,
            &bMin, &bMax, &bGamma
        )
        guard err == .success else { return nil }
        let avg = Double((rMax + gMax + bMax) / 3)
        // Only return if it looks like we previously applied a gamma change
        // (avoid reporting 100% for a fresh display as 100% — that's fine, it means full brightness)
        return avg * 100.0
    }
}
