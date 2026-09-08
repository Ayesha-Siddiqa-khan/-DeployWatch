@echo off
setlocal enabledelayedexpansion

echo ========================================
echo TerraPilot Terraform Runner
echo ========================================
echo.

where terraform >nul 2>&1
if errorlevel 1 (
  echo [ERROR] Terraform is not installed or not available in PATH.
  echo Please install Terraform first:
  echo https://developer.hashicorp.com/terraform/install
  pause
  exit /b 1
)

echo [1/5] Running terraform fmt...
terraform fmt -recursive
if errorlevel 1 (
  echo [ERROR] terraform fmt failed.
  pause
  exit /b 1
)

echo.
echo [2/5] Running terraform init...
terraform init
if errorlevel 1 (
  echo [ERROR] terraform init failed.
  pause
  exit /b 1
)

echo.
echo [3/5] Running terraform validate...
terraform validate
if errorlevel 1 (
  echo [ERROR] terraform validate failed.
  pause
  exit /b 1
)

echo.
echo [4/5] Running terraform plan...
terraform plan -out=tfplan
if errorlevel 1 (
  echo [ERROR] terraform plan failed.
  pause
  exit /b 1
)

echo.
echo ========================================
echo Terraform plan completed successfully.
echo ========================================
echo.
echo WARNING: terraform apply can create, update, or destroy real cloud resources.
echo.

set /p APPLY_CONFIRM="Do you want to run terraform apply now? Type Y to apply, or N to cancel [N]: "

if /I "%APPLY_CONFIRM%"=="Y" (
  echo.
  echo [5/5] Running terraform apply...
  terraform apply tfplan
  if errorlevel 1 (
    echo [ERROR] terraform apply failed.
    pause
    exit /b 1
  )

  echo.
  echo ========================================
  echo Terraform apply completed successfully.
  echo ========================================
  terraform output
) else (
  echo.
  echo Apply cancelled.
  echo Your saved plan file is: tfplan
  echo To apply later, run:
  echo terraform apply tfplan
)

echo.
pause
endlocal
