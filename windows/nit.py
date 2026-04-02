"""
Nit for Windows — Samsung Smart M70F brightness control
System tray app with DDC/CI → WMI → gamma fallback chain.

Install:  pip install pystray pillow
Build:    pyinstaller --onefile --windowed --name Nit nit.py
"""

from __future__ import annotations

import json
import math
import threading
import ctypes
import ctypes.wintypes as wt
import tkinter as tk
from tkinter import ttk
from dataclasses import dataclass
from datetime import datetime
from pathlib import Path

import pystray
from PIL import Image, ImageDraw


# ── Win32 DDC/CI via Dxva2.dll ───────────────────────────────────────────────

class _PHYSICAL_MONITOR(ctypes.Structure):
    _fields_ = [
        ("hPhysicalMonitor", wt.HANDLE),
        ("szPhysicalMonitorDescription", ctypes.c_wchar * 128),
    ]


@dataclass
class MonitorInfo:
    hmonitor: wt.HMONITOR
    description: str
    index: int


class DDCController:
    """Controls brightness via the Windows High-Level Monitor Configuration API."""

    def __init__(self):
        self._lib = self._load()

    def _load(self):
        try:
            lib = ctypes.WinDLL("Dxva2.dll")
            lib.GetNumberOfPhysicalMonitorsFromHMONITOR.argtypes = [
                wt.HMONITOR, ctypes.POINTER(wt.DWORD)]
            lib.GetNumberOfPhysicalMonitorsFromHMONITOR.restype = wt.BOOL
            lib.GetPhysicalMonitorsFromHMONITOR.argtypes = [
                wt.HMONITOR, wt.DWORD, ctypes.POINTER(_PHYSICAL_MONITOR)]
            lib.GetPhysicalMonitorsFromHMONITOR.restype = wt.BOOL
            lib.GetMonitorBrightness.argtypes = [
                wt.HANDLE,
                ctypes.POINTER(wt.DWORD), ctypes.POINTER(wt.DWORD), ctypes.POINTER(wt.DWORD)]
            lib.GetMonitorBrightness.restype = wt.BOOL
            lib.SetMonitorBrightness.argtypes = [wt.HANDLE, wt.DWORD]
            lib.SetMonitorBrightness.restype = wt.BOOL
            lib.DestroyPhysicalMonitors.argtypes = [
                wt.DWORD, ctypes.POINTER(_PHYSICAL_MONITOR)]
            lib.DestroyPhysicalMonitors.restype = wt.BOOL

            # Generic VCP read/write for contrast, volume, etc.
            try:
                lib.GetMonitorVCPFeatureAndVCPFeatureReply.argtypes = [
                    wt.HANDLE, wt.BYTE,
                    ctypes.POINTER(wt.DWORD),   # pvct (MC_VCP_CODE_TYPE, pass NULL)
                    ctypes.POINTER(wt.DWORD),   # pdwCurrentValue
                    ctypes.POINTER(wt.DWORD),   # pdwMaximumValue
                ]
                lib.GetMonitorVCPFeatureAndVCPFeatureReply.restype = wt.BOOL
                lib.SetVCPFeature.argtypes = [wt.HANDLE, wt.BYTE, wt.DWORD]
                lib.SetVCPFeature.restype = wt.BOOL
            except Exception:
                pass  # VCP functions not available, contrast/volume won't work

            return lib
        except Exception:
            return None

    # -- helpers ---------------------------------------------------------------

    def _enum_hmonitors(self) -> list:
        result: list = []
        EnumProc = ctypes.WINFUNCTYPE(
            wt.BOOL, wt.HMONITOR, wt.HDC, ctypes.POINTER(wt.RECT), wt.LPARAM)

        def _cb(hm, _hdc, _rect, _lp):
            result.append(hm)
            return True

        ctypes.windll.user32.EnumDisplayMonitors(None, None, EnumProc(_cb), 0)
        return result

    def _with_physical_monitors(self, hmonitor, callback):
        """Calls callback(handle, description) for every physical monitor on hmonitor."""
        if not self._lib:
            return
        count = wt.DWORD(0)
        if not self._lib.GetNumberOfPhysicalMonitorsFromHMONITOR(hmonitor, ctypes.byref(count)):
            return
        n = count.value
        if n == 0:
            return
        arr = (_PHYSICAL_MONITOR * n)()
        if not self._lib.GetPhysicalMonitorsFromHMONITOR(hmonitor, n, arr):
            return
        try:
            for i in range(n):
                callback(arr[i].hPhysicalMonitor, arr[i].szPhysicalMonitorDescription)
        finally:
            self._lib.DestroyPhysicalMonitors(n, arr)

    # -- public API ------------------------------------------------------------

    def get_brightness(self) -> int | None:
        """Returns current brightness (0-100) or None if DDC unavailable."""
        if not self._lib:
            return None
        result = [None]

        def _check(handle, desc):
            if result[0] is not None:
                return
            mn, cur, mx = wt.DWORD(), wt.DWORD(), wt.DWORD()
            if self._lib.GetMonitorBrightness(
                    handle, ctypes.byref(mn), ctypes.byref(cur), ctypes.byref(mx)):
                if mx.value > 0:
                    result[0] = int(cur.value / mx.value * 100)

        for hm in self._enum_hmonitors():
            self._with_physical_monitors(hm, _check)
            if result[0] is not None:
                return result[0]
        return None

    def set_brightness(self, value: int) -> bool:
        """Sets brightness (0-100). Returns True on success."""
        if not self._lib:
            return False
        value = max(0, min(100, value))
        success = [False]

        def _set(handle, desc):
            if self._lib.SetMonitorBrightness(handle, wt.DWORD(value)):
                success[0] = True

        for hm in self._enum_hmonitors():
            self._with_physical_monitors(hm, _set)
        return success[0]

    # -- per-monitor API -------------------------------------------------------

    def enumerate_monitors(self) -> list:
        """Returns list of MonitorInfo for each logical monitor."""
        result = []
        for idx, hm in enumerate(self._enum_hmonitors()):
            desc_holder = [""]
            def _capture(handle, desc, _idx=idx):
                if desc:
                    desc_holder[0] = desc
            self._with_physical_monitors(hm, _capture)
            result.append(MonitorInfo(hmonitor=hm, description=desc_holder[0] or f"Monitor {idx + 1}", index=idx))
        return result

    def get_brightness_for(self, hmonitor) -> int | None:
        """Gets brightness for a specific HMONITOR."""
        if not self._lib:
            return None
        result = [None]
        def _check(handle, desc):
            if result[0] is not None:
                return
            mn, cur, mx = wt.DWORD(), wt.DWORD(), wt.DWORD()
            if self._lib.GetMonitorBrightness(handle, ctypes.byref(mn), ctypes.byref(cur), ctypes.byref(mx)):
                if mx.value > 0:
                    result[0] = int(cur.value / mx.value * 100)
        self._with_physical_monitors(hmonitor, _check)
        return result[0]

    def set_brightness_for(self, hmonitor, value: int) -> bool:
        """Sets brightness for a specific HMONITOR only."""
        if not self._lib:
            return False
        value = max(0, min(100, value))
        success = [False]
        def _set(handle, desc):
            if self._lib.SetMonitorBrightness(handle, wt.DWORD(value)):
                success[0] = True
        self._with_physical_monitors(hmonitor, _set)
        return success[0]

    # -- generic VCP API ---------------------------------------------------

    def get_vcp_for(self, hmonitor, vcp_code: int) -> int | None:
        """Read a VCP feature value (0-100 scale) for a specific monitor."""
        if not self._lib or not hasattr(self._lib, 'GetMonitorVCPFeatureAndVCPFeatureReply'):
            return None
        result = [None]

        def _read(handle, desc):
            if result[0] is not None:
                return
            cur = wt.DWORD()
            mx = wt.DWORD()
            if self._lib.GetMonitorVCPFeatureAndVCPFeatureReply(
                    handle, wt.BYTE(vcp_code), None, ctypes.byref(cur), ctypes.byref(mx)):
                if mx.value > 0:
                    result[0] = int(cur.value / mx.value * 100)

        self._with_physical_monitors(hmonitor, _read)
        return result[0]

    def set_vcp_for(self, hmonitor, vcp_code: int, value: int) -> bool:
        """Write a VCP feature value (0-100 scale) for a specific monitor."""
        if not self._lib or not hasattr(self._lib, 'SetVCPFeature'):
            return False
        value = max(0, min(100, value))
        success = [False]

        def _write(handle, desc):
            if self._lib.SetVCPFeature(handle, wt.BYTE(vcp_code), wt.DWORD(value)):
                success[0] = True

        self._with_physical_monitors(hmonitor, _write)
        return success[0]


