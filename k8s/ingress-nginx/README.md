# ingress-nginx for self-managed Kubernetes

Install the upstream ingress-nginx controller, then apply the fixed NodePort service in this folder.

```bash
kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/controller-v1.13.0/deploy/static/provider/baremetal/deploy.yaml
kubectl apply -f k8s/ingress-nginx/controller-nodeports.yaml
kubectl -n ingress-nginx get svc ingress-nginx-controller
```

The Terraform NLB forwards port 80 to NodePort 30080 and port 443 to NodePort 30443.
