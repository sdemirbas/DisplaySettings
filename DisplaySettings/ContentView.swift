// ContentView.swift
// SwiftUI popover UI for Nit menu bar app.

import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var displayManager: DisplayManager
    @EnvironmentObject private var updateChecker: UpdateChecker
    @ObservedObject    private var settings = SettingsManager.shared

    @State private var showSettings  = false
    @State private var showAddPreset       = false
    @State private var newPresetName       = ""
    @State private var newPresetBrightness = 80.0

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            if updateChecker.updateAvailable || updateChecker.isUpdating || updateChecker.updateInstalled {
                updateBanner
                Divider()
            }

            if !settings.presets.isEmpty {
                presetsBar
                Divider()
            }

            let ddcDisplays = displayManager.displays.filter { $0.ddcSupported }
            if ddcDisplays.count > 1 {
                masterSlider
                Divider()
            }

            if displayManager.displays.isEmpty && !displayManager.isRefreshing {
                noDisplaysView
            } else {
                displayListView
            }

            Divider()
            footer
        }
        .frame(width: 300)
        .sheet(isPresented: $showSettings) { SettingsView() }
        .sheet(isPresented: $showAddPreset) { addPresetSheet }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("openSettings"))) { _ in
            showSettings = true
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            Image(systemName: "display.2")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(.secondary)
            Text("Nit")
                .font(.system(size: 13, weight: .semibold))
            Spacer()
            Button { showSettings = true } label: {
                Image(systemName: "gear")
                    .font(.system(size: 12, weight: .medium))
            }
            .buttonStyle(.plain)
            .foregroundColor(.secondary)
            .help("Settings")

            Button {
                Task { await displayManager.refresh() }
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 12, weight: .medium))
                    .rotationEffect(.degrees(displayManager.isRefreshing ? 360 : 0))
                    .animation(
                        displayManager.isRefreshing
                            ? .linear(duration: 0.8).repeatForever(autoreverses: false)
                            : .default,
                        value: displayManager.isRefreshing
                    )
            }
            .buttonStyle(.plain)
            .foregroundColor(.secondary)
            .help("Refresh displays")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    // MARK: - Update Banner

    private var updateBanner: some View {
        HStack(spacing: 8) {
            if updateChecker.isUpdating {
                ProgressView()
                    .scaleEffect(0.75)
                    .frame(width: 16, height: 16)
                Text("Updating…")
                    .font(.system(size: 12))
                    .foregroundColor(.primary)
            } else if updateChecker.updateInstalled {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(.green)
                    .font(.system(size: 13))
                Text("Updated! Relaunch to apply.")
                    .font(.system(size: 12))
                Spacer()
                Button("Relaunch") {
                    updateChecker.relaunch()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            } else if let ver = updateChecker.latestVersion {
                Image(systemName: "arrow.down.circle.fill")
                    .foregroundColor(.accentColor)
                    .font(.system(size: 13))
                Text("v\(ver) available")
                    .font(.system(size: 12))
                Spacer()
                Button("Update") {
                    updateChecker.installViaBrew()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity)
        .background(Color.accentColor.opacity(0.07))
    }

    // MARK: - Presets Bar

    private var presetsBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(settings.presets) { preset in
                    Button {
                        displayManager.applyPreset(preset)
                    } label: {
                        Text(preset.name)
                            .font(.system(size: 11, weight: .medium))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(Color.accentColor.opacity(0.12))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 6)
                                    .stroke(Color.accentColor.opacity(0.3), lineWidth: 1)
                            )
                    }
                    .buttonStyle(.plain)
                    .help("\(Int(preset.brightness.rounded()))% brightness")
                }

                Button {
                    newPresetName       = "Preset \(settings.presets.count + 1)"
                    newPresetBrightness = displayManager.masterBrightness
                    showAddPreset       = true
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 11, weight: .medium))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(Color.secondary.opacity(0.1))
                        )
                }
                .buttonStyle(.plain)
                .foregroundColor(.secondary)
                .help("Save current brightness as preset")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
        }
    }

    // MARK: - Master Slider

    private var masterSlider: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 13))
                    .foregroundColor(.secondary)
                    .frame(width: 18)
                Text("All Displays")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.secondary)
                Spacer()
                Text("\(Int(displayManager.masterBrightness.rounded()))%")
                    .font(.system(size: 11, weight: .medium).monospacedDigit())
                    .foregroundColor(.secondary)
                    .frame(minWidth: 32, alignment: .trailing)
            }
            HStack(spacing: 6) {
                Image(systemName: "sun.min").font(.system(size: 10)).foregroundColor(.secondary)
                Slider(
                    value: Binding(
                        get: { displayManager.masterBrightness },
                        set: { displayManager.setMasterBrightness($0) }
                    ),
                    in: 0...100, step: 1
                )
                Image(systemName: "sun.max").font(.system(size: 10)).foregroundColor(.secondary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    // MARK: - Empty State

    private var noDisplaysView: some View {
        VStack(spacing: 8) {
            Image(systemName: "display.trianglebadge.exclamationmark")
                .font(.system(size: 28))
                .foregroundColor(.secondary)
            Text("No external displays found")
                .font(.system(size: 12))
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
    }

    // MARK: - Display List

    private var displayListView: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach($displayManager.displays) { $display in
                    DisplayCardView(display: $display, displayManager: displayManager)
                    if display.id != displayManager.displays.last?.id {
                        Divider().padding(.leading, 14)
                    }
                }
            }
        }
        .frame(maxHeight: 400)
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            Text("v\(updateChecker.currentVersion)")
                .font(.system(size: 11))
                .foregroundColor(.secondary)
            Spacer()
            Button("Quit") { NSApplication.shared.terminate(nil) }
                .buttonStyle(.plain)
                .font(.system(size: 11))
                .foregroundColor(.secondary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    // MARK: - Add Preset Sheet

    private var addPresetSheet: some View {
        VStack(spacing: 16) {
            Text("Save Preset")
                .font(.headline)

            TextField("Name", text: $newPresetName)
                .textFieldStyle(.roundedBorder)
                .frame(width: 200)

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Brightness")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                    Spacer()
                    Text("\(Int(newPresetBrightness.rounded()))%")
                        .font(.system(size: 12, weight: .semibold).monospacedDigit())
                }
                HStack(spacing: 6) {
                    Image(systemName: "sun.min")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                    Slider(value: $newPresetBrightness, in: 0...100, step: 1)
                    Image(systemName: "sun.max")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }
            }
            .frame(width: 200)

            HStack(spacing: 12) {
                Button("Cancel") { showAddPreset = false }
                Button("Save") {
                    let name = newPresetName.trimmingCharacters(in: .whitespaces)
                    settings.addPreset(name: name, brightness: newPresetBrightness)
                    showAddPreset = false
                }
                .buttonStyle(.borderedProminent)
                .disabled(newPresetName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(24)
        .frame(width: 280)
    }
}

#Preview {
    ContentView()
        .environmentObject(DisplayManager())
        .environmentObject(UpdateChecker())
}