# ── WMI fallback ─────────────────────────────────────────────────────────────

class WMIController:
    """Controls brightness via WMI WmiMonitorBrightness (works on some laptops/panels)."""

    def get_brightness(self) -> int | None:
        try:
            import subprocess
            r = subprocess.run(
                ["powershell", "-NoProfile", "-NonInteractive", "-Command",
                 "(Get-WmiObject -Namespace root/wmi -Class WmiMonitorBrightness"
                 " -ErrorAction SilentlyContinue).CurrentBrightness"],
                capture_output=True, text=True, timeout=5)
            val = r.stdout.strip()
            if val.isdigit():
                return int(val)
        except Exception:
            pass
        return None

    def set_brightness(self, value: int) -> bool:
        try:
            import subprocess
            value = max(0, min(100, value))
            r = subprocess.run(
                ["powershell", "-NoProfile", "-NonInteractive", "-Command",
                 f"(Get-WmiObject -Namespace root/wmi -Class WmiMonitorBrightnessMethods"
                 f" -ErrorAction SilentlyContinue).WmiSetBrightness(1,{value})"],
                capture_output=True, timeout=5)
            return r.returncode == 0
        except Exception:
            return False


# ── Software gamma fallback ───────────────────────────────────────────────────

class GammaController:
    """Software brightness via SetDeviceGammaRamp — visual dimming only."""

    def get_brightness(self) -> int:
        return 100  # Can't reliably read back gamma we set

    def set_brightness(self, value: int) -> bool:
        try:
            cap = max(0.0, min(1.0, value / 100.0))
            ramp = (ctypes.c_ushort * 256 * 3)()
            for i in range(256):
                v = min(65535, int(i * cap * 257))
                ramp[0][i] = v
                ramp[1][i] = v
                ramp[2][i] = v
            hdc = ctypes.windll.user32.GetDC(None)
            ok = bool(ctypes.windll.gdi32.SetDeviceGammaRamp(hdc, ctypes.byref(ramp)))
            ctypes.windll.user32.ReleaseDC(None, hdc)
            return ok
        except Exception:
            return False


