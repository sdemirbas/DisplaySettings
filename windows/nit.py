"""
Nit for Windows — Samsung Smart M70F brightness control
System tray app with DDC/CI → WMI → gamma fallback chain.

Install:  pip install pystray pillow
Build:    pyinstaller --onefile --windowed --name Nit nit.py
"""

from __future__ import annotations

import math
import threading
import ctypes
import ctypes.wintypes as wt
import tkinter as tk
from tkinter import ttk
import pystray
from PIL import Image, ImageDraw


# ── Win32 DDC/CI via Dxva2.dll ───────────────────────────────────────────────

class _PHYSICAL_MONITOR(ctypes.Structure):
    _fields_ = [
        ("hPhysicalMonitor", wt.HANDLE),
        ("szPhysicalMonitorDescription", ctypes.c_wchar * 128),
    ]


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
    BG       = "#1e1e1e"
    FG       = "#f0f0f0"
    MUTED    = "#777777"
    ACCENT   = "#f5a623"
    WIDTH    = 280
    HEIGHT   = 108

    def __init__(self, controller: BrightnessController, on_close):
        self._ctrl     = controller
        self._on_close = on_close
        self._job      = None
        self._root     = None

    def show(self):
        if self._root and self._root.winfo_exists():
            self._root.destroy()
            return

        root = tk.Tk()
        self._root = root
        root.withdraw()
        root.title("Nit")
        root.resizable(False, False)
        root.attributes("-topmost", True)
        root.overrideredirect(True)
        root.configure(bg=self.BG)

        # Position: bottom-right, above taskbar
        sw = root.winfo_screenwidth()
        sh = root.winfo_screenheight()
        x  = sw - self.WIDTH  - 16
        y  = sh - self.HEIGHT - 56
        root.geometry(f"{self.WIDTH}x{self.HEIGHT}+{x}+{y}")

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
        pad = tk.Frame(root, bg=self.BG, padx=14, pady=10)
        pad.pack(fill=tk.BOTH, expand=True)

        # Header row
        header = tk.Frame(pad, bg=self.BG)
        header.pack(fill=tk.X)

        tk.Label(
            header, text="Nit", bg=self.BG, fg=self.FG,
            font=("Segoe UI Semibold", 11)
        ).pack(side=tk.LEFT)

        pct_var = tk.StringVar(value=f"{self._ctrl.brightness}%")
        tk.Label(
            header, textvariable=pct_var, bg=self.BG, fg=self.MUTED,
            font=("Segoe UI", 10)
        ).pack(side=tk.RIGHT)

        # Subtitle
        tk.Label(
            pad,
            text=f"Samsung M70F  ·  {self._ctrl.mode}",
            bg=self.BG, fg=self.MUTED,
            font=("Segoe UI", 8)
        ).pack(anchor=tk.W, pady=(1, 6))

        # Slider row
        row = tk.Frame(pad, bg=self.BG)
        row.pack(fill=tk.X)

        tk.Label(row, text="○", bg=self.BG, fg=self.MUTED,
                 font=("Segoe UI", 9)).pack(side=tk.LEFT)

        style = ttk.Style()
        style.theme_use("clam")
        style.configure("N.Horizontal.TScale",
                         background=self.BG,
                         troughcolor="#3a3a3a",
                         sliderlength=14,
                         sliderrelief="flat")

        slider = ttk.Scale(
            row, from_=0, to=100, orient=tk.HORIZONTAL,
            length=self.WIDTH - 60, style="N.Horizontal.TScale"
        )
        slider.set(self._ctrl.brightness)

        def _on_change(val):
            v = int(float(val))
            pct_var.set(f"{v}%")
            # debounce 80ms
            if self._job:
                root.after_cancel(self._job)
            self._job = root.after(80, lambda: self._ctrl.set(v))

        slider.configure(command=_on_change)
        slider.pack(side=tk.LEFT, padx=4, fill=tk.X, expand=True)

        tk.Label(row, text="◉", bg=self.BG, fg=self.MUTED,
                 font=("Segoe UI", 9)).pack(side=tk.LEFT)


# ── System tray app ───────────────────────────────────────────────────────────

class NitApp:
    def __init__(self):
        self._ctrl        = BrightnessController()
        self._popup_open  = False
        self._popup_lock  = threading.Lock()
        self._icon        = None

    def _toggle_popup(self, icon=None, item=None):
        with self._popup_lock:
            if self._popup_open:
                return
            self._popup_open = True

        def _run():
            popup = BrightnessPopup(
                self._ctrl,
                on_close=lambda: self._set_popup_closed()
            )
            popup.show()

        t = threading.Thread(target=_run, daemon=True)
        t.start()

    def _set_popup_closed(self):
        with self._popup_lock:
            self._popup_open = False

    def _quit(self, icon, item):
        icon.stop()

    def run(self):
        icon_img = _make_icon(self._ctrl.brightness)
        menu = pystray.Menu(
            pystray.MenuItem(
                "Brightness…", self._toggle_popup, default=True
            ),
            pystray.Menu.SEPARATOR,
            pystray.MenuItem("Quit", self._quit),
        )
        self._icon = pystray.Icon(
            "nit", icon_img,
            f"Nit  {self._ctrl.brightness}%  ({self._ctrl.mode})",
            menu
        )
        self._icon.run()


# ── Entry point ───────────────────────────────────────────────────────────────

if __name__ == "__main__":
    # Prevent multiple instances
    mutex = ctypes.windll.kernel32.CreateMutexW(None, False, "NitSingleInstance")
    if ctypes.windll.kernel32.GetLastError() == 183:  # ERROR_ALREADY_EXISTS
        import sys
        sys.exit(0)

    NitApp().run()
