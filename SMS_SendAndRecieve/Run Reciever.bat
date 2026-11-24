@echo off
setlocal

set "BASE=%~dp0"
set "TARGET=%BASE%Project-Nimbus\SMS_SendAndRecieve"

if not exist "%TARGET%" (
    if exist "%BASE%SMS_SendAndRecieve" (
        set "TARGET=%BASE%SMS_SendAndRecieve"
    ) else if exist "%BASE%run_reciever.py" (
        set "TARGET=%BASE%"
    ) else (
        echo [ERROR] Could not find SMS_SendAndRecieve folder under "%BASE%"
        pause
        exit /b 1
    )
)

cd /d "%TARGET%"

if not exist "%TARGET%\run_reciever.py" (
    echo [ERROR] Missing run_reciever.py in "%TARGET%"
    pause
    exit /b 1
)

if not exist "%TARGET%\.env" (
    if not exist "%TARGET%\..\.env" (
        if not exist "%TARGET%\..\..\.env" (
            echo [WARNING] No .env file found in "%TARGET%" or parent folders. Make sure SMS_USERNAME and SMS_PASSWORD are set.
        )
    )
)

where cloudflared >nul 2>&1
if errorlevel 1 (
    echo [ERROR] cloudflared was not found in PATH. Install cloudflared or add it to PATH.
    pause
    exit /b 1
)

where python >nul 2>&1
if errorlevel 1 (
    echo [ERROR] python was not found in PATH.
    pause
    exit /b 1
)

echo Starting receiver and tunnel from "%TARGET%"...
python "%TARGET%\run_reciever.py"

echo.
echo Process exited.
pause