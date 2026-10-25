@echo off
REM Run this script as Administrator (right-click - Run as administrator)
REM Adds Windows Defender exclusions for Flutter development folders.
REM This makes Gradle builds much faster by skipping real-time AV scans
REM on source code, build outputs, SDKs and caches (all trusted folders).

net session >nul 2>&1
if %errorlevel% neq 0 (
    echo [ERROR] Please right-click this file and choose:
    echo         "Run as administrator" ^("以管理员身份运行"^)
    echo.
    pause
    exit /b 1
)

echo Adding Defender exclusions for Flutter development...

powershell -NoProfile -Command "Add-MpPreference -ExclusionPath '%~dp0'; Add-MpPreference -ExclusionPath 'D:\Dev\flutter'; Add-MpPreference -ExclusionPath '%USERPROFILE%\.gradle'; Add-MpPreference -ExclusionProcess 'java.exe'; Add-MpPreference -ExclusionProcess 'dart.exe'; Add-MpPreference -ExclusionProcess 'kotlin-compiler-embeddable.jar'"

if %errorlevel% neq 0 (
    echo [ERROR] Failed to add exclusions.
    pause
    exit /b 1
)

echo.
echo DONE. Exclusions added:
echo   - %~dp0   ^(project code and build output^)
echo   - D:\Dev\flutter                   ^(Flutter SDK^)
echo   - %USERPROFILE%\.gradle            ^(Gradle dependency caches^)
echo   - java.exe / dart.exe processes
echo.
echo Now re-run the build script ^("yi jian chu shi hua gou jian.cmd" - the one with a Chinese name in this folder^).
echo.
pause
