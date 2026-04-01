@echo off
REM Nit for Windows — Build Script
REM Requirements: Python 3.10+, pip install -r requirements.txt

echo Installing dependencies...
pip install -r requirements.txt

echo Building Nit.exe...
pyinstaller ^
    --onefile ^
    --windowed ^
    --name Nit ^
    --add-data "nit.py;." ^
    --hidden-import pystray._win32 ^
    --hidden-import PIL._tkinter_finder ^
    nit.py

echo.
if exist dist\Nit.exe (
    echo BUILD OK: dist\Nit.exe
) else (
    echo BUILD FAILED
)
pause
