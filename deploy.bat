@echo off
set HOST=192.168.2.60
set USER=root
set DIR=%~dp0wasi-host

echo ----------------------------------------
echo Deploy wasi-host to %HOST%
echo ----------------------------------------
echo.

echo [1/4] Creating directory on target...
ssh %USER%@%HOST% "mkdir -p /root/wasi-host/"
if %ERRORLEVEL% neq 0 (
    echo [FAILED]
    pause
    exit /b 1
)

echo [2/4] Copying wasi-host-arm32...
scp "%DIR%\zig-out\bin\wasi-host-arm32" %USER%@%HOST%:/root/wasi-host/wasi-host
if %ERRORLEVEL% neq 0 (
    echo [FAILED]
    pause
    exit /b 1
)

echo [3/4] Copying config.json...
scp "%DIR%\config.json" %USER%@%HOST%:/root/wasi-host/
if %ERRORLEVEL% neq 0 (
    echo [FAILED]
    pause
    exit /b 1
)

echo [4/4] Setting execute permission...
ssh %USER%@%HOST% "chmod +x /root/wasi-host/wasi-host"
if %ERRORLEVEL% neq 0 (
    echo [FAILED]
    pause
    exit /b 1
)

echo.
echo ---- Done ----
echo.
echo Run on target:
echo   ssh %USER%@%HOST%
echo   cd /root/wasi-host
echo   ./wasi-host
echo.
pause
