# PrometheusTargetDown

## Symptom

A scrape target in `devops-app`, `jenkins` or `observability` has been down for
five minutes. Its metrics are missing, so related dashboard data is unavailable
and alerts that depend on those metrics may no longer evaluate correctly.

## Check

PromQL:

```promql
up{namespace=~"devops-app|jenkins|observability"} == 0
```

Reach the Prometheus targets page with
`kubectl -n observability port-forward svc/observability-kube-prometh-prometheus 9090:9090`,
then open Status, Target health.

- Identify the target from the `job`, `instance` and `namespace` labels on the
  alert and read its last scrape error on that page.
- Confirm the pod is running and the endpoint has addresses:
  `kubectl -n <namespace> get pods` and
  `kubectl -n <namespace> get endpoints <service>`
- Confirm the ServiceMonitor still matches the Service labels and port name:
  `kubectl -n <namespace> get servicemonitor -o yaml`

## Recover

1. Pod not running: recover the workload first, then confirm that the target is
   discovered and scraping successfully again.
2. Empty endpoint: verify the Service selector and Pod readiness. Port mismatch:
   align the Service port name with the ServiceMonitor endpoint and deploy the
   corrected manifest through the normal configuration workflow.
3. Scrape refused or timing out: confirm that the metrics endpoint answers from
   inside the cluster. For targets in `observability`, also confirm that
   `observability/manifests/10-networkpolicy.yaml` allows the scrape path.
4. Confirm the target reports UP and the alert resolves.
