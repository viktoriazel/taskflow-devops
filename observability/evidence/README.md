# Observability Evidence

This folder contains screenshots that show the main runtime checks for TaskFlow monitoring and observability. Each item below explains what the screenshot demonstrates.

## 🟣 01 — Prometheus Platform Targets

Prometheus platform targets are healthy: 31 targets are UP and 0 are DOWN.

![Prometheus platform targets](./01_prometheus_targets_31_up_0_down.png)

## 🟣 02 — Observability Stack and Network Policies

The observability stack is running in EKS, node-exporter covers all cluster nodes, and the required ingress NetworkPolicies are applied.

![Observability stack and NetworkPolicies](./02_observability_stack_and_network_policies.png)

## 🟣 03 — NetworkPolicy Enforcement

NetworkPolicy enforcement blocks unauthorized access to Prometheus while allowing the required monitoring communication.

![NetworkPolicy enforcement](./03_network_policy_enforcement.png)

## 🟣 04 — Application and Jenkins Targets

Prometheus successfully discovers and scrapes two Frontend targets, two Backend targets, two Worker targets, and one Jenkins metrics target.

![Application and Jenkins targets](./04_application_jenkins_targets_up.png)

## 🟣 05 — Application Overview

The Application Overview dashboard shows real traffic, 0% 5xx errors, 100% availability, p50/p95/p99 latency, CPU usage, and memory usage.

![Application Overview dashboard](./05_application_overview.png)

## 🟣 06 — Release Identity

The running application Pods are linked to the deployed version, Git SHA, and CI release, providing runtime release traceability.

![Application release identity](./06_application_release_identity.png)

## 🟣 07 — Kubernetes Cluster Overview

The Kubernetes Cluster dashboard shows all nodes ready, no pending or unready Pods, and node CPU, memory, disk, and capacity commitment per node.

![Kubernetes cluster overview](./07_kubernetes_cluster_overview.png)

## 🟣 08 — Kubernetes Cluster Workloads and Storage

The same dashboard covers container restarts and OOMKills, CPU throttling, Deployment replicas desired versus available, and PVC usage with bind state.

![Kubernetes cluster workloads and storage](./08_kubernetes_cluster_workloads_storage.png)

## 🟣 09 — HighErrorRate Firing

Controlled backend failures drive HighErrorRate into the firing state with the affected service, severity, and runbook visible.

![HighErrorRate alert firing](./09_high_error_rate_firing.png)

## 🟣 10 — Application Overview During Fault

Application Overview shows the backend 5xx error rate rising to about 20% and availability falling below the 99% SLO.

![Application Overview during fault](./10_application_overview_fault.png)

## 🟣 11 — HighErrorRate Resolved

After recovery, all TaskFlow alert rules are inactive and monitoring has returned to a healthy state.

![TaskFlow alert rules inactive](./11_high_error_rate_resolved.png)

## 🟣 12 — SNS Alert Notification

Alertmanager successfully delivers the controlled alert notification through Amazon SNS to email.

![SNS alert notification email](./12_sns_alert_notification.jpg)

## 🟣 13 — Jenkins Delivery Overview

The Jenkins and Delivery dashboard shows Jenkins controller health, live queue activity, successful CI and CD results, deployed release information, and stage durations for the latest pipeline run.

![Jenkins delivery overview](./13_jenkins_delivery_overview.png)

## 🟣 14 — Jenkins Delivery Performance

The same dashboard covers build duration and queue wait for the latest build, dynamic executor and agent activity, and controller JVM heap and CPU usage.

![Jenkins delivery performance](./14_jenkins_delivery_performance.png)

## 🟣 15 — Jenkins Delivery Activity

Build rate and non-successful builds are shown together with Jenkins queue behavior during pipeline execution.

![Jenkins delivery activity](./15_jenkins_delivery_activity.png)
