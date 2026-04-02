#!/usr/bin/env python3
"""
Nit for Linux — Display brightness control via ddcutil
System tray app. Requires: pip install pystray pillow
Optional: sudo apt install ddcutil (for DDC/CI support)
Fallback: xrandr gamma (software dimming)

Usage: python nit.py
"""

from __future__ import annotations

import json
import math
import re
import shutil
import subprocess
import threading
import tkinter as tk
from tkinter import ttk
from dataclasses import dataclass
from datetime import datetime
from pathlib import Path

import pystray
from PIL import Image, ImageDraw


# -- DDC/CI via ddcutil CLI ------------------------------------------------


class LinuxDDCutilController:
    """Controls brightness via ddcutil CLI subprocess."""

    def __init__(self):
        self._available = shutil.which("ddcutil") is not None
        self._displays: list[int] = []
        if self._available:
            self._displays = self._detect_displays()

    def is_available(self) -> bool:
        return self._available and bool(self._displays)

    def _detect_displays(self) -> list[int]:
        try:
            result = subprocess.run(
                ["ddcutil", "detect", "--brief"],
                capture_output=True, text=True, timeout=10,
            )
            # Parse "Display N" lines
            nums = re.findall(r"Display\s+(\d+)", result.stdout)
            return [int(n) for n in nums]
        except Exception:
            return []

    def get_vcp(self, display_num: int, vcp_code: int) -> int | None:
        """Read a VCP feature value (0-100 scale)."""
        try:
            result = subprocess.run(
                ["ddcutil", "getvcp", "--display", str(display_num),
                 f"0x{vcp_code:02x}", "--brief"],
                capture_output=True, text=True, timeout=5,
            )
            # Output: "VCP 10 C 50 100" (current max)
            parts = result.stdout.strip().split()
            if len(parts) >= 4 and parts[0] == "VCP":
                cur = int(parts[3])
                mx = int(parts[4]) if len(parts) > 4 else 100
                return int(cur / mx * 100) if mx > 0 else cur
        except Exception:
            pass
        return None

    def set_vcp(self, display_num: int, vcp_code: int, value: int) -> bool:
        """Write a VCP feature value (0-100 scale)."""
        try:
            value = max(0, min(100, value))
            result = subprocess.run(
                ["ddcutil", "setvcp", "--display", str(display_num),
                 f"0x{vcp_code:02x}", str(value)],
                capture_output=True, timeout=5,
            )
            return result.returncode == 0
        except Exception:
            return False

    def get_brightness(self, display_num: int) -> int | None:
        return self.get_vcp(display_num, 0x10)

    def set_brightness(self, display_num: int, value: int) -> bool:
        return self.set_vcp(display_num, 0x10, value)

    def get_contrast(self, display_num: int) -> int | None:
        return self.get_vcp(display_num, 0x12)

    def set_contrast(self, display_num: int, value: int) -> bool:
        return self.set_vcp(display_num, 0x12, value)

    def get_volume(self, display_num: int) -> int | None:
        return self.get_vcp(display_num, 0x62)

    def set_volume(self, display_num: int, value: int) -> bool:
        return self.set_vcp(display_num, 0x62, value)

    @property
    def display_count(self) -> int:
        return len(self._displays)


# -- xrandr software fallback ---------------------------------------------


class XRandrController:
    """Software brightness via xrandr gamma (fallback)."""

    def __init__(self):
        self._outputs = self._detect_outputs()
        self._value = 100

    def _detect_outputs(self) -> list[str]:
        try:
            result = subprocess.run(
                ["xrandr", "--query"],
                capture_output=True, text=True, timeout=5,
            )
            return re.findall(r"^(\S+)\s+connected", result.stdout, re.MULTILINE)
        except Exception:
            return []

    def is_available(self) -> bool:
        return bool(self._outputs)

    @property
    def outputs(self) -> list[str]:
        return list(self._outputs)

    def get_brightness(self) -> int:
        return self._value

    def set_brightness(self, value: int) -> bool:
        value = max(0, min(100, value))
        self._value = value
        gamma = max(0.1, value / 100.0)
        success = False
        for output in self._outputs:
            try:
                result = subprocess.run(
                    ["xrandr", "--output", output, "--brightness", f"{gamma:.2f}"],
                    capture_output=True, timeout=5,
                )
                if result.returncode == 0:
                    success = True
            except Exception:
                pass
        return success


