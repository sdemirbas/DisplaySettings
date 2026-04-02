// HotkeyManager.swift
// Global keyboard shortcuts using Carbon RegisterEventHotKey.
// Default bindings:
//   Ctrl+Cmd+Up    → brightness +5% (all displays)
//   Ctrl+Cmd+Down  → brightness -5% (all displays)
// Optional bindings (when f1f2BrightnessKeys is enabled):
//   F1             → brightness -5% (all displays)
//   F2             → brightness +5% (all displays)

import Foundation
import Carbon

@MainActor
final class HotkeyManager {
    static let shared = HotkeyManager()

    private var hotkeys: [EventHotKeyRef] = []
    private var handler: EventHandlerRef?
    private weak var _displayManager: DisplayManager?

    private init() {}

    // MARK: - Registration

    func register(displayManager: DisplayManager) {
        _displayManager = displayManager
        unregister()

        // Install the Carbon event handler once
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                      eventKind:  OSType(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(),
                            { _, event, refCon -> OSStatus in
                                guard let ctx = refCon else { return OSStatus(eventNotHandledErr) }
                                let manager = Unmanaged<HotkeyManagerProxy>.fromOpaque(ctx).takeUnretainedValue()
                                manager.handle(event)
                                return noErr
                            },
                            1, &eventType,
                            Unmanaged.passRetained(HotkeyManagerProxy(displayManager: displayManager)).toOpaque(),
                            &handler)

        // Ctrl+Cmd+Up = ID 1
        var upRef: EventHotKeyRef?
        var upID = EventHotKeyID(signature: OSType(0x4453_5000), id: 1)
        RegisterEventHotKey(UInt32(kVK_UpArrow),
                            UInt32(cmdKey | controlKey),
                            upID, GetApplicationEventTarget(), 0, &upRef)
        if let ref = upRef { hotkeys.append(ref) }

        // Ctrl+Cmd+Down = ID 2
        var downRef: EventHotKeyRef?
        var downID = EventHotKeyID(signature: OSType(0x4453_5000), id: 2)
        RegisterEventHotKey(UInt32(kVK_DownArrow),
                            UInt32(cmdKey | controlKey),
                            downID, GetApplicationEventTarget(), 0, &downRef)
        if let ref = downRef { hotkeys.append(ref) }

        // F1/F2 optional bindings (ID 3 and ID 4)
        if SettingsManager.shared.f1f2BrightnessKeys {
            // F1 = ID 3 → brightness -5%
            var f1Ref: EventHotKeyRef?
            var f1ID = EventHotKeyID(signature: OSType(0x4453_5000), id: 3)
            RegisterEventHotKey(UInt32(kVK_F1),
                                0,
                                f1ID, GetApplicationEventTarget(), 0, &f1Ref)
            if let ref = f1Ref { hotkeys.append(ref) }

            // F2 = ID 4 → brightness +5%
            var f2Ref: EventHotKeyRef?
            var f2ID = EventHotKeyID(signature: OSType(0x4453_5000), id: 4)
            RegisterEventHotKey(UInt32(kVK_F2),
                                0,
                                f2ID, GetApplicationEventTarget(), 0, &f2Ref)
            if let ref = f2Ref { hotkeys.append(ref) }
        }
    }

    /// Re-registers hotkeys using the previously stored DisplayManager reference.
    /// Called when settings (e.g. f1f2BrightnessKeys) change at runtime.
    func reregister() {
        guard let dm = _displayManager else { return }
        register(displayManager: dm)
    }

    func unregister() {
        hotkeys.forEach { UnregisterEventHotKey($0) }
        hotkeys.removeAll()
        if let h = handler { RemoveEventHandler(h); handler = nil }
    }
}

// Proxy object to bridge C callback → Swift (non-sendable Carbon refs can't cross actor boundary)
private final class HotkeyManagerProxy {
    let displayManager: DisplayManager

    init(displayManager: DisplayManager) {
        self.displayManager = displayManager
    }

    func handle(_ event: EventRef?) {
        guard let event else { return }
        var hotkeyID = EventHotKeyID()
        GetEventParameter(event,
                          EventParamName(kEventParamDirectObject),
                          EventParamType(typeEventHotKeyID),
                          nil,
                          MemoryLayout<EventHotKeyID>.size,
                          nil,
                          &hotkeyID)

        let step: Double = 5.0
        Task { @MainActor in
            switch hotkeyID.id {
            case 1:  // Ctrl+Cmd+Up → brightness +5%
                let next = min(self.displayManager.masterBrightness + step, 100)
                self.displayManager.setMasterBrightness(next)
            case 2:  // Ctrl+Cmd+Down → brightness -5%
                let next = max(self.displayManager.masterBrightness - step, 0)
                self.displayManager.setMasterBrightness(next)
            case 3:  // F1 → brightness -5%
                let next = max(self.displayManager.masterBrightness - step, 0)
                self.displayManager.setMasterBrightness(next)
            case 4:  // F2 → brightness +5%
                let next = min(self.displayManager.masterBrightness + step, 100)
                self.displayManager.setMasterBrightness(next)
            default: break
            }
        }
    }
}
