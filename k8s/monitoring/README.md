# Optional Monitoring

Monitoring is intentionally not mandatory for first deployment.

Recommended optional stack:

- Prometheus
- Grafana
- kube-state-metrics
- node-exporter
- PostgreSQL exporter
- Redis exporter

Plain manifest path:

```bash
kubectl create namespace monitoring
kubectl apply -f https://raw.githubusercontent.com/prometheus-operator/kube-prometheus/main/manifests/setup/
kubectl apply -f https://raw.githubusercontent.com/prometheus-operator/kube-prometheus/main/manifests/
```

Review resource requests before applying this on small t3.medium lab nodes.
