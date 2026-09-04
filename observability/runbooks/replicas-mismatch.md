# ReplicasMismatch

## Symptom

A Deployment has had fewer available replicas than desired for five minutes.
Capacity is reduced, and at zero available replicas the workload is
unavailable.

## Check

PromQL:

```promql
max by (namespace, deployment) (kube_deployment_status_replicas_available{namespace=~"devops-app|observability"})
<
max by (namespace, deployment) (kube_deployment_spec_replicas{namespace=~"devops-app|observability"})
```

Dashboard: **Kubernetes / Cluster**, the desired versus available replicas and
pod health panels.

- `kubectl -n <namespace> rollout status deployment/<deployment>`
- `kubectl -n <namespace> get pods -o wide`; identify Pods owned by the affected
  Deployment and look for Pending, CrashLoopBackOff, image pull errors, or
  containers that never become ready.
- `kubectl -n <namespace> describe pod <pod>`; the events say whether the pod
  failed to schedule, failed to pull its image, or failed its readiness probe.

## Recover

1. Failing readiness or liveness probe: fix the probe or the code path it
   checks. If a release introduced it, roll back with
   `kubectl -n <namespace> rollout undo deployment/<deployment>`.
2. Pending pods: check node capacity on the Kubernetes / Cluster dashboard, then
   resolve the scheduling constraint or add capacity through the normal
   infrastructure workflow.
3. Image pull failure: confirm the image digest in the Deployment still exists
   in the registry, then deploy the last known good release.
4. Confirm available replicas match desired and the alert resolves.
