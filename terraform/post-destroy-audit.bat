@echo off
setlocal
pushd "%~dp0"

echo ========================================
echo TerraPilot Post-Destroy AWS Audit
echo ========================================
echo This script is read-only. It runs AWS CLI describe/list/get commands only.
echo Cleanup commands are printed as suggestions and are not executed.
echo.

set "AWS_PAGER="
if exist "%~dp0AWS_AUDIT_ENV.bat" call "%~dp0AWS_AUDIT_ENV.bat"

where aws >nul 2>&1
if errorlevel 1 (
  echo [ERROR] AWS CLI is not installed or not available in PATH.
  popd
  if "%TERRAPILOT_AUDIT_NO_PAUSE%"=="" pause
  exit /b 1
)

if not exist "%~dp0post-destroy-audit.ps1" (
  echo [ERROR] post-destroy-audit.ps1 was not found in this folder.
  popd
  if "%TERRAPILOT_AUDIT_NO_PAUSE%"=="" pause
  exit /b 1
)

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0post-destroy-audit.ps1"
set "AUDIT_EXIT=%ERRORLEVEL%"

popd
if "%TERRAPILOT_AUDIT_NO_PAUSE%"=="" pause
exit /b %AUDIT_EXIT%
