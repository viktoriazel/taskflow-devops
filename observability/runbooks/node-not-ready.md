# NodeNotReady

## Symptom

A node has not reported Ready for five minutes. No new pods are scheduled onto
it, and the pods already running there may be evicted.

## Check

PromQL:

```promql
max by (node) (kube_node_status_condition{condition="Ready", status="true"}) == 0
```

Dashboard: **Kubernetes / Cluster**, the node readiness and capacity panels.

- `kubectl get nodes -o wide` to confirm which node is affected and for how long.
- `kubectl describe node <node>`; the conditions section shows whether the
  kubelet stopped reporting or a pressure condition is set.
- Check resource pressure directly:
  `kube_node_status_condition{condition=~"MemoryPressure|DiskPressure|PIDPressure", status="true"} == 1`

## Recover

1. Check which workloads are still assigned to the affected node:
   `kubectl get pods -A -o wide --field-selector spec.nodeName=<node>`.
2. Disk or memory pressure: identify the workload or node condition causing the
   pressure, then restore capacity or correct the affected workload.
3. If the node remains unhealthy, confirm workload redundancy before draining
   it, then replace or recover the node through the managed node group
   workflow.
4. Confirm the node returns Ready, or that its replacement joined the cluster,
   and the alert resolves.
