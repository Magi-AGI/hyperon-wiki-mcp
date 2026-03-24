@echo off
REM Windows wrapper for update-mcp bash script
REM Runs the script using Git Bash (must be installed)

setlocal

REM Find Git Bash
set "GIT_BASH="

REM Try common Git Bash locations
if exist "C:\Program Files\Git\bin\bash.exe" (
    set "GIT_BASH=C:\Program Files\Git\bin\bash.exe"
) else if exist "C:\Program Files (x86)\Git\bin\bash.exe" (
    set "GIT_BASH=C:\Program Files (x86)\Git\bin\bash.exe"
) else if exist "%LOCALAPPDATA%\Programs\Git\bin\bash.exe" (
    set "GIT_BASH=%LOCALAPPDATA%\Programs\Git\bin\bash.exe"
)

REM Check if Git Bash was found
if "%GIT_BASH%"=="" (
    echo Error: Git Bash not found!
    echo.
    echo Please install Git for Windows from: https://git-scm.com/download/win
    echo Or run the update-mcp script directly in Git Bash.
    exit /b 1
)

REM Get script directory
set "SCRIPT_DIR=%~dp0"

REM Run the bash script with all arguments
"%GIT_BASH%" "%SCRIPT_DIR%update-mcp" %*

endlocal
