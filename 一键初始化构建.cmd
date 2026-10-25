@echo off
REM nianlun - build script (ASCII only, encoding-safe)
REM Platform folders already exist and are configured - no regenerate step here.
title nianlun - build

set PATH=D:\Dev\flutter\bin;C:\Program Files\Git\cmd;%PATH%
set FLUTTER_STORAGE_BASE_URL=https://storage.flutter-io.cn
set PUB_HOSTED_URL=https://pub.flutter-io.cn
set ANDROID_HOME=D:\Dev\android-sdk

cd /d %~dp0

echo ============================================
echo   nianlun - build debug apk
echo ============================================
echo.

if not exist android (
    echo [ERROR] android folder missing. Tell Xiaobai first.
    goto :fail
)

echo [1/4] Flutter version...
call flutter --version
if errorlevel 1 goto :fail

echo.
echo [2/4] Fetching dependencies...
call flutter pub get
if errorlevel 1 goto :fail

echo.
echo [3/4] Static analysis (advisory, does not stop the build)...
call flutter analyze

echo.
echo [4/4] Building Debug APK (first Gradle run may download deps)...
call flutter build apk --debug
if errorlevel 1 goto :fail

echo.
echo ============================================
echo   BUILD SUCCESS
echo   APK: %~dp0build\app\outputs\flutter-apk\app-debug.apk
echo   Copy it to your phone and install.
echo ============================================
goto :end

:fail
echo.
echo XXXXXXXX A STEP FAILED XXXXXXXX
echo Send Xiaobai the red error text above (screenshot is fine).

:end
echo.
pause
