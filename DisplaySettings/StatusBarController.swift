// StatusBarController.swift
// Manages the NSStatusItem, NSPopover, and menu bar brightness indicator.

import AppKit
import SwiftUI
import Combine

@MainActor
final class StatusBarController: NSObject {

    private var statusItem: NSStatusItem
    private var popover: NSPopover
    private var eventMonitor: EventMonitor?
    private let displayManager: DisplayManager
    private var cancellables: Set<AnyCancellable> = []

    override init() {
        displayManager = DisplayManager()
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        popover = NSPopover()
        super.init()
        configureStatusItem()
        configurePopover()
        setupEventMonitor()
        observeDisplays()
        setupHotkeysAndSchedule()
    }

    // MARK: - Setup

    private func configureStatusItem() {
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "display", accessibilityDescription: "BarDis")
            button.image?.isTemplate = true
            button.action = #selector(handleButtonClick(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.target = self
        }
    }

    private func configurePopover() {
        popover.contentViewController = NSHostingController(
            rootView: ContentView()
                .environmentObject(displayManager)
        )
        popover.behavior = .transient
        popover.animates = true
    }

    private func setupEventMonitor() {
        eventMonitor = EventMonitor(mask: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            guard let self, self.popover.isShown else { return }
            self.closePopover()
        }
    }

    // MARK: - Hotkeys & Schedule

    private func setupHotkeysAndSchedule() {
        HotkeyManager.shared.register(displayManager: displayManager)
        ScheduleManager.shared.attach(displayManager: displayManager)
    }

    // MARK: - Menu Bar Brightness Indicator

    private func observeDisplays() {
        let displaysPublisher = displayManager.$displays.eraseToAnyPublisher()
        let settingPublisher  = SettingsManager.shared.$showBrightnessInMenuBar.eraseToAnyPublisher()

        Publishers.CombineLatest(displaysPublisher, settingPublisher)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] displays, showIndicator in
                self?.updateMenuBarIndicator(displays: displays, show: showIndicator)
            }
            .store(in: &cancellables)
    }

    private func updateMenuBarIndicator(displays: [DisplayModel], show: Bool) {
        let button = statusItem.button
        guard show else {
            button?.title = ""
            statusItem.length = NSStatusItem.squareLength
            return
        }
        let active = displays.filter { $0.ddcSupported }
        guard !active.isEmpty else {
            button?.title = ""
            statusItem.length = NSStatusItem.squareLength
            return
        }
        let avg = Int((active.map(\.brightness).reduce(0, +) / Double(active.count)).rounded())
        button?.title = " \(avg)%"
        statusItem.length = NSStatusItem.variableLength
    }

    // MARK: - Button click handler

    @objc private func handleButtonClick(_ sender: NSStatusBarButton) {
        guard let event = NSApp.currentEvent else { return }
        if event.type == .rightMouseUp {
            showContextMenu(sender)
        } else {
            togglePopover()
        }
    }

    // MARK: - Context menu (right-click)

    private func showContextMenu(_ button: NSStatusBarButton) {
        if popover.isShown { closePopover() }

        let menu = NSMenu()

        let presets = SettingsManager.shared.presets
        if !presets.isEmpty {
            let header = NSMenuItem(title: "Presets", action: nil, keyEquivalent: "")
            header.isEnabled = false
            menu.addItem(header)
            for preset in presets {
                let item = NSMenuItem(
                    title: "\(preset.name)  \(Int(preset.brightness.rounded()))%",
                    action: #selector(applyPresetFromMenu(_:)),
                    keyEquivalent: ""
                )
                item.representedObject = preset
                item.target = self
                menu.addItem(item)
            }
            menu.addItem(.separator())
        }

        let settingsItem = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(
            title: "Quit BarDis",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        menu.addItem(quitItem)

        // Temporarily attach menu for this click
        statusItem.menu = menu
        button.performClick(nil)
        statusItem.menu = nil
    }

    @objc private func applyPresetFromMenu(_ sender: NSMenuItem) {
        guard let preset = sender.representedObject as? BrightnessPreset else { return }
        displayManager.applyPreset(preset)
    }

    @objc private func openSettings() {
        if popover.isShown {
            NotificationCenter.default.post(name: NSNotification.Name("openSettings"), object: nil)
        } else {
            // Defer until the context menu is fully dismissed so button.window is valid
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.openPopover()
                // Post after ContentView has subscribed via .onReceive
                DispatchQueue.main.async {
                    NotificationCenter.default.post(name: NSNotification.Name("openSettings"), object: nil)
                }
            }
        }
    }

    // MARK: - Popover

    private func togglePopover() {
        if popover.isShown {
            closePopover()
        } else {
            openPopover()
        }
    }

    private func openPopover() {
        guard let button = statusItem.button else { return }
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        eventMonitor?.start()
    }

    private func closePopover() {
        popover.performClose(nil)
        eventMonitor?.stop()
    }
}

// MARK: - EventMonitor

final class EventMonitor: NSObject {
    private var monitor: Any?
    private let mask: NSEvent.EventTypeMask
    private let handler: (NSEvent?) -> Void

    init(mask: NSEvent.EventTypeMask, handler: @escaping (NSEvent?) -> Void) {
        self.mask = mask
        self.handler = handler
    }

    deinit { stop() }

    func start() {
        guard monitor == nil else { return }
        monitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] event in
            self?.handler(event)
        }
    }

    func stop() {
        guard let m = monitor else { return }
        NSEvent.removeMonitor(m)
        monitor = nil
    }
}