# -- Per-monitor unified controller ----------------------------------------


class LinuxMonitorController:
    """Unified controller: ddcutil first, xrandr fallback."""

    MODE_DDC = "ddcutil"
    MODE_XRANDR = "xrandr"

    def __init__(self, ddcutil: LinuxDDCutilController, xrandr: XRandrController,
                 display_num: int = 0, name: str = "Display"):
        self._ddcutil = ddcutil
        self._xrandr = xrandr
        self._display_num = display_num
        self._name = name
        self._mode = self.MODE_DDC if self._ddcutil.is_available() else self.MODE_XRANDR
        self._value = 50
        self._contrast = -1     # -1 = not supported
        self._volume = -1
        self._probe()

    def _probe(self):
        if self._mode == self.MODE_DDC:
            displays = self._ddcutil._displays
            if self._display_num < len(displays):
                val = self._ddcutil.get_brightness(displays[self._display_num])
                if val is not None:
                    self._value = val
                    # Probe contrast and volume too
                    c = self._ddcutil.get_contrast(displays[self._display_num])
                    if c is not None:
                        self._contrast = c
                    v = self._ddcutil.get_volume(displays[self._display_num])
                    if v is not None:
                        self._volume = v
                    return
        self._mode = self.MODE_XRANDR
        self._value = self._xrandr.get_brightness()

    @property
    def name(self) -> str:
        return self._name

    @property
    def mode(self) -> str:
        return self._mode

    @property
    def brightness(self) -> int:
        return self._value

    @property
    def contrast(self) -> int:
        return self._contrast

    @property
    def volume(self) -> int:
        return self._volume

    def set(self, value: int):
        value = max(0, min(100, value))
        self._value = value
        if self._mode == self.MODE_DDC:
            displays = self._ddcutil._displays
            if self._display_num < len(displays):
                if self._ddcutil.set_brightness(displays[self._display_num], value):
                    return
        self._xrandr.set_brightness(value)

    def set_contrast(self, value: int):
        value = max(0, min(100, value))
        self._contrast = value
        if self._mode == self.MODE_DDC:
            displays = self._ddcutil._displays
            if self._display_num < len(displays):
                self._ddcutil.set_contrast(displays[self._display_num], value)

    def set_volume(self, value: int):
        value = max(0, min(100, value))
        self._volume = value
        if self._mode == self.MODE_DDC:
            displays = self._ddcutil._displays
            if self._display_num < len(displays):
                self._ddcutil.set_volume(displays[self._display_num], value)


# -- Multi-monitor orchestrator --------------------------------------------


class LinuxMultiController:
    """Manages one LinuxMonitorController per detected display."""

    def __init__(self):
        self._ddcutil = LinuxDDCutilController()
        self._xrandr = XRandrController()
        self._controllers: list[LinuxMonitorController] = []
        self._build()

    def _build(self):
        if self._ddcutil.is_available():
            for i, _ in enumerate(self._ddcutil._displays):
                ctrl = LinuxMonitorController(
                    self._ddcutil, self._xrandr,
                    display_num=i, name=f"Display {i + 1}",
                )
                self._controllers.append(ctrl)
        elif self._xrandr.is_available():
            for i, output in enumerate(self._xrandr.outputs):
                ctrl = LinuxMonitorController(
                    self._ddcutil, self._xrandr,
                    display_num=i, name=output,
                )
                self._controllers.append(ctrl)

        if not self._controllers:
            self._controllers.append(
                LinuxMonitorController(self._ddcutil, self._xrandr, name="Display")
            )

    @property
    def monitors(self) -> list[LinuxMonitorController]:
        return self._controllers

    @property
    def count(self) -> int:
        return len(self._controllers)

    @property
    def average_brightness(self) -> int:
        if not self._controllers:
            return 50
        return int(sum(c.brightness for c in self._controllers) / len(self._controllers))


