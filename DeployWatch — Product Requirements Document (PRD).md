# DeployWatch — Product Requirements Document

## 1. Product Overview

**Product Name:** DeployWatch

**Product Type:** DevOps Practice Project

**Purpose:**  
DeployWatch is a small web application that displays the current deployment status and version of an application. The main purpose of the project is to practice a complete DevOps workflow from source code to production deployment.

The application itself should remain simple. The primary learning objective is the **CI/CD and infrastructure workflow**, not complex application functionality.

---

# 2. Goals

The project should allow the developer to practice:

- Git and GitHub workflow
- Docker containerization
- GitHub Actions CI/CD
- AWS ECR
- AWS EC2
- Nginx reverse proxy
- HTTPS with Certbot
- Application health checks
- Basic monitoring with AWS CloudWatch
- Automated deployment
- Deployment troubleshooting

---

# 3. Application Features

## 3.1 Dashboard

The application should have a simple dashboard displaying:

- Application name
- Application status
- Current version
- Deployment environment
- Last deployment time
- Health status

Example:

```text
DeployWatch

Application: DeployWatch
Environment: Production

Status:     Running
Version:    v1.0.4
Health:     Healthy

Last Deployment:
September 8, 2026 — 03:20 PM
```

The UI should be intentionally simple.

---

## 3.2 Health Check Endpoint

The backend must provide:

```text
GET /health
```

Expected response:

```json
{
  "status": "healthy",
  "version": "1.0.4"
}
```

This endpoint will be used by:

- Deployment verification
- Monitoring
- Troubleshooting
- Container health checks

---

## 3.3 Version Endpoint

Provide:

```text
GET /version
```

Example response:

```json
{
  "version": "1.0.4"
}
```

The version should be configurable through an environment variable.

Example:

```text
APP_VERSION=1.0.4
```

---

# 4. Suggested Architecture

```text
                    GitHub
                       |
                       v
                GitHub Actions
                       |
             +---------+---------+
             |                   |
          Run Tests         Build Docker
                                 |
                                 v
                            AWS ECR
                                 |
                                 v
                              AWS EC2
                                 |
                              Docker
                                 |
                              Nginx
                                 |
                                 v
                              Users
```

---

# 5. Technology Stack

## Frontend

Use a simple:

- React.js or Next.js
- Basic CSS/Tailwind CSS

The frontend does not need complex functionality.

## Backend

Use a lightweight API framework such as:

- Python + FastAPI

The backend should expose:

```text
/health
/version
```

## Containerization

Use:

- Docker
- Dockerfile

The application should run inside a Docker container.

## Cloud

Use:

- AWS EC2
- AWS ECR

## CI/CD

Use:

- GitHub
- GitHub Actions

## Web Server

Use:

- Nginx

## HTTPS

Use:

- Certbot
- Let's Encrypt

## Monitoring

Use:

- AWS CloudWatch

---

# 6. Repository Structure

A suggested structure:

```text
deploywatch/
│
├── frontend/
│
├── backend/
│   ├── app/
│   ├── requirements.txt
│   └── Dockerfile
│
├── nginx/
│   └── nginx.conf
│
├── .github/
│   └── workflows/
│       └── deploy.yml
│
├── docker-compose.yml
├── .gitignore
└── README.md
```

The exact structure should follow the architecture chosen during implementation rather than forcing unnecessary files.

---

# 7. CI/CD Pipeline

When code is pushed to the main branch:

```text
Developer
    |
    v
Git Push
    |
    v
GitHub
    |
    v
GitHub Actions
    |
    +--> Install dependencies
    |
    +--> Run tests
    |
    +--> Build Docker image
    |
    +--> Login to AWS ECR
    |
    +--> Push image to ECR
    |
    +--> Deploy to EC2
    |
    +--> Restart application
    |
    +--> Run health check
    |
    v
Deployment Successful
```

---

# 8. Docker Requirements

The application must be containerized.

The Docker image should:

- Use an appropriate lightweight base image
- Install required dependencies
- Copy application code
- Expose the required application port
- Start the application correctly

The container should also have a health check using:

```text
/health
```

---

# 9. AWS Infrastructure

## EC2

Use one EC2 instance for the initial project.

