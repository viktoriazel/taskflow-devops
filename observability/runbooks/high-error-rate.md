# HighErrorRate

## Symptom

More than 5% of application requests returned a 5xx response for five minutes.
Users are seeing failures on the service named in the alert labels.

## Check

PromQL:

```promql
sum by (namespace, service) (rate(taskflow_http_requests_total{namespace="devops-app", status=~"5.."}[5m]))
/
sum by (namespace, service) (rate(taskflow_http_requests_total{namespace="devops-app"}[5m]))
```

Dashboard: **Application Overview**, the 5xx Error Rate and Availability panels,
filtered to the affected service.

- Find the failing endpoint:
  `sum by (route, status) (rate(taskflow_http_requests_total{namespace="devops-app", service="<service>", status=~"5.."}[5m]))`
- Check whether a dependency is failing rather than the service itself:
  `sum by (service, dependency) (rate(taskflow_dependency_failures_total{namespace="devops-app"}[5m]))`
- Read the logs of the affected pods:
  `kubectl -n devops-app logs -l app.kubernetes.io/name=<service> --tail=100`

## Recover

1. Compare the release on the Current Release / Version panel with the previous
   one. If the errors started with a new release, roll it back:
   `kubectl -n devops-app rollout undo deployment/<service>`.
2. If a dependency is the source, restore it and confirm that 5xx responses
   decrease.
3. Watch the 5xx Error Rate panel until the error ratio falls below 5% and
   confirm the alert resolves. The 24-hour Availability panel may recover more
   slowly.