# -- Tray icon image -------------------------------------------------------


def _make_icon(brightness: int = 50) -> Image.Image:
    size = 64
    img = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    draw = ImageDraw.Draw(img)

    intensity = max(0.3, brightness / 100.0)
    r, g, b = 255, int(165 + 90 * intensity), 0
    color = (r, g, b, 230)

    cx = cy = size // 2
    core_r = int(size * 0.28 * intensity + size * 0.12)

    # Rays
    ray_count = 8
    for i in range(ray_count):
        angle = math.radians(i * 360 / ray_count)
        inner = core_r + 3
        outer = core_r + int(9 * intensity) + 3
        draw.line(
            [cx + inner * math.cos(angle), cy + inner * math.sin(angle),
             cx + outer * math.cos(angle), cy + outer * math.sin(angle)],
            fill=color, width=max(2, int(3 * intensity)),
        )

    # Core
    draw.ellipse([cx - core_r, cy - core_r, cx + core_r, cy + core_r], fill=color)
    return img


# -- Popup window ----------------------------------------------------------


class LinuxBrightnessPopup:
    BG = "#1e1e1e"
    FG = "#f0f0f0"
    MUTED = "#777777"
    WIDTH = 280
    PER_MONITOR_HEIGHT = 76
    BASE_HEIGHT = 44

    def __init__(self, multi: LinuxMultiController, on_close):
        self._multi = multi
        self._on_close = on_close
        self._jobs: dict = {}
        self._root = None

    def _compute_height(self) -> int:
        total = self.BASE_HEIGHT
        for ctrl in self._multi.monitors:
            h = self.PER_MONITOR_HEIGHT
            if ctrl.contrast >= 0:
                h += 24
            if ctrl.volume >= 0:
                h += 24
            total += h
        return total

    def show(self):
        if self._root and self._root.winfo_exists():
            self._root.destroy()
            return

        height = self._compute_height()
        root = tk.Tk()
        self._root = root
        root.withdraw()
        root.title("Nit")
        root.resizable(False, False)
        root.attributes("-topmost", True)
        root.overrideredirect(True)
        root.configure(bg=self.BG)

        sw = root.winfo_screenwidth()
        sh = root.winfo_screenheight()
        root.geometry(f"{self.WIDTH}x{height}+{sw - self.WIDTH - 16}+{sh - height - 56}")

        style = ttk.Style()
        style.theme_use("clam")
        style.configure("N.Horizontal.TScale", background=self.BG,
                        troughcolor="#3a3a3a", sliderlength=14, sliderrelief="flat")

        pad = tk.Frame(root, bg=self.BG, padx=14, pady=10)
        pad.pack(fill=tk.BOTH, expand=True)
        tk.Label(pad, text="Nit", bg=self.BG, fg=self.FG,
                 font=("DejaVu Sans", 11, "bold")).pack(anchor=tk.W, pady=(0, 4))

        for ctrl in self._multi.monitors:
            self._build_section(pad, ctrl, root)

        root.deiconify()
        root.focus_force()
        root.bind("<FocusOut>", lambda _: self._close())
        root.bind("<Escape>", lambda _: self._close())
        root.mainloop()

    def _close(self):
        if self._root and self._root.winfo_exists():
            self._root.destroy()
        self._root = None
        self._on_close()

    def _build_slider_row(self, parent, root, label_left: str, label_right: str,
                          initial: int, key_suffix: str, callback):
        row = tk.Frame(parent, bg=self.BG)
        row.pack(fill=tk.X)
        tk.Label(row, text=label_left, bg=self.BG, fg=self.MUTED,
                 font=("DejaVu Sans", 9)).pack(side=tk.LEFT)

        slider = ttk.Scale(row, from_=0, to=100, orient=tk.HORIZONTAL,
                           length=self.WIDTH - 60, style="N.Horizontal.TScale")
        slider.set(initial)

        key = key_suffix

        def _on_change(val, _key=key):
            v = int(float(val))
            if _key in self._jobs:
                root.after_cancel(self._jobs[_key])
            self._jobs[_key] = root.after(80, lambda: callback(v))

        slider.configure(command=_on_change)
        slider.pack(side=tk.LEFT, padx=4, fill=tk.X, expand=True)
        tk.Label(row, text=label_right, bg=self.BG, fg=self.MUTED,
                 font=("DejaVu Sans", 9)).pack(side=tk.LEFT)

    def _build_section(self, parent, ctrl: LinuxMonitorController, root):
        frame = tk.Frame(parent, bg=self.BG)
        frame.pack(fill=tk.X, pady=(4, 0))

        header = tk.Frame(frame, bg=self.BG)
        header.pack(fill=tk.X)
        tk.Label(header, text=ctrl.name, bg=self.BG, fg=self.FG,
                 font=("DejaVu Sans", 9)).pack(side=tk.LEFT)

        pct_var = tk.StringVar(value=f"{ctrl.brightness}%")
        tk.Label(header, textvariable=pct_var, bg=self.BG, fg=self.MUTED,
                 font=("DejaVu Sans", 9)).pack(side=tk.RIGHT)

        tk.Label(frame, text=ctrl.mode, bg=self.BG, fg=self.MUTED,
                 font=("DejaVu Sans", 7)).pack(anchor=tk.W)

        # Brightness slider
        key = id(ctrl)

        row = tk.Frame(frame, bg=self.BG)
        row.pack(fill=tk.X)
        tk.Label(row, text="○", bg=self.BG, fg=self.MUTED,
                 font=("DejaVu Sans", 9)).pack(side=tk.LEFT)

        slider = ttk.Scale(row, from_=0, to=100, orient=tk.HORIZONTAL,
                           length=self.WIDTH - 60, style="N.Horizontal.TScale")
        slider.set(ctrl.brightness)

        def _on_brightness(val, _ctrl=ctrl, _pct=pct_var, _key=key):
            v = int(float(val))
            _pct.set(f"{v}%")
            if _key in self._jobs:
                root.after_cancel(self._jobs[_key])
            self._jobs[_key] = root.after(80, lambda: _ctrl.set(v))

        slider.configure(command=_on_brightness)
        slider.pack(side=tk.LEFT, padx=4, fill=tk.X, expand=True)
        tk.Label(row, text="◉", bg=self.BG, fg=self.MUTED,
                 font=("DejaVu Sans", 9)).pack(side=tk.LEFT)

        # Contrast slider (only if supported)
        if ctrl.contrast >= 0:
            ch = tk.Frame(frame, bg=self.BG)
            ch.pack(fill=tk.X, pady=(2, 0))
            tk.Label(ch, text="Contrast", bg=self.BG, fg=self.MUTED,
                     font=("DejaVu Sans", 7)).pack(side=tk.LEFT)
            self._build_slider_row(
                frame, root, "◐", "◑", ctrl.contrast,
                f"contrast_{key}", lambda v, _c=ctrl: _c.set_contrast(v),
            )

        # Volume slider (only if supported)
        if ctrl.volume >= 0:
            vh = tk.Frame(frame, bg=self.BG)
            vh.pack(fill=tk.X, pady=(2, 0))
            tk.Label(vh, text="Volume", bg=self.BG, fg=self.MUTED,
                     font=("DejaVu Sans", 7)).pack(side=tk.LEFT)
            self._build_slider_row(
                frame, root, "♪", "♫", ctrl.volume,
                f"volume_{key}", lambda v, _c=ctrl: _c.set_volume(v),
            )


