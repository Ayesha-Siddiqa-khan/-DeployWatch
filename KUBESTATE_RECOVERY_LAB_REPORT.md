# KubeState Recovery Lab Gap Report

## Already Covered By TerraPilot

- VPC, public/private subnets, Internet Gateway, route tables, and security groups.
- EC2 control-plane and worker node generation.
- kubeadm bootstrap, containerd, Calico CNI, and PostgreSQL client tooling when selected in startup scripts.
- Private ECR repository generation and repository URL output.
- GitHub Actions OIDC ECR push role when IAM Project Policies are enabled.
- Worker EC2 ECR pull role when IAM Project Policies are enabled.
- Kubernetes API hardening through generated security presets instead of exposing 6443 to 0.0.0.0/0.

## Added For This Recovery Lab

- `self-managed-kubernetes.tf` with an optional public AWS Network Load Balancer.
- Fixed ingress-nginx NodePorts: HTTP 30080 and HTTPS 30443.
- Optional Route53 A/alias record controlled by `create_dns_record`, `hosted_zone_id`, and `app_hostname`.
- PostgreSQL backup S3 bucket with server-side encryption, versioning, ownership controls, and full public access block.
- Prefix-scoped PostgreSQL backup/restore IAM policy for `s3://BUCKET_NAME/postgres-backups/*`.
- EBS CSI managed policy attachment for self-managed Kubernetes EC2 node roles.
- gp3 StorageClass, ingress-nginx NodePort Service, cert-manager ClusterIssuer, FastAPI, PostgreSQL, Redis, and backup CronJob manifests.
- Optional monitoring instructions without making Prometheus/Grafana mandatory.

## Still Needs Your Input

- Real domain name, hosted zone ID, and whether `create_dns_record` should be true.
- Real Let's Encrypt email.
- Real FastAPI container image pushed to ECR.
- Real database password and application secret values.
- Confirmation that worker nodes are at least `t3.medium`. Current explicit worker node present: yes.
- A safe GitHub runner strategy. Prefer a self-hosted runner inside the VPC for private control-plane access; avoid exposing Kubernetes API 6443 publicly.

## Apply Order

1. Run Terraform.
2. Wait for kubeadm bootstrap and Calico readiness.
3. Install EBS CSI, ingress-nginx, and cert-manager from the generated runbooks.
4. Replace placeholders in `k8s/stateful-app/*.yaml`.
5. Apply the namespace, storage class, secrets, StatefulSets, services, app Deployment, Ingress, and backup CronJob.
