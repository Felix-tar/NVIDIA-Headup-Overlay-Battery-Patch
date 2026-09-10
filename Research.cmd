@echo off
setlocal
cd /d "%~dp0"
echo NVOverlay Battery Patch - Research / Compatibility Collector
echo ===========================================================
echo.
echo Dieses Tool veraendert KEINE NVIDIA-Dateien.
echo Es sammelt Diagnose- und Frontend-Daten fuer eine private KI-/Entwickleranalyse.
echo.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Research-NvidiaOverlay.ps1"
echo.
pause
