@echo off
setlocal

set "PS_EXE="
where pwsh.exe >nul 2>nul
if %errorlevel%==0 (
    set "PS_EXE=pwsh.exe"
) else if exist "%LocalAppData%\Microsoft\WindowsApps\pwsh.exe" (
    set "PS_EXE=%LocalAppData%\Microsoft\WindowsApps\pwsh.exe"
) else if exist "%ProgramFiles%\PowerShell\7\pwsh.exe" (
    set "PS_EXE=%ProgramFiles%\PowerShell\7\pwsh.exe"
) else (
    set "PS_EXE=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
)

"%PS_EXE%" -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0dns-switch.ps1" %*
set "EXIT_CODE=%errorlevel%"

if "%~1"=="" (
    if not "%EXIT_CODE%"=="0" (
        echo.
        echo [dns-switch] Exited with error code %EXIT_CODE%.
        pause
    )
)

endlocal & exit /b %EXIT_CODE%
