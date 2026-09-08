# AWS EBS CSI Driver

Terraform attaches `var.ebs_csi_driver_policy_arn` to the self-managed Kubernetes EC2 node role. Install the self-managed EBS CSI driver before applying StatefulSets that use the `gp3` StorageClass.

```bash
kubectl apply -k "github.com/kubernetes-sigs/aws-ebs-csi-driver/deploy/kubernetes/overlays/stable/?ref=release-1.62"
kubectl apply -f k8s/storage/gp3-storageclass.yaml
kubectl get storageclass
```

For production, prefer a dedicated workload identity strategy over broad node instance-profile access.
