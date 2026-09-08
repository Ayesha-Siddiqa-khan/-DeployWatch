@echo off
REM Optional override file. post-destroy-audit.bat auto-detects region/project from terraform.tfvars, main.tf, AWS env vars, and AWS CLI config.
REM Copy this file to AWS_AUDIT_ENV.bat only when you want to override the detected values.
REM Do not commit AWS_AUDIT_ENV.bat if it contains local profile/account details.

REM Optional: set AWS_REGION=us-east-1
REM Optional: set AWS_PROFILE=your-profile-name
REM Optional: set PROJECT_NAME=DeployWatch
REM Optional: set ENVIRONMENT=dev
REM Optional: set ECR_REPOSITORY=deploywatch
