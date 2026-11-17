@echo off
rem Runs both test suites. Set GODOT to your Godot executable, or edit the line below.
setlocal
if "%GODOT%"=="" set "GODOT=godot"
cd /d "%~dp0"

"%GODOT%" --headless --path . --import >nul 2>&1

echo === core ===
"%GODOT%" --headless --path . --script res://tests/test_runner.gd
set CORE=%ERRORLEVEL%

echo.
echo === interface ===
"%GODOT%" --headless --path . --script res://tests/smoke_ui.gd
set UI=%ERRORLEVEL%

echo.
if %CORE%==0 if %UI%==0 echo ALL SUITES PASSED
pause
