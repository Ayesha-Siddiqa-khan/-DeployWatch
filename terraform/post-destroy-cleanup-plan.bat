@echo off
setlocal
pushd "%~dp0"

echo ========================================
echo TerraPilot Post-Destroy Cleanup Planner
echo ========================================
echo This script is read-only. It creates a cleanup plan and does not delete resources.
echo.

set "AWS_PAGER="
if exist "%~dp0CLEANUP_ENV.bat" call "%~dp0CLEANUP_ENV.bat"

where aws >nul 2>&1
if errorlevel 1 (
  echo [ERROR] AWS CLI is not installed or not available in PATH.
  popd
  pause
  exit /b 1
)

if not exist "%~dp0post-destroy-cleanup.ps1" (
  echo [ERROR] post-destroy-cleanup.ps1 was not found in this folder.
  popd
  pause
  exit /b 1
)

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0post-destroy-cleanup.ps1" -Mode Plan
set "CLEANUP_EXIT=%ERRORLEVEL%"

popd
pause
exit /b %CLEANUP_EXIT%