# ── Unified controller ────────────────────────────────────────────────────────

class BrightnessController:
    """
    Tries DDC/CI first, falls back to WMI, then gamma.
    Remembers which mode worked so subsequent calls are fast.
    """

    MODE_DDC   = "DDC/CI"
    MODE_WMI   = "WMI"
    MODE_GAMMA = "Software"

    def __init__(self):
        self._ddc   = DDCController()
        self._wmi   = WMIController()
        self._gamma = GammaController()
        self._mode  = None
        self._value = 50
        self._probe()

    def _probe(self):
        val = self._ddc.get_brightness()
        if val is not None:
            self._mode  = self.MODE_DDC
            self._value = val
            return
        val = self._wmi.get_brightness()
        if val is not None:
            self._mode  = self.MODE_WMI
            self._value = val
            return
        self._mode  = self.MODE_GAMMA
        self._value = 100

    @property
    def mode(self) -> str:
        return self._mode or self.MODE_GAMMA

    @property
    def brightness(self) -> int:
        return self._value

    def set(self, value: int):
        value = max(0, min(100, value))
        self._value = value

        if self._mode == self.MODE_DDC:
            if self._ddc.set_brightness(value):
                return
            self._mode = self.MODE_WMI  # DDC stopped working, downgrade

        if self._mode == self.MODE_WMI:
            if self._wmi.set_brightness(value):
                return
            self._mode = self.MODE_GAMMA

        self._gamma.set_brightness(value)


