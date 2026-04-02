// SettingsView.swift
// App preferences: launch at login, menu bar indicator, hotkeys, schedule, presets, dark mode, debug log.

import SwiftUI

struct SettingsView: View {
    @ObservedObject private var settings = SettingsManager.shared
    @ObservedObject private var schedule = ScheduleManager.shared
    @ObservedObject private var alsManager = AmbientLightManager.shared
    @ObservedObject private var appBrightnessManager = AppBrightnessManager.shared
    @Environment(\.dismiss) private var dismiss

    @State private var showAddSchedule   = false
    @State private var newScheduleHour: Int = 8
    @State private var newScheduleMinute: Int = 0
    @State private var newScheduleBrightness: Double = 70
    @State private var showDebugLog      = false

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Settings")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Button("Done") { dismiss() }
                    .buttonStyle(.plain)
                    .font(.system(size: 12))
                    .foregroundColor(.accentColor)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {

                    // MARK: General
                    sectionHeader("General")
                    SettingsRow(icon: "power", title: "Launch at Login") {
                        Toggle("", isOn: $settings.launchAtLogin).labelsHidden()
                    }
                    Divider().padding(.leading, 42)
                    SettingsRow(icon: "percent", title: "Brightness in Menu Bar") {
                        Toggle("", isOn: $settings.showBrightnessInMenuBar).labelsHidden()
                    }

                    // MARK: Dark Mode Auto-Dim
                    sectionHeader("Dark Mode")
                        .padding(.top, 4)
                    SettingsRow(icon: "moon.fill", title: "Auto-Dim on Dark Mode") {
                        Toggle("", isOn: $settings.autoDimOnDarkMode).labelsHidden()
                    }
                    if settings.autoDimOnDarkMode {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text("Dark mode brightness")
                                    .font(.system(size: 11))
                                    .foregroundColor(.secondary)
                                Spacer()
                                Text("\(Int(settings.darkModeDimBrightness.rounded()))%")
                                    .font(.system(size: 11).monospacedDigit())
                                    .foregroundColor(.secondary)
                            }
                            Slider(value: $settings.darkModeDimBrightness, in: 0...100, step: 5)
                            HStack {
                                Text("Light mode brightness")
                                    .font(.system(size: 11))
                                    .foregroundColor(.secondary)
                                Spacer()
                                Text("\(Int(settings.lightModeBrightness.rounded()))%")
                                    .font(.system(size: 11).monospacedDigit())
                                    .foregroundColor(.secondary)
                            }
                            Slider(value: $settings.lightModeBrightness, in: 0...100, step: 5)
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                    }

                    // MARK: Ambient Light
                    sectionHeader("Ambient Light")
                        .padding(.top, 4)
                    SettingsRow(icon: "sun.max", title: "Auto-Adjust to Ambient Light") {
                        Toggle("", isOn: $alsManager.isEnabled).labelsHidden()
                    }

                    // MARK: App-Aware Brightness
                    sectionHeader("App Brightness")
                        .padding(.top, 4)
                    SettingsRow(icon: "app.badge", title: "Per-App Brightness") {
                        Toggle("", isOn: $appBrightnessManager.isEnabled).labelsHidden()
                    }
                    if appBrightnessManager.isEnabled {
                        if appBrightnessManager.rules.isEmpty {
                            Text("No rules. Running apps appear below.")
                                .font(.system(size: 11))
                                .foregroundColor(.secondary)
                                .padding(.horizontal, 16)
                                .padding(.vertical, 4)
                        } else {
                            ForEach(appBrightnessManager.rules) { rule in
                                HStack {
                                    Text(rule.appName)
                                        .font(.system(size: 11))
                                        .padding(.leading, 16)
                                    Spacer()
                                    Text("\(Int(rule.brightness.rounded()))%")
                                        .font(.system(size: 11))
                                        .foregroundColor(.secondary)
                                    Button {
                                        appBrightnessManager.removeRule(id: rule.id)
                                    } label: {
                                        Image(systemName: "minus.circle")
                                            .font(.system(size: 12))
                                            .foregroundColor(.red.opacity(0.7))
                                    }
                                    .buttonStyle(.plain)
                                    .padding(.trailing, 16)
                                }
                                .frame(height: 30)
                            }
                        }
                        // Running apps list for quick-add
                        let runningApps = NSWorkspace.shared.runningApplications
                            .filter { $0.activationPolicy == .regular && $0.bundleIdentifier != nil }
                        if !runningApps.isEmpty {
                            Text("Add from running apps:")
                                .font(.system(size: 10))
                                .foregroundColor(.secondary)
                                .padding(.horizontal, 16)
                                .padding(.top, 4)
                            ForEach(runningApps.prefix(5), id: \.bundleIdentifier) { app in
                                HStack {
                                    Text(app.localizedName ?? (app.bundleIdentifier ?? ""))
                                        .font(.system(size: 11))
                                        .padding(.leading, 16)
                                    Spacer()
                                    Button {
                                        appBrightnessManager.addRule(
                                            bundleID: app.bundleIdentifier ?? "",
                                            appName: app.localizedName ?? "",
                                            brightness: 70
                                        )
                                    } label: {
                                        Image(systemName: "plus.circle")
                                            .font(.system(size: 12))
                                            .foregroundColor(.accentColor)
                                    }
                                    .buttonStyle(.plain)
                                    .padding(.trailing, 16)
                                }
                                .frame(height: 28)
                            }
                        }
                    }

