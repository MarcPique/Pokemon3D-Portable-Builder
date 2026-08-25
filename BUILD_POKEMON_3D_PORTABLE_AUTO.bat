@echo off
setlocal EnableExtensions
cd /d "%~dp0"

title Pokemon 3D Portable AUTO Builder v18


if "%~1"=="" (
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0builder.ps1"
) else (
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0builder.ps1" -Rom "%~1"
)

if errorlevel 1 (
    echo.
    echo [ERROR] La compilacion no ha terminado correctamente.
    pause
    exit /b 1
)

echo.
echo [OK] Compilacion terminada.
pause