# -- Preset system ---------------------------------------------------------


@dataclass
class NitPreset:
    name: str
    monitors: list          # list of {brightness, contrast, volume} dicts
    created_at: str = ""

    def to_dict(self):
        return {"name": self.name, "monitors": self.monitors, "created_at": self.created_at}

    @classmethod
    def from_dict(cls, d):
        return cls(
            name=d["name"],
            monitors=d.get("monitors", []),
            created_at=d.get("created_at", ""),
        )


class PresetManager:
    CONFIG_DIR = Path.home() / ".nit"
    PRESETS_FILE = CONFIG_DIR / "presets.json"

    def __init__(self):
        self.CONFIG_DIR.mkdir(parents=True, exist_ok=True)
        self._presets: list[NitPreset] = self._load()

    def _load(self) -> list[NitPreset]:
        if not self.PRESETS_FILE.exists():
            return []
        try:
            with open(self.PRESETS_FILE) as f:
                data = json.load(f)
            return [NitPreset.from_dict(p) for p in data]
        except Exception:
            return []

    def _save(self):
        with open(self.PRESETS_FILE, "w") as f:
            json.dump([p.to_dict() for p in self._presets], f, indent=2)

    @property
    def presets(self) -> list[NitPreset]:
        return list(self._presets)

    def save_current(self, name: str, multi: LinuxMultiController) -> NitPreset:
        preset = NitPreset(
            name=name,
            monitors=[{
                "brightness": c.brightness,
                "contrast": c.contrast,
                "volume": c.volume,
            } for c in multi.monitors],
            created_at=datetime.now().isoformat(),
        )
        self._presets = [p for p in self._presets if p.name != name]
        self._presets.append(preset)
        self._save()
        return preset

    def delete(self, name: str):
        self._presets = [p for p in self._presets if p.name != name]
        self._save()

    def apply(self, name: str, multi: LinuxMultiController):
        preset = next((p for p in self._presets if p.name == name), None)
        if not preset:
            return
        for i, ctrl in enumerate(multi.monitors):
            if i < len(preset.monitors):
                mon = preset.monitors[i]
                ctrl.set(mon.get("brightness", 50))
                if ctrl.contrast >= 0 and "contrast" in mon:
                    ctrl.set_contrast(mon["contrast"])
                if ctrl.volume >= 0 and "volume" in mon:
                    ctrl.set_volume(mon["volume"])