class PerMonitorController:
    """Controls a single physical monitor independently. Falls back to gamma."""

    VCP_CONTRAST = 0x12
    VCP_VOLUME   = 0x62

    def __init__(self, ddc: DDCController, monitor: MonitorInfo, gamma: GammaController):
        self._ddc = ddc
        self._monitor = monitor
        self._gamma = gamma
        self._mode = BrightnessController.MODE_GAMMA
        self._value = 50
        self._contrast = -1   # -1 = not supported
        self._volume   = -1
        self._probe()
        self._probe_extras()

    def _probe(self):
        val = self._ddc.get_brightness_for(self._monitor.hmonitor)
        if val is not None:
            self._mode = BrightnessController.MODE_DDC
            self._value = val
        else:
            self._mode = BrightnessController.MODE_GAMMA
            self._value = 100

    def _probe_extras(self):
        val = self._ddc.get_vcp_for(self._monitor.hmonitor, self.VCP_CONTRAST)
        if val is not None:
            self._contrast = val
        val = self._ddc.get_vcp_for(self._monitor.hmonitor, self.VCP_VOLUME)
        if val is not None:
            self._volume = val

    @property
    def name(self) -> str:
        return self._monitor.description or f"Display {self._monitor.index + 1}"

    @property
    def mode(self) -> str:
        return self._mode

    @property
    def brightness(self) -> int:
        return self._value

    @property
    def contrast(self) -> int:
        return self._contrast  # -1 if not supported

    def set_contrast(self, value: int):
        value = max(0, min(100, value))
        self._contrast = value
        self._ddc.set_vcp_for(self._monitor.hmonitor, self.VCP_CONTRAST, value)

    @property
    def volume(self) -> int:
        return self._volume  # -1 if not supported

    def set_volume(self, value: int):
        value = max(0, min(100, value))
        self._volume = value
        self._ddc.set_vcp_for(self._monitor.hmonitor, self.VCP_VOLUME, value)

    def set(self, value: int):
        value = max(0, min(100, value))
        self._value = value
        if self._mode == BrightnessController.MODE_DDC:
            if self._ddc.set_brightness_for(self._monitor.hmonitor, value):
                return
            self._mode = BrightnessController.MODE_GAMMA
        self._gamma.set_brightness(value)


class MultiMonitorController:
    """Manages independent PerMonitorController instances per physical monitor."""

    def __init__(self):
        self._ddc = DDCController()
        self._gamma = GammaController()
        self._controllers: list = []
        self._refresh()

    def _refresh(self):
        monitors = self._ddc.enumerate_monitors()
        if monitors:
            self._controllers = [
                PerMonitorController(self._ddc, m, self._gamma) for m in monitors
            ]
        else:
            # Fallback: single legacy controller
            legacy = BrightnessController()
            legacy._monitor_name = "Display"
            self._controllers = [legacy]

    @property
    def monitors(self) -> list:
        return self._controllers

    @property
    def count(self) -> int:
        return len(self._controllers)

    @property
    def average_brightness(self) -> int:
        if not self._controllers:
            return 50
        return int(sum(c.brightness for c in self._controllers) / len(self._controllers))


# ── Tray icon image ───────────────────────────────────────────────────────────

def _make_icon(brightness: int = 50) -> Image.Image:
    size = 64
    img  = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    draw = ImageDraw.Draw(img)

    intensity = max(0.3, brightness / 100.0)
    r = int(255)
    g = int(165 + 90 * intensity)
    b = 0
    color = (r, g, b, 230)

    cx = cy = size // 2
    core_r = int(size * 0.28 * intensity + size * 0.12)

    # Rays
    ray_count = 8
    for i in range(ray_count):
        angle = math.radians(i * 360 / ray_count)
        inner = core_r + 3
        outer = core_r + int(9 * intensity) + 3
        x1 = cx + inner * math.cos(angle)
        y1 = cy + inner * math.sin(angle)
        x2 = cx + outer * math.cos(angle)
        y2 = cy + outer * math.sin(angle)
        draw.line([x1, y1, x2, y2], fill=color, width=max(2, int(3 * intensity)))

    # Core
    draw.ellipse(
        [cx - core_r, cy - core_r, cx + core_r, cy + core_r],
        fill=color
    )
    return img


# ── Popup window ──────────────────────────────────────────────────────────────