                    // MARK: Hotkeys
                    sectionHeader("Global Hotkeys")
                        .padding(.top, 4)
                    VStack(alignment: .leading, spacing: 2) {
                        Label("Ctrl+Cmd+↑  →  All displays +5%", systemImage: "command")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                        Label("Ctrl+Cmd+↓  →  All displays -5%", systemImage: "command")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                        if settings.f1f2BrightnessKeys {
                            Label("F1  →  All displays -5%", systemImage: "command")
                                .font(.system(size: 11))
                                .foregroundColor(.secondary)
                            Label("F2  →  All displays +5%", systemImage: "command")
                                .font(.system(size: 11))
                                .foregroundColor(.secondary)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 4)
                    Divider().padding(.leading, 42)
                    SettingsRow(icon: "f.cursive", title: "F1/F2 Brightness Keys") {
                        Toggle("", isOn: $settings.f1f2BrightnessKeys).labelsHidden()
                    }
                    .padding(.bottom, 4)

                    // MARK: Scheduled Brightness
                    sectionHeader("Scheduled Brightness")
                        .padding(.top, 4)
                    SettingsRow(icon: "clock", title: "Auto Schedule") {
                        Toggle("", isOn: $schedule.isEnabled).labelsHidden()
                    }

                    if !schedule.entries.isEmpty {
                        ForEach(schedule.entries.sorted(by: { $0.hour * 60 + $0.minute < $1.hour * 60 + $1.minute })) { entry in
                            HStack {
                                Text(entry.displayString)
                                    .font(.system(size: 11, weight: .medium).monospacedDigit())
                                    .padding(.leading, 16)
                                Spacer()
                                Button {
                                    schedule.deleteEntry(id: entry.id)
                                } label: {
                                    Image(systemName: "minus.circle")
                                        .font(.system(size: 12))
                                        .foregroundColor(.red.opacity(0.7))
                                }
                                .buttonStyle(.plain)
                                .padding(.trailing, 16)
                            }
                            .frame(height: 30)
                            Divider().padding(.leading, 16)
                        }
                    }

                    Button {
                        showAddSchedule = true
                    } label: {
                        Label("Add Rule", systemImage: "plus.circle")
                            .font(.system(size: 11))
                            .foregroundColor(.accentColor)
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)

                    // MARK: Presets
                    sectionHeader("Presets")
                        .padding(.top, 4)

                    if settings.presets.isEmpty {
                        Text("No presets. Add one from the main view.")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 8)
                    } else {
                        ForEach(settings.presets) { preset in
                            HStack {
                                Text(preset.name)
                                    .font(.system(size: 12))
                                    .padding(.leading, 16)
                                Spacer()
                                Text("\(Int(preset.brightness.rounded()))%")
                                    .font(.system(size: 11))
                                    .foregroundColor(.secondary)
                                Button {
                                    settings.deletePreset(id: preset.id)
                                } label: {
                                    Image(systemName: "trash")
                                        .font(.system(size: 11))
                                        .foregroundColor(.red.opacity(0.7))
                                }
                                .buttonStyle(.plain)
                                .padding(.trailing, 16)
                            }
                            .frame(height: 34)
                            // Per-display breakdown (shown when preset has individual screen values)
                            if !preset.perDisplayNames.isEmpty {
                                ForEach(Array(preset.perDisplayNames.keys.sorted()), id: \.self) { key in
                                    if let brightness = preset.perDisplay[key],
                                       let displayName = preset.perDisplayNames[key] {
                                        HStack {
                                            Text(displayName)
                                                .font(.system(size: 9))
                                                .foregroundColor(.secondary)
                                                .lineLimit(1)
                                                .padding(.leading, 16)
                                            Spacer()
                                            Text("\(Int(brightness.rounded()))%")
                                                .font(.system(size: 9))
                                                .foregroundColor(.secondary)
                                                .padding(.trailing, 16)
                                        }
                                    }
                                }
                            }
                            if preset.id != settings.presets.last?.id {
                                Divider().padding(.leading, 16)
                            }
                        }
                    }

