@echo off
setlocal

set "DEVECO_HOME=F:\Programs\DevEco Studio"
set "JAVA_HOME=%DEVECO_HOME%\jbr"
set "PATH=%JAVA_HOME%\bin;%PATH%"
set "HVIGORW=%DEVECO_HOME%\tools\hvigor\bin\hvigorw.bat"
set "HDC=%DEVECO_HOME%\sdk\default\openharmony\toolchains\hdc.exe"
set "PROJECT_DIR=%~dp0..\harmony-app"
set "HAP_PATH=%PROJECT_DIR%\entry\build\default\outputs\default\entry-default-unsigned.hap"
set "BUNDLE_NAME=com.cleanroom.immich"
set "ABILITY_NAME=EntryAbility"

echo [1/3] Building HAP package via Hvigor...
cd /d "%PROJECT_DIR%"
call "%HVIGORW%" assembleHap
if %ERRORLEVEL% neq 0 (
    echo [ERROR] Build failed!
    exit /b %ERRORLEVEL%
)

echo.
echo [2/3] Installing HAP to HarmonyOS device/emulator...
"%HDC%" install -r "%HAP_PATH%"
if %ERRORLEVEL% neq 0 (
    echo [ERROR] Install failed! Check if emulator is running.
    exit /b %ERRORLEVEL%
)

echo.
echo [3/3] Starting App (%BUNDLE_NAME%)...
"%HDC%" shell aa start -a %ABILITY_NAME% -b %BUNDLE_NAME%

echo.
echo [SUCCESS] App deployed and launched successfully!
pause