class BrightnessPopup:
    BG    = "#1e1e1e"
    FG    = "#f0f0f0"
    MUTED = "#777777"
    ACCENT = "#f5a623"
    WIDTH = 280
    PER_MONITOR_HEIGHT = 76
    BASE_HEIGHT = 44

    def __init__(self, multi: MultiMonitorController, on_close):
        self._multi    = multi
        self._on_close = on_close
        self._jobs     = {}
        self._root     = None

    def _compute_height(self) -> int:
        total = self.BASE_HEIGHT
        for ctrl in self._multi.monitors:
            h = self.PER_MONITOR_HEIGHT
            contrast = getattr(ctrl, 'contrast', -1)
            volume = getattr(ctrl, 'volume', -1)
            if contrast >= 0:
                h += 24
            if volume >= 0:
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
        x  = sw - self.WIDTH - 16
        y  = sh - height - 56
        root.geometry(f"{self.WIDTH}x{height}+{x}+{y}")

        self._build_ui(root)

        root.deiconify()
        root.focus_force()
        root.bind("<FocusOut>", lambda _: self._close())
        root.bind("<Escape>",   lambda _: self._close())
        root.mainloop()

    def _close(self):
        if self._root and self._root.winfo_exists():
            self._root.destroy()
        self._root = None
        self._on_close()

    def _build_ui(self, root):
        # Apply style once
        style = ttk.Style()
        style.theme_use("clam")
        style.configure("N.Horizontal.TScale",
                        background=self.BG,
                        troughcolor="#3a3a3a",
                        sliderlength=14,
                        sliderrelief="flat")

        pad = tk.Frame(root, bg=self.BG, padx=14, pady=10)
        pad.pack(fill=tk.BOTH, expand=True)

        # App title
        tk.Label(pad, text="Nit", bg=self.BG, fg=self.FG,
                 font=("Segoe UI Semibold", 11)).pack(anchor=tk.W, pady=(0, 4))

        for ctrl in self._multi.monitors:
            self._build_monitor_section(pad, ctrl, root)

    def _build_slider_row(self, parent, root, label_left: str, label_right: str,
                          initial: int, key_suffix: str, callback):
        """Build a labeled slider row and return the percentage StringVar."""
        row = tk.Frame(parent, bg=self.BG)
        row.pack(fill=tk.X)
        tk.Label(row, text=label_left, bg=self.BG, fg=self.MUTED,
                 font=("Segoe UI", 9)).pack(side=tk.LEFT)

        slider = ttk.Scale(row, from_=0, to=100, orient=tk.HORIZONTAL,
                           length=self.WIDTH - 60, style="N.Horizontal.TScale")
        slider.set(initial)

        key = f"{key_suffix}"

        def _on_change(val, _key=key):
            v = int(float(val))
            if _key in self._jobs:
                root.after_cancel(self._jobs[_key])
            self._jobs[_key] = root.after(80, lambda: callback(v))

        slider.configure(command=_on_change)
        slider.pack(side=tk.LEFT, padx=4, fill=tk.X, expand=True)
        tk.Label(row, text=label_right, bg=self.BG, fg=self.MUTED,
                 font=("Segoe UI", 9)).pack(side=tk.LEFT)

    def _build_monitor_section(self, parent, ctrl, root):
        frame = tk.Frame(parent, bg=self.BG)
        frame.pack(fill=tk.X, pady=(4, 0))

        # Monitor name + percentage
        header = tk.Frame(frame, bg=self.BG)
        header.pack(fill=tk.X)

        name = getattr(ctrl, 'name', getattr(ctrl, '_monitor_name', 'Display'))
        tk.Label(header, text=name, bg=self.BG, fg=self.FG,
                 font=("Segoe UI", 9)).pack(side=tk.LEFT)

        pct_var = tk.StringVar(value=f"{ctrl.brightness}%")
        tk.Label(header, textvariable=pct_var, bg=self.BG, fg=self.MUTED,
                 font=("Segoe UI", 9)).pack(side=tk.RIGHT)

        # Mode label
        tk.Label(frame, text=ctrl.mode, bg=self.BG, fg=self.MUTED,
                 font=("Segoe UI", 7)).pack(anchor=tk.W)

        # Brightness slider row
        key = id(ctrl)

        row = tk.Frame(frame, bg=self.BG)
        row.pack(fill=tk.X)
        tk.Label(row, text="○", bg=self.BG, fg=self.MUTED,
                 font=("Segoe UI", 9)).pack(side=tk.LEFT)

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
                 font=("Segoe UI", 9)).pack(side=tk.LEFT)

        # Contrast slider (only if supported)
        contrast = getattr(ctrl, 'contrast', -1)
        if contrast >= 0:
            contrast_header = tk.Frame(frame, bg=self.BG)
            contrast_header.pack(fill=tk.X, pady=(2, 0))
            tk.Label(contrast_header, text="Contrast", bg=self.BG, fg=self.MUTED,
                     font=("Segoe UI", 7)).pack(side=tk.LEFT)
            self._build_slider_row(
                frame, root, "◐", "◑", contrast,
                f"contrast_{key}",
                lambda v, _c=ctrl: _c.set_contrast(v),
            )

        # Volume slider (only if supported)
        volume = getattr(ctrl, 'volume', -1)
        if volume >= 0:
            volume_header = tk.Frame(frame, bg=self.BG)
            volume_header.pack(fill=tk.X, pady=(2, 0))
            tk.Label(volume_header, text="Volume", bg=self.BG, fg=self.MUTED,
                     font=("Segoe UI", 7)).pack(side=tk.LEFT)
            self._build_slider_row(
                frame, root, "♪", "♫", volume,
                f"volume_{key}",
                lambda v, _c=ctrl: _c.set_volume(v),
            )