# -- Schedule system -------------------------------------------------------


@dataclass
class ScheduleRule:
    time: str               # "HH:MM"
    preset_name: str
    enabled: bool = True

    def to_dict(self):
        return {"time": self.time, "preset_name": self.preset_name, "enabled": self.enabled}

    @classmethod
    def from_dict(cls, d):
        return cls(
            time=d["time"],
            preset_name=d["preset_name"],
            enabled=d.get("enabled", True),
        )


class ScheduleManager:
    SCHEDULE_FILE = Path.home() / ".nit" / "schedule.json"

    def __init__(self):
        self._rules: list[ScheduleRule] = self._load()
        self._thread: threading.Thread | None = None
        self._stop_event = threading.Event()
        self._last_applied: str | None = None
        self._preset_manager: PresetManager | None = None
        self._multi: LinuxMultiController | None = None

    def _load(self) -> list[ScheduleRule]:
        if not self.SCHEDULE_FILE.exists():
            return []
        try:
            with open(self.SCHEDULE_FILE) as f:
                data = json.load(f)
            return [ScheduleRule.from_dict(r) for r in data]
        except Exception:
            return []

    def save(self):
        self.SCHEDULE_FILE.parent.mkdir(parents=True, exist_ok=True)
        with open(self.SCHEDULE_FILE, "w") as f:
            json.dump([r.to_dict() for r in self._rules], f, indent=2)

    @property
    def rules(self) -> list[ScheduleRule]:
        return list(self._rules)

    def add_rule(self, time_str: str, preset_name: str):
        self._rules.append(ScheduleRule(time=time_str, preset_name=preset_name))
        self.save()

    def remove_rule(self, time_str: str):
        self._rules = [r for r in self._rules if r.time != time_str]
        self.save()

    def start(self, preset_manager: PresetManager, multi: LinuxMultiController):
        self._preset_manager = preset_manager
        self._multi = multi
        self._stop_event.clear()
        self._thread = threading.Thread(target=self._check_loop, daemon=True)
        self._thread.start()

    def stop(self):
        self._stop_event.set()

    def _check_loop(self):
        while not self._stop_event.wait(60):
            self._check_now()

    def _check_now(self):
        if not self._preset_manager or not self._multi:
            return
        now = datetime.now().strftime("%H:%M")
        enabled = [r for r in self._rules if r.enabled]
        if not enabled:
            return
        # Find the most recently passed rule
        applicable = [r for r in enabled if r.time <= now]
        if not applicable:
            applicable = enabled    # wrap around midnight: pick last rule of day
        rule = max(applicable, key=lambda r: r.time)
        if rule.time != self._last_applied:
            self._last_applied = rule.time
            self._preset_manager.apply(rule.preset_name, self._multi)


