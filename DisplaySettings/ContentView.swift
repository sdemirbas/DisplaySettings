// ContentView.swift
// SwiftUI popover UI for DisplaySettings menu bar app.

import SwiftUI

struct ContentView: View {
    @StateObject private var displayManager = DisplayManager()
    @StateObject private var updateChecker  = UpdateChecker()

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Image(systemName: "display.2")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.secondary)
                Text("Display Settings")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Button {
                    Task { await displayManager.refresh() }
                } label: {
                    Image(systemName: displayManager.isRefreshing ? "arrow.clockwise" : "arrow.clockwise")
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

            Divider()

            // Display list
            if displayManager.displays.isEmpty && !displayManager.isRefreshing {
                noDisplaysView
            } else {
                displayListView
            }

            Divider()

            // Footer
            HStack {
                Text("v\(updateChecker.currentVersion)")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)

                if updateChecker.updateAvailable, let latest = updateChecker.latestVersion {
                    Button {
                        NSWorkspace.shared.open(updateChecker.releasesURL)
                    } label: {
                        HStack(spacing: 3) {
                            Image(systemName: "arrow.down.circle.fill")
                                .font(.system(size: 10))
                            Text("v\(latest) available")
                                .font(.system(size: 11))
                        }
                        .foregroundColor(.accentColor)
                    }
                    .buttonStyle(.plain)
                }

                Spacer()
                Button("Quit") {
                    NSApplication.shared.terminate(nil)
                }
                .buttonStyle(.plain)
                .font(.system(size: 11))
                .foregroundColor(.secondary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
        }
        .frame(width: 280)
    }

    // MARK: - Subviews

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
}

// MARK: - DisplayCardView

struct DisplayCardView: View {
    @Binding var display: DisplayModel
    let displayManager: DisplayManager

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Display name row
            HStack(spacing: 8) {
                Image(systemName: "display")
                    .font(.system(size: 13))
                    .foregroundColor(.accentColor)
                    .frame(width: 18)
                Text(display.name)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer()
                if display.isLoading {
                    ProgressView()
                        .scaleEffect(0.6)
                        .frame(width: 20, height: 16)
                } else if display.ddcSupported {
                    Text("\(Int(display.brightness.rounded()))%")
                        .font(.system(size: 11, weight: .medium).monospacedDigit())
                        .foregroundColor(.secondary)
                        .frame(minWidth: 32, alignment: .trailing)
                }
            }

            // Brightness control
            if display.isLoading {
                Slider(value: .constant(50), in: 0...100)
                    .disabled(true)
                    .opacity(0.4)
            } else if display.ddcSupported {
                HStack(spacing: 6) {
                    Image(systemName: "sun.min")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                    Slider(
                        value: Binding(
                            get: { display.brightness },
                            set: { newVal in
                                displayManager.setBrightness(newVal, for: display.id)
                            }
                        ),
                        in: 0...100,
                        step: 1
                    )
                    Image(systemName: "sun.max")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }
            } else {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 10))
                        .foregroundColor(.orange)
                    Text("DDC not supported")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
                .help("This display does not support DDC/CI brightness control")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}

#Preview {
    ContentView()
}
