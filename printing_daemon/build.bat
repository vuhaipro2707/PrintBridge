@echo off
chcp 65001 >nul
cd /d "%~dp0"
echo ============================================
echo   DANG BIEN DICH MULTI-FOLDER PRINT DAEMON
echo ============================================

taskkill /F /IM printer_agent.exe >nul 2>&1
set GOPROXY=https://proxy.golang.org,direct

if exist "..\build\temp_go\go\bin\go.exe" (
    ..\build\temp_go\go\bin\go.exe build -o printer_agent.exe main.go
) else (
    go build -o printer_agent.exe main.go
)

if %ERRORLEVEL% equ 0 (
    echo ============================================
    echo   [OK] BIEN DICH THANH CONG: printer_agent.exe
    echo ============================================
) else (
    echo ============================================
    echo   [LOI] BIEN DICH THAT BAI! Kiem tra lai main.go
    echo ============================================
)

echo.
pause