# -- System tray app -------------------------------------------------------


class LinuxNitApp:
    def __init__(self):
        self._multi = LinuxMultiController()
        self._preset_manager = PresetManager()
        self._schedule_manager = ScheduleManager()
        self._popup_open = False
        self._popup_lock = threading.Lock()
        self._icon = None

    def _toggle_popup(self, icon=None, item=None):
        with self._popup_lock:
            if self._popup_open:
                return
            self._popup_open = True

        def _run():
            popup = LinuxBrightnessPopup(self._multi, on_close=self._set_popup_closed)
            popup.show()

        threading.Thread(target=_run, daemon=True).start()

    def _set_popup_closed(self):
        with self._popup_lock:
            self._popup_open = False

    def _refresh_icon(self):
        avg = self._multi.average_brightness
        if self._icon:
            self._icon.icon = _make_icon(avg)
            n = self._multi.count
            self._icon.title = f"Nit  {avg}%  ({n} display{'s' if n != 1 else ''})"

    def _apply_preset(self, name: str):
        self._preset_manager.apply(name, self._multi)
        self._refresh_icon()

    def _save_preset_dialog(self, icon=None, item=None):
        """Simple Tkinter dialog to name and save current settings."""
        def _run():
            root = tk.Tk()
            root.title("Save Preset")
            root.attributes("-topmost", True)
            root.geometry("280x120")

            tk.Label(root, text="Preset name:").pack(pady=(16, 4))
            name_var = tk.StringVar(value="My Preset")
            entry = tk.Entry(root, textvariable=name_var, width=30)
            entry.pack()
            entry.focus_set()

            def _save():
                name = name_var.get().strip()
                if name:
                    self._preset_manager.save_current(name, self._multi)
                    if self._icon:
                        self._icon.menu = self._build_menu()
                root.destroy()

            tk.Button(root, text="Save", command=_save).pack(pady=8)
            root.bind("<Return>", lambda _: _save())
            root.mainloop()

        threading.Thread(target=_run, daemon=True).start()

    def _build_menu(self):
        preset_items = []
        for p in self._preset_manager.presets:
            name = p.name
            preset_items.append(
                pystray.MenuItem(name, lambda icon, item, n=name: self._apply_preset(n))
            )
        if preset_items:
            preset_items.append(pystray.Menu.SEPARATOR)
        preset_items.append(
            pystray.MenuItem("Save current...", self._save_preset_dialog)
        )

        return pystray.Menu(
            pystray.MenuItem("Brightness...", self._toggle_popup, default=True),
            pystray.MenuItem("Presets", pystray.Menu(*preset_items)),
            pystray.Menu.SEPARATOR,
            pystray.MenuItem("Quit", self._quit),
        )

    def _quit(self, icon, item):
        self._schedule_manager.stop()
        icon.stop()

    def run(self):
        # Start schedule background thread
        self._schedule_manager.start(self._preset_manager, self._multi)

        avg = self._multi.average_brightness
        n = self._multi.count
        menu = self._build_menu()
        icon = pystray.Icon(
            "nit", _make_icon(avg),
            f"Nit  {avg}%  ({n} display{'s' if n != 1 else ''})",
            menu,
        )
        self._icon = icon
        icon.run()


if __name__ == "__main__":
    LinuxNitApp().run()