# ── Preset system ────────────────────────────────────────────────────────────

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
    CONFIG_DIR   = Path.home() / ".nit"
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

    def save_current(self, name: str, multi: MultiMonitorController) -> NitPreset:
        preset = NitPreset(
            name=name,
            monitors=[{
                "brightness": c.brightness,
                "contrast": getattr(c, 'contrast', -1),
                "volume": getattr(c, 'volume', -1),
            } for c in multi.monitors],
            created_at=datetime.now().isoformat(),
        )
        # Replace existing with same name
        self._presets = [p for p in self._presets if p.name != name]
        self._presets.append(preset)
        self._save()
        return preset

    def delete(self, name: str):
        self._presets = [p for p in self._presets if p.name != name]
        self._save()

    def apply(self, name: str, multi: MultiMonitorController):
        preset = next((p for p in self._presets if p.name == name), None)
        if not preset:
            return
        for i, ctrl in enumerate(multi.monitors):
            if i < len(preset.monitors):
                mon = preset.monitors[i]
                ctrl.set(mon.get("brightness", 50))
                if getattr(ctrl, 'contrast', -1) >= 0 and "contrast" in mon:
                    ctrl.set_contrast(mon["contrast"])
                if getattr(ctrl, 'volume', -1) >= 0 and "volume" in mon:
                    ctrl.set_volume(mon["volume"])


# ── Schedule system ──────────────────────────────────────────────────────────

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
        self._last_applied: str | None = None   # "HH:MM" of last applied rule
        self._preset_manager: PresetManager | None = None
        self._multi: MultiMonitorController | None = None

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

    def start(self, preset_manager: PresetManager, multi: MultiMonitorController):
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


# ── System tray app ───────────────────────────────────────────────────────────

class NitApp:
    def __init__(self):
        self._multi           = MultiMonitorController()
        self._preset_manager  = PresetManager()
        self._schedule_manager = ScheduleManager()
        self._popup_open      = False
        self._popup_lock      = threading.Lock()
        self._icon            = None

    def _toggle_popup(self, icon=None, item=None):
        with self._popup_lock:
            if self._popup_open:
                return
            self._popup_open = True

        def _run():
            popup = BrightnessPopup(
                self._multi,
                on_close=lambda: self._set_popup_closed()
            )
            popup.show()

        t = threading.Thread(target=_run, daemon=True)
        t.start()

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
        n   = self._multi.count
        icon_img = _make_icon(avg)
        label = f"Nit  {avg}%  ({n} display{'s' if n != 1 else ''})"
        menu = self._build_menu()
        self._icon = pystray.Icon("nit", icon_img, label, menu)
        self._icon.run()


# ── Entry point ───────────────────────────────────────────────────────────────

if __name__ == "__main__":
    # Prevent multiple instances
    mutex = ctypes.windll.kernel32.CreateMutexW(None, False, "NitSingleInstance")
    if ctypes.windll.kernel32.GetLastError() == 183:  # ERROR_ALREADY_EXISTS
        import sys
        sys.exit(0)

    NitApp().run()
