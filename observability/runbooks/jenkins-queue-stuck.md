# JenkinsQueueStuck

## Symptom

The Jenkins build queue has been non-empty for five minutes. Builds are waiting
instead of starting, so delivery is delayed.

## Check

PromQL:

```promql
jenkins_queue_size_value{namespace="jenkins"}
```

Dashboard: **Jenkins & Delivery**, the queue and executors panels.

- Separate waiting for capacity from the other queue states:
  `jenkins_queue_buildable_value{namespace="jenkins"}` and
  `jenkins_queue_blocked_value{namespace="jenkins"}`
- Check whether agent pods are being created at all:
  `kubectl -n jenkins get pods` and
  `kubectl -n jenkins get events --sort-by=.lastTimestamp | tail -20`
- Read the controller log: `kubectl -n jenkins logs jenkins-0 -c jenkins --tail=100`

## Recover

1. Check whether builds are running and whether agent capacity is available. A
   queue that remains non-empty for five minutes may indicate delayed agent
   provisioning or insufficient capacity.
2. Agent pods stuck Pending: check node capacity, and the node selector and
   toleration on the agent template.
3. Agent pods never created: confirm the Kubernetes cloud configuration and the
   agent ServiceAccount are intact, then verify that the existing queued build
   can obtain an agent.
4. Confirm the queue drains to zero and the alert resolves.
