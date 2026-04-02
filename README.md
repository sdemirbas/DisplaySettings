# Nit

Hardware-level brightness, contrast & volume control for all your monitors — on macOS, Windows, and Linux. Free, open source, forever.

## Features

- DDC/CI hardware brightness (no drivers, no software dimming)
- Per-display brightness, contrast, and volume sliders
- Presets — save and apply display configurations in one click
- F1/F2 key override for external monitors
- Ambient light sensor sync (macOS)
- App-aware brightness — auto-switch presets when apps activate
- Apple Shortcuts integration (macOS 13+)
- URL scheme CLI: `open "nit://brightness?value=50"`
- Cross-platform: macOS, Windows, Linux

## Requirements

### macOS
- macOS 13 (Ventura) or later
- External display with DDC/CI support (DisplayPort or HDMI)

### Windows
- Windows 10 / 11 (x64)
- DDC-compatible monitor

### Linux
- `ddcutil` installed (`sudo apt install ddcutil` / `pacman -S ddcutil` / etc.)
- Fallback: `xrandr` (software brightness only)

## Install

### macOS

Download **[Nit.dmg](https://github.com/sdemirbas/Nit/releases/latest/download/Nit.dmg)** from the latest release, open it, and drag Nit.app to `/Applications`.

### Windows

Download **[Nit.exe](https://github.com/sdemirbas/Nit/releases/latest/download/Nit.exe)** and run it directly — no installer needed.

### Linux

```bash
# Clone and run directly
git clone https://github.com/sdemirbas/Nit.git
pip install pystray pillow
python linux/nit.py
```

---

## Gatekeeper — "unidentified developer" warning {#gatekeeper}

Nit is signed with an Apple Development certificate but is **not notarized** (notarization requires Apple's $99/year Developer Program). macOS Gatekeeper will show a warning on first launch.

### Option 1 — Right-click workaround (free, instant)

1. Open the DMG and drag Nit.app to `/Applications`
2. **Do not double-click the app.** Instead, right-click (or Control-click) it and choose **Open**
3. Click **Open** in the dialog that appears
4. macOS remembers your choice — subsequent launches work normally

### Option 2 — Remove quarantine flag via Terminal

```bash
xattr -dr com.apple.quarantine /Applications/Nit.app
```

Then double-click as usual. This is safe — it just tells macOS you've reviewed and trust this specific app.

### Why isn't Nit notarized?

Notarization requires an Apple Developer Program membership ($99/year). Nit is a free, open-source project. If you'd like to help cover the cost, [open an issue](https://github.com/sdemirbas/Nit/issues) — or build from source (always unsigned, always trusted by Xcode).

---

## Build from source

```bash
git clone https://github.com/sdemirbas/Nit.git
cd Nit
xcodebuild -project DisplaySettings.xcodeproj -scheme Nit -configuration Release build
```

## URL Scheme

Nit registers the `nit://` scheme for scripting and automation:

| Command | Effect |
|---------|--------|
| `open "nit://brightness?value=50"` | Set all displays to 50% |
| `open "nit://preset?name=Night"` | Apply the "Night" preset |
| `open "nit://display/0/brightness?value=75"` | Set display 0 to 75% |

Add `alias nit='open -g'` to your shell profile, then use: `nit "nit://brightness?value=30"`

## License

MIT
