@echo off
setlocal enabledelayedexpansion

pushd "%~dp0"

echo ========================================
echo TerraPilot Terraform Destroy Runner
echo ========================================
echo.
echo WARNING:
echo This action can permanently destroy real cloud resources.
echo This may delete EC2 instances, VPCs, subnets, security groups,
echo EKS clusters, S3 buckets, IAM resources, and other infrastructure.
echo.

where terraform >nul 2>&1
if errorlevel 1 (
  echo [ERROR] Terraform is not installed or not available in PATH.
  echo Please install Terraform first:
  echo https://developer.hashicorp.com/terraform/install
  echo.
  popd
  pause
  exit /b 1
)

echo Current folder:
cd
echo.

echo [Safety Check] Terraform version:
terraform version
echo.

set /p CONFIRM="Type DESTROY to confirm terraform destroy, or press Enter to cancel: "

if /I NOT "%CONFIRM%"=="DESTROY" (
  echo.
  echo Destroy cancelled. No resources were changed.
  echo.
  popd
  pause
  exit /b 0
)

echo.
echo You confirmed DESTROY.
echo Terraform will now show the destroy plan and ask for final approval.
echo.

terraform destroy

if errorlevel 1 (
  echo.
  echo [ERROR] terraform destroy failed.
  echo Review the error above and fix the issue before retrying.
  echo.
  popd
  pause
  exit /b 1
)

echo.
echo ========================================
echo Terraform destroy completed successfully.
echo ========================================
echo.
set /p RUN_AUDIT="Do you want to run the post-destroy AWS audit now? Type Y to run, or N to skip [N]: "
if /I "%RUN_AUDIT%"=="Y" (
  if exist "%~dp0post-destroy-audit.bat" (
    call "%~dp0post-destroy-audit.bat"
    echo.
    echo Recommended next step: run post-destroy-cleanup-plan.bat to create a safe cleanup plan.
    echo The cleanup planner is read-only and does not delete resources.
  ) else (
    echo post-destroy-audit.bat was not found in this folder.
  )
 ) else (
  echo.
  echo Recommended next step: run post-destroy-audit.bat to check for leftovers.
  echo Then run post-destroy-cleanup-plan.bat to create a cleanup plan.
)

popd
pause
endlocal
