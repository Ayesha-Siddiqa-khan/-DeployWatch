# cert-manager TLS

Install cert-manager after the cluster is ready, then apply the ClusterIssuer.

```bash
kubectl apply -f https://github.com/cert-manager/cert-manager/releases/download/v1.19.1/cert-manager.yaml
kubectl apply -f k8s/cert-manager/clusterissuer-letsencrypt.yaml
```

Replace `REPLACE_WITH_LETSENCRYPT_EMAIL` before applying the ClusterIssuer. HTTP-01 challenges are routed through ingress-nginx.