The instance should run:

- Docker
- Docker Compose
- Nginx

The application should be deployed as a Docker container.

## ECR

Create an ECR repository:

```text
deploywatch
```

GitHub Actions will push the Docker image to this repository.

## Security Group

Only expose the ports that are actually required.

Expected public traffic:

```text
80   HTTP
443  HTTPS
```

SSH should be restricted appropriately rather than unnecessarily exposed to the entire internet.

---

# 10. Deployment Strategy

The initial deployment can use a simple replacement strategy:

```text
Pull new Docker image
        ↓
Stop old container
        ↓
Start new container
        ↓
Run health check
        ↓
Deployment successful
```

If the new container fails the health check, the deployment should be considered unsuccessful.

---

# 11. Environment Variables

Configuration should not be hard-coded.

Example:

```text
APP_VERSION
APP_ENV
PORT
```

Sensitive credentials must never be committed to GitHub.

AWS credentials and other secrets should be stored using appropriate GitHub Actions secrets or AWS-native authentication mechanisms.

---

# 12. Monitoring

Use AWS CloudWatch for basic monitoring.

Monitor:

- EC2 CPU utilization
- Application/container logs where practical
- Deployment failures where practical

The initial version does not need a sophisticated monitoring dashboard.

---

# 13. Logging

The application should produce useful logs for:

- Application startup
- Health checks
- Errors
- Deployment-related failures

Logs should be understandable enough to troubleshoot a failed deployment.

---

# 14. Domain and HTTPS

The production application should eventually be accessible through a domain.

Example:

```text
https://deploywatch.example.com
```

Nginx should:

- Receive incoming traffic
- Forward requests to the application
- Handle HTTP → HTTPS redirection

Certbot should be used to obtain and configure the TLS certificate.

---

# 15. Testing Requirements

Before deployment, GitHub Actions should run automated tests.

At minimum, test:

```text
GET /health
```

Expected:

```text
HTTP 200
```

and:

```text
GET /version
```

Expected:

```text
HTTP 200
```

After deployment, the pipeline should perform a production health check.

---

# 16. Success Criteria

The project is considered successful when:

- The application runs locally.
- The application runs inside Docker.
- Docker image is successfully built.
- Docker image is pushed to AWS ECR.
- EC2 can pull and run the image.
- Nginx forwards traffic to the application.
- HTTPS works correctly.
- GitHub Actions automatically deploys changes.
- `/health` returns a healthy response.
- `/version` displays the deployed version.
- CloudWatch provides basic infrastructure/application visibility.
- A code push to `main` can result in a verified production deployment.

---

# 17. Learning Objectives

By completing DeployWatch, the developer should understand the practical relationship between:

```text
Git
 ↓
GitHub
 ↓
CI/CD
 ↓
Docker
 ↓
Container Registry
 ↓
AWS EC2
 ↓
Nginx
 ↓
HTTPS
 ↓
Monitoring
```

The project should emphasize **understanding and troubleshooting each stage**, rather than simply making the deployment work once.

---

# 18. Out of Scope

To keep the project small, the first version should NOT include:

- User authentication
- Payment systems
- Complex databases
- Kubernetes
- Microservices
- Multi-region deployment
- Auto-scaling
- Complex analytics
- Mobile applications
- Advanced notification systems

These can be considered future learning exercises after the basic deployment pipeline works.

---

# 19. Future Enhancements

After the initial version is stable, optional improvements could include:

- Blue/green deployment
- Rollback to previous image
- Deployment history
- Slack/email deployment notifications
- Docker image tagging with Git commit SHA
- Automatic rollback after failed health checks
- Terraform for AWS infrastructure
- Ansible for EC2 configuration
- Prometheus/Grafana monitoring
- Kubernetes deployment

These should only be added after the basic CI/CD pipeline is working reliably.

---

# 20. Definition of Done

DeployWatch is complete when a developer can make a code change, run:

```bash
git push origin main
```

and GitHub Actions automatically:

```text
Test
  ↓
Build
  ↓
Push Docker image
  ↓
Deploy to EC2
  ↓
Verify application
  ↓
Report success/failure
```

The deployed application should then be accessible through HTTPS and display the newly deployed version.