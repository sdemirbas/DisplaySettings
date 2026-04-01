// DisplayCardView.swift
// Per-display card with brightness, contrast, volume, color temp, and RGB gain sliders.

import SwiftUI

struct DisplayCardView: View {
    @Binding var display: DisplayModel
    let displayManager: DisplayManager

    @State private var showContrast     = false
    @State private var showColorAdv     = false
    @State private var showPowerConfirm = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            nameRow
            sliders
            if display.ddcSupported && display.volume >= 0 {
                volumeSlider
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    // MARK: - Name row

    private var nameRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "display")
                .font(.system(size: 13))
                .foregroundColor(.accentColor)
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 1) {
                Text(display.name)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.tail)
                if !display.resolution.isEmpty {
                    Text(display.resolution)
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }
            }

            Spacer()

            if display.isLoading {
                ProgressView().scaleEffect(0.6).frame(width: 20, height: 16)
            } else if display.usesSoftwareBrightness {
                Text("\(Int(display.brightness.rounded()))%")
                    .font(.system(size: 11, weight: .medium).monospacedDigit())
                    .foregroundColor(.secondary)
                    .frame(minWidth: 32, alignment: .trailing)
            } else if display.ddcSupported {
                Text("\(Int(display.brightness.rounded()))%")
                    .font(.system(size: 11, weight: .medium).monospacedDigit())
                    .foregroundColor(.secondary)
                    .frame(minWidth: 32, alignment: .trailing)

                // Toggle contrast
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) { showContrast.toggle() }
                } label: {
                    Image(systemName: "circle.lefthalf.filled")
                        .font(.system(size: 11))
                        .foregroundColor(showContrast ? .accentColor : .secondary)
                }
                .buttonStyle(.plain)
                .help(showContrast ? "Hide contrast" : "Adjust contrast")

                // Toggle color/RGB
                if display.colorTemp >= 0 || display.gainR >= 0 {
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) { showColorAdv.toggle() }
                    } label: {
                        Image(systemName: "paintpalette")
                            .font(.system(size: 11))
                            .foregroundColor(showColorAdv ? .accentColor : .secondary)
                    }
                    .buttonStyle(.plain)
                    .help(showColorAdv ? "Hide color controls" : "Adjust color temperature / RGB")
                }

                // Power off button
                Button { showPowerConfirm = true } label: {
                    Image(systemName: "power")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .help("Put display to sleep")
                .confirmationDialog(
                    "Put \"\(display.name)\" to sleep?",
                    isPresented: $showPowerConfirm,
                    titleVisibility: .visible
                ) {
                    Button("Sleep Display", role: .destructive) {
                        displayManager.setPower(on: false, for: display.id)
                    }
                }
            }
        }
    }

    // MARK: - Sliders

    @ViewBuilder
    private var sliders: some View {
        if display.isLoading {
            Slider(value: .constant(50), in: 0...100).disabled(true).opacity(0.4)
        } else if display.ddcSupported {
            brightnessSlider
            if showContrast {
                contrastSlider
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
            if showColorAdv {
                if display.colorTemp >= 0 {
                    colorTempSlider
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
                if display.gainR >= 0 {
                    gainSlider(label: "R", value: display.gainR, channel: 0x16, color: .red)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
                if display.gainG >= 0 {
                    gainSlider(label: "G", value: display.gainG, channel: 0x18, color: .green)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
                if display.gainB >= 0 {
                    gainSlider(label: "B", value: display.gainB, channel: 0x1A, color: .blue)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
        } else if display.usesSoftwareBrightness {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Image(systemName: "sun.min").font(.system(size: 10)).foregroundColor(.secondary)
                    Slider(
                        value: Binding(
                            get: { display.brightness },
                            set: { displayManager.setBrightness($0, for: display.id) }
                        ),
                        in: 0...100, step: 1
                    )
                    Image(systemName: "sun.max").font(.system(size: 10)).foregroundColor(.secondary)
                }
                Text("Software brightness (DDC not supported)")
                    .font(.system(size: 9))
                    .foregroundColor(.secondary)
                    .padding(.leading, 16)
            }
        } else {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle").font(.system(size: 10)).foregroundColor(.orange)
                Text("DDC not supported").font(.system(size: 11)).foregroundColor(.secondary)
            }
            .help("This display does not support DDC/CI brightness control")
        }
    }

    // MARK: - Slider rows

    private var brightnessSlider: some View {
        HStack(spacing: 6) {
            Image(systemName: "sun.min").font(.system(size: 10)).foregroundColor(.secondary)
            Slider(
                value: Binding(
                    get: { display.brightness },
                    set: { displayManager.setBrightness($0, for: display.id) }
                ),
                in: 0...100, step: 1
            )
            Image(systemName: "sun.max").font(.system(size: 10)).foregroundColor(.secondary)
        }
    }

    private var contrastSlider: some View {
        HStack(spacing: 6) {
            Image(systemName: "circle.lefthalf.filled").font(.system(size: 10)).foregroundColor(.secondary)
            Slider(
                value: Binding(
                    get: { display.contrast },
                    set: { displayManager.setContrast($0, for: display.id) }
                ),
                in: 0...100, step: 1
            )
            Image(systemName: "circle.righthalf.filled").font(.system(size: 10)).foregroundColor(.secondary)
        }
    }

    private var colorTempSlider: some View {
        HStack(spacing: 6) {
            Image(systemName: "thermometer.low").font(.system(size: 10)).foregroundColor(.orange)
            Slider(
                value: Binding(
                    get: { display.colorTemp },
                    set: { displayManager.setColorTemp($0, for: display.id) }
                ),
                in: 0...100, step: 1
            )
            Image(systemName: "thermometer.high").font(.system(size: 10)).foregroundColor(.blue)
        }
    }

    private var volumeSlider: some View {
        HStack(spacing: 6) {
            Image(systemName: "speaker").font(.system(size: 10)).foregroundColor(.secondary)
            Slider(
                value: Binding(
                    get: { max(display.volume, 0) },
                    set: { displayManager.setVolume($0, for: display.id) }
                ),
                in: 0...100, step: 1
            )
            Image(systemName: "speaker.wave.3").font(.system(size: 10)).foregroundColor(.secondary)
        }
    }

    private func gainSlider(label: String, value: Double, channel: UInt8, color: Color) -> some View {
        HStack(spacing: 6) {
            Text(label)
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(color)
                .frame(width: 10)
            Slider(
                value: Binding(
                    get: { value },
                    set: { displayManager.setGain($0, channel: channel, for: display.id) }
                ),
                in: 0...100, step: 1
            )
            Text("\(Int(value.rounded()))")
                .font(.system(size: 10).monospacedDigit())
                .foregroundColor(.secondary)
                .frame(width: 24, alignment: .trailing)
        }
    }
}
