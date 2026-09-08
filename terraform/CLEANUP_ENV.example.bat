@echo off
REM Optional override file. post-destroy-cleanup-plan.bat and post-destroy-cleanup-execute.bat auto-detect values from terraform.tfvars, AWS CLI config, and the latest audit report.
REM Copy this file to CLEANUP_ENV.bat only when you want to override detection.
REM Do not commit CLEANUP_ENV.bat if it contains local profile/account details.

REM Optional: set AWS_REGION=us-east-1
REM Optional: set AWS_PROFILE=your-profile-name
REM Optional: set PROJECT_NAME=DeployWatch
REM Optional: set ENVIRONMENT=dev
REM Optional: set AUDIT_REPORT_PATH=
REM Optional: set CLEANUP_PLAN_PATH=