                    // MARK: Debug Log
                    sectionHeader("Debug Log")
                        .padding(.top, 4)
                    HStack {
                        Button {
                            showDebugLog.toggle()
                        } label: {
                            Label(showDebugLog ? "Hide Log" : "Show Log", systemImage: "terminal")
                                .font(.system(size: 11))
                                .foregroundColor(.accentColor)
                        }
                        .buttonStyle(.plain)
                        Spacer()
                        Button {
                            DebugLogger.shared.clear()
                        } label: {
                            Text("Clear")
                                .font(.system(size: 11))
                                .foregroundColor(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 6)

                    if showDebugLog {
                        let logText = DebugLogger.shared.text
                        ScrollView {
                            Text(logText.isEmpty ? "(no log entries)" : logText)
                                .font(.system(size: 9, design: .monospaced))
                                .foregroundColor(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(8)
                        }
                        .frame(height: 120)
                        .background(Color(NSColor.textBackgroundColor).opacity(0.5))
                        .cornerRadius(6)
                        .padding(.horizontal, 16)
                        .padding(.bottom, 8)

                        Button {
                            let pb = NSPasteboard.general
                            pb.clearContents()
                            pb.setString(logText, forType: .string)
                        } label: {
                            Label("Copy to Clipboard", systemImage: "doc.on.clipboard")
                                .font(.system(size: 11))
                                .foregroundColor(.accentColor)
                        }
                        .buttonStyle(.plain)
                        .padding(.horizontal, 16)
                        .padding(.bottom, 8)
                    }
                }
                .padding(.bottom, 12)
            }
        }
        .frame(width: 300, height: 600)
        .sheet(isPresented: $showAddSchedule) { addScheduleSheet }
    }

    // MARK: - Add Schedule Sheet

    private var addScheduleSheet: some View {
        VStack(spacing: 16) {
            Text("Add Schedule Rule")
                .font(.headline)

            HStack(spacing: 12) {
                VStack(spacing: 4) {
                    Text("Hour").font(.system(size: 11)).foregroundColor(.secondary)
                    Stepper("\(newScheduleHour)", value: $newScheduleHour, in: 0...23)
                        .frame(width: 90)
                }
                VStack(spacing: 4) {
                    Text("Minute").font(.system(size: 11)).foregroundColor(.secondary)
                    Stepper(String(format: "%02d", newScheduleMinute),
                            value: $newScheduleMinute, in: 0...59, step: 5)
                        .frame(width: 90)
                }
            }

            VStack(spacing: 4) {
                Text("Brightness: \(Int(newScheduleBrightness.rounded()))%")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                Slider(value: $newScheduleBrightness, in: 0...100, step: 5)
                    .frame(width: 200)
            }

            HStack(spacing: 12) {
                Button("Cancel") { showAddSchedule = false }
                Button("Add") {
                    schedule.addEntry(ScheduleEntry(
                        hour: newScheduleHour,
                        minute: newScheduleMinute,
                        brightness: newScheduleBrightness
                    ))
                    showAddSchedule = false
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(24)
        .frame(width: 280)
    }

    // MARK: - Helpers

    private func sectionHeader(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.system(size: 10, weight: .semibold))
            .foregroundColor(.secondary)
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Reusable row

struct SettingsRow<Content: View>: View {
    let icon: String
    let title: String
    let content: Content

    init(icon: String, title: String, @ViewBuilder content: () -> Content) {
        self.icon = icon
        self.title = title
        self.content = content()
    }

    var body: some View {
        HStack {
            Image(systemName: icon)
                .font(.system(size: 13))
                .foregroundColor(.accentColor)
                .frame(width: 18)
                .padding(.leading, 16)
            Text(title)
                .font(.system(size: 12))
            Spacer()
            content
                .padding(.trailing, 16)
        }
        .frame(height: 40)
    }
}
