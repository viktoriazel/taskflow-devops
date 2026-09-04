# HighLatencyP95

## Symptom

The 95th percentile of request latency stayed above 0.5 seconds for ten minutes.
The service named in the alert labels is responding slowly; errors may or may
not be present.

## Check

PromQL:

```promql
histogram_quantile(0.95, sum by (le, namespace, service) (
  rate(taskflow_http_request_duration_seconds_bucket{namespace="devops-app"}[5m])
))
```

Dashboard: **Application Overview**, the Latency Percentiles panel, filtered to
the affected service. The 0.5 second threshold line marks the SLO.

- Find the slow route:
  `histogram_quantile(0.95, sum by (le, route) (rate(taskflow_http_request_duration_seconds_bucket{namespace="devops-app", service="<service>"}[5m])))`
- Check the CPU Usage and Memory Usage panels in Application Overview for
  resource pressure, and the CPU Throttling panel in Kubernetes / Cluster for
  throttling.
- Check whether dependency failures accompany the latency increase:
  `sum by (dependency) (rate(taskflow_dependency_failures_total{namespace="devops-app", service="<service>"}[5m]))`

## Recover

1. If latency rose with a new release, roll it back:
   `kubectl -n devops-app rollout undo deployment/<service>`.
2. If resource pressure is confirmed, adjust the affected Deployment resources
   and redeploy through the normal delivery path.
3. If a slow dependency is the cause, restore it and confirm p95 returns below
   0.5 seconds.
