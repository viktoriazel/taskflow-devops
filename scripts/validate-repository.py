#!/usr/bin/env python3
"""Structural validation of the TaskFlow repository, used by the CI pipeline.

Answers one question before anything is built: does this commit still contain
the files the pipeline is about to act on, and do they hold the shape the rest
of the pipeline assumes?

Deliberately limited to structure and references. Rendering the manifests with
Kustomize and dry-running them against a cluster belongs to the deployment
pipeline, which is the side that owns the Kubernetes tooling and the API
credential; the CI agent has neither.

Run it directly from anywhere:

    python3 scripts/validate-repository.py

Exit status is 0 when every check passes and 1 when any of them fails.
"""

import json
import sys
from pathlib import Path

import yaml

REPO_ROOT = Path(__file__).resolve().parents[1]

SERVICES = ("backend", "frontend", "worker")

# Files the pipeline reads directly. A missing one is a failure here rather than
# an unexplained error three stages later.
REQUIRED_FILES = (
    "ci-Jenkinsfile",
    "pyproject.toml",
    "requirements-dev.txt",
    ".trivyignore",
)

# Kustomization roots. Every manifest under them has to be reachable from one of
# these through a resources or patches reference; k8s/examples/ is deliberately
# outside them, because those files are placeholders and never applied.
KUSTOMIZATION_ROOTS = (
    "k8s/base",
    "k8s/overlays/release",
)

# Sentinel the Deployment manifests carry in place of a real image reference, so
# an unrendered manifest cannot be applied by accident.
IMAGE_PLACEHOLDER_TAG = "IMAGE-NOT-SET"

KUSTOMIZATION_KIND = "Kustomization"

# Monitoring configuration. Checked for shape only: whether the objects are
# accepted by the cluster is decided by the API server, and whether the queries
# return anything is decided by Prometheus. Neither is reachable from here.
MONITORING_DIRS = (
    "observability/manifests",
    "observability/rules",
)

DASHBOARD_DIR = "observability/dashboards"

MONITORING_API_GROUP = "monitoring.coreos.com/"

SCRAPE_KINDS = {
    "ServiceMonitor": "endpoints",
    "PodMonitor": "podMetricsEndpoints",
}

RULE_KIND = "PrometheusRule"

# Every alert has to carry enough for whoever is paged to act on it: how urgent
# it is, what happened, and where the procedure is written down.
ALERT_LABELS = ("severity",)
ALERT_ANNOTATIONS = ("summary", "description", "runbook")


class Report:
    """Collects check results and prints them as one aligned list."""

    def __init__(self):
        self.failures = 0
        self.checks = 0

    def record(self, ok, description, detail=""):
        self.checks += 1
        if not ok:
            self.failures += 1
        suffix = f" - {detail}" if detail else ""
        print(f"  [{'PASS' if ok else 'FAIL'}] {description}{suffix}")
        return ok

    def section(self, title):
        print(f"\n{title}")


def load_yaml_documents(path):
    """Return every YAML document in a file, or raise yaml.YAMLError."""
    with path.open(encoding="utf-8") as handle:
        return [document for document in yaml.safe_load_all(handle) if document is not None]


def check_repository_layout(report):
    report.section("Repository layout")

    for name in REQUIRED_FILES:
        path = REPO_ROOT / name
        report.record(path.is_file(), f"{name} is present")

    for service in SERVICES:
        service_dir = REPO_ROOT / service
        if not report.record(service_dir.is_dir(), f"{service}/ is present"):
            continue

        report.record((service_dir / "requirements.txt").is_file(),
                      f"{service}/requirements.txt is present")
        report.record((service_dir / ".dockerignore").is_file(),
                      f"{service}/.dockerignore is present")

        tests_dir = service_dir / "tests"
        if report.record(tests_dir.is_dir(), f"{service}/tests/ is present"):
            collected = sorted(tests_dir.glob("test_*.py"))
            report.record(bool(collected),
                          f"{service}/tests/ contains at least one test module",
                          f"{len(collected)} found")


def check_dockerfiles(report):
    report.section("Dockerfiles")

    for service in SERVICES:
        path = REPO_ROOT / service / "Dockerfile"
        if not report.record(path.is_file(), f"{service}/Dockerfile is present"):
            continue

        from_lines = [
            line.strip()
            for line in path.read_text(encoding="utf-8").splitlines()
            if line.strip().upper().startswith("FROM ")
        ]

        if not report.record(bool(from_lines), f"{service}/Dockerfile declares a base image"):
            continue

        # A digest cannot be repointed after the fact, so the base image stays a
        # fixed input instead of whatever the tag happens to resolve to today.
        # That fixes one input of a reproducible build, not all of them.
        unpinned = [line for line in from_lines if "@sha256:" not in line]
        report.record(not unpinned,
                      f"{service}/Dockerfile pins every base image by digest",
                      "; ".join(unpinned))

        floating = [line for line in from_lines if ":latest" in line]
        report.record(not floating,
                      f"{service}/Dockerfile does not reference latest",
                      "; ".join(floating))


def collect_referenced_manifests(report, kustomization_dirs):
    """Resolve the Kustomization graph and return every manifest file it reaches.

    Follows resources entries into nested Kustomization directories, so a broken
    reference anywhere in the chain is reported against the file that made it.
    The release overlay reuses the base Deployment directory, so directories are
    visited once no matter how many overlays point at them.
    """
    manifests = set()
    pending = [directory.resolve() for directory in kustomization_dirs]
    visited = set()

    while pending:
        current = pending.pop()
        if current in visited:
            continue
        visited.add(current)

        kustomization = current / "kustomization.yaml"
        relative = kustomization.relative_to(REPO_ROOT)

        if not report.record(kustomization.is_file(), f"{relative} is present"):
            continue

        try:
            documents = load_yaml_documents(kustomization)
        except yaml.YAMLError as error:
            report.record(False, f"{relative} parses as YAML", str(error).replace("\n", " "))
            continue

        report.record(True, f"{relative} parses as YAML")

        # Nothing below reads the document until its shape has been confirmed:
        # valid YAML is not necessarily a Kustomization, and a malformed one has
        # to come out as a recorded failure rather than as a traceback.
        document = check_kustomization_shape(report, relative, documents)
        if document is None:
            continue

        for entry in kustomization_list(report, relative, document, "resources"):
            if not report.record(isinstance(entry, str),
                                 f"{relative} resource entry is a path", repr(entry)):
                continue

            target = (current / entry).resolve()
            if target.is_dir():
                pending.append(target)
                continue
            if report.record(target.is_file(),
                             f"{relative} resource {entry} resolves"):
                manifests.add(target)

        for patch in kustomization_list(report, relative, document, "patches"):
            if not report.record(isinstance(patch, dict),
                                 f"{relative} patch entry is a mapping", repr(patch)):
                continue

            entry = patch.get("path")
            if entry is None:
                # An inline patch carries its content in this file and points at
                # no separate manifest.
                continue

            if not report.record(isinstance(entry, str),
                                 f"{relative} patch path is a string", repr(entry)):
                continue

            target = (current / entry).resolve()
            if report.record(target.is_file(), f"{relative} patch {entry} resolves"):
                manifests.add(target)

        check_image_transformers(
            report, relative, kustomization_list(report, relative, document, "images")
        )

    return manifests


def check_kustomization_shape(report, relative, documents):
    """Confirm a parsed file really is one Kustomization mapping.

    Returns the document when it is, and None when it is not, in which case the
    caller must stop reading it. A bare scalar is valid YAML and would otherwise
    only fail on the first attribute access.
    """
    if not report.record(len(documents) == 1,
                         f"{relative} holds exactly one YAML document",
                         f"{len(documents)} found"):
        return None

    document = documents[0]

    if not report.record(isinstance(document, dict),
                         f"{relative} is a YAML mapping",
                         f"parsed as {type(document).__name__}"):
        return None

    declared = report.record(bool(document.get("apiVersion")),
                             f"{relative} declares apiVersion")

    kind = document.get("kind")
    declared = report.record(kind == KUSTOMIZATION_KIND,
                             f"{relative} declares kind {KUSTOMIZATION_KIND}",
                             f"kind={kind!r}") and declared

    return document if declared else None


def kustomization_list(report, relative, document, field):
    """Return a list-valued Kustomization field, or an empty list if it is unusable.

    A field written as the wrong type is reported as a failure and then skipped,
    so one malformed entry does not stop the rest of the file being checked.
    """
    value = document.get(field)
    if value is None:
        return []

    if not report.record(isinstance(value, list), f"{relative} {field} is a list",
                         f"parsed as {type(value).__name__}"):
        return []

    return value


def check_image_transformers(report, relative, images):
    """Every image transformer has to name a reference that is not a floating tag.

    A digest identifies content. An explicit tag does not, on its own, prove the
    registry will keep it pointing at the same image; it is checked here only for
    being explicit and not being latest.
    """
    for image in images:
        if not report.record(isinstance(image, dict),
                             f"{relative} image transformer is a mapping", repr(image)):
            continue

        name = image.get("name", "<unnamed>")
        if image.get("digest"):
            report.record(True, f"{relative} image {name} is pinned by digest")
            continue

        new_tag = image.get("newTag")
        report.record(isinstance(new_tag, str) and new_tag not in ("", "latest"),
                      f"{relative} image {name} uses an explicit non-latest tag",
                      f"newTag={new_tag!r}")


def check_every_manifest_is_referenced(report, manifests):
    """No manifest may sit under a Kustomization root without being referenced.

    A file added to the directory but forgotten in kustomization.yaml is silently
    ignored by Kustomize, so it would never reach the cluster and nothing would
    say so.
    """
    for root in KUSTOMIZATION_ROOTS:
        for path in sorted((REPO_ROOT / root).rglob("*.yaml")):
            if path.name == "kustomization.yaml":
                continue

            report.record(path.resolve() in manifests,
                          f"{path.relative_to(REPO_ROOT)} is referenced by a Kustomization")


def check_manifests(report, manifests):
    report.section("Kubernetes manifests")

    for path in sorted(manifests):
        relative = path.relative_to(REPO_ROOT)

        try:
            documents = load_yaml_documents(path)
        except yaml.YAMLError as error:
            report.record(False, f"{relative} parses as YAML", str(error).replace("\n", " "))
            continue

        if not report.record(bool(documents), f"{relative} contains at least one document"):
            continue

        incomplete = [
            index
            for index, document in enumerate(documents)
            if not (isinstance(document, dict) and document.get("apiVersion") and
                    document.get("kind"))
        ]
        report.record(not incomplete,
                      f"{relative} declares apiVersion and kind in every document",
                      f"documents {incomplete}" if incomplete else "")

        floating = sorted(
            reference
            for reference in collect_image_references(documents)
            if is_floating_reference(reference)
        )
        report.record(not floating,
                      f"{relative} uses no floating image reference",
                      "; ".join(floating))


def is_floating_reference(reference):
    """True when an image reference could resolve to different content over time.

    A raw Deployment manifest may carry the IMAGE-NOT-SET sentinel instead of a
    real reference, which the Kustomization image transformer is expected to
    replace with an explicitly given, acceptable reference. What counts as
    acceptable is decided by check_image_transformers, which takes either a
    digest or an explicit non-latest tag. Requiring an exact digest for a
    deployment or a release is the job of the deployment-side validation, not of
    this function.
    """
    if "@sha256:" in reference:
        return False

    last_segment = reference.rsplit("/", 1)[-1]
    if ":" not in last_segment:
        return True

    tag = last_segment.rsplit(":", 1)[-1]
    return tag != IMAGE_PLACEHOLDER_TAG


def collect_image_references(documents):
    """Return every value of an `image` key found anywhere in the documents."""
    references = set()

    def walk(node):
        if isinstance(node, dict):
            for key, value in node.items():
                if key == "image" and isinstance(value, str):
                    references.add(value)
                else:
                    walk(value)
        elif isinstance(node, list):
            for item in node:
                walk(item)

    for document in documents:
        walk(document)

    return references


def mapping_field(report, subject, document, field):
    """Return a mapping-valued field, or an empty mapping once the failure is recorded."""
    value = document.get(field)

    if not report.record(isinstance(value, dict), f"{subject} {field} is a mapping",
                         f"parsed as {type(value).__name__}"):
        return {}

    return value


def check_monitoring_manifests(report):
    """Check the shape of the scrape targets and alert rules the stack is built on.

    Shape only. Whether the API server accepts an object and whether Prometheus
    can evaluate an expression are runtime questions, and neither the cluster nor
    Prometheus is reachable from here.
    """
    report.section("Monitoring configuration")

    scrape_targets = 0
    alert_rules = 0

    for directory in MONITORING_DIRS:
        root = REPO_ROOT / directory
        if not report.record(root.is_dir(), f"{directory}/ is present"):
            continue

        for path in sorted(root.rglob("*.yaml")):
            relative = path.relative_to(REPO_ROOT)

            try:
                documents = load_yaml_documents(path)
            except yaml.YAMLError as error:
                report.record(False, f"{relative} parses as YAML", str(error).replace("\n", " "))
                continue

            report.record(True, f"{relative} parses as YAML")

            for index, document in enumerate(documents):
                if not report.record(isinstance(document, dict),
                                     f"{relative} document {index} is a YAML mapping",
                                     f"parsed as {type(document).__name__}"):
                    continue

                kind = document.get("kind")

                if kind in SCRAPE_KINDS:
                    scrape_targets += 1
                    check_scrape_target(report, relative, document)
                elif kind == RULE_KIND:
                    alert_rules += check_prometheus_rule(report, relative, document)

    report.record(scrape_targets > 0, "a scrape target is defined",
                  f"{scrape_targets} found")
    report.record(alert_rules > 0, "an alert rule is defined", f"{alert_rules} found")


def check_scrape_target(report, relative, document):
    """A ServiceMonitor or PodMonitor that selects nothing, or names no port, is
    discovered by the operator and then scrapes nothing at all.
    """
    kind = document["kind"]
    endpoints_field = SCRAPE_KINDS[kind]

    api_version = document.get("apiVersion", "")
    report.record(isinstance(api_version, str) and api_version.startswith(MONITORING_API_GROUP),
                  f"{relative} {kind} declares a {MONITORING_API_GROUP}* apiVersion",
                  f"apiVersion={api_version!r}")

    metadata = mapping_field(report, f"{relative} {kind}", document, "metadata")
    name = metadata.get("name")
    report.record(isinstance(name, str) and bool(name),
                  f"{relative} {kind} declares metadata.name", f"name={name!r}")

    subject = f"{relative} {kind} {name or '<unnamed>'}"

    spec = mapping_field(report, subject, document, "spec")
    if not spec:
        return

    selector = spec.get("selector")
    report.record(isinstance(selector, dict) and
                  bool(selector.get("matchLabels") or selector.get("matchExpressions")),
                  f"{subject} selects its targets by label")

    endpoints = spec.get(endpoints_field)
    if not report.record(isinstance(endpoints, list) and bool(endpoints),
                         f"{subject} declares at least one {endpoints_field} entry"):
        return

    for index, endpoint in enumerate(endpoints):
        if not report.record(isinstance(endpoint, dict),
                             f"{subject} {endpoints_field}[{index}] is a mapping",
                             f"parsed as {type(endpoint).__name__}"):
            continue

        report.record(bool(endpoint.get("port") or endpoint.get("targetPort")),
                      f"{subject} {endpoints_field}[{index}] names a port")


def check_prometheus_rule(report, relative, document):
    """Check one PrometheusRule and return the number of alert rules it declares."""
    api_version = document.get("apiVersion", "")
    report.record(isinstance(api_version, str) and api_version.startswith(MONITORING_API_GROUP),
                  f"{relative} {RULE_KIND} declares a {MONITORING_API_GROUP}* apiVersion",
                  f"apiVersion={api_version!r}")

    metadata = mapping_field(report, f"{relative} {RULE_KIND}", document, "metadata")
    name = metadata.get("name")
    report.record(isinstance(name, str) and bool(name),
                  f"{relative} {RULE_KIND} declares metadata.name", f"name={name!r}")

    spec = mapping_field(report, f"{relative} {RULE_KIND}", document, "spec")
    groups = spec.get("groups")

    if not report.record(isinstance(groups, list) and bool(groups),
                         f"{relative} declares at least one rule group"):
        return 0

    alerts = 0

    for index, group in enumerate(groups):
        if not report.record(isinstance(group, dict), f"{relative} group {index} is a mapping",
                             f"parsed as {type(group).__name__}"):
            continue

        group_name = group.get("name")
        report.record(bool(group_name), f"{relative} group {index} declares a name")

        rules = group.get("rules")
        if not report.record(isinstance(rules, list) and bool(rules),
                             f"{relative} group {group_name!r} declares at least one rule"):
            continue

        for rule in rules:
            if not report.record(isinstance(rule, dict),
                                 f"{relative} group {group_name!r} rule is a mapping",
                                 f"parsed as {type(rule).__name__}"):
                continue

            alert = rule.get("alert")
            if not alert:
                # A recording rule carries none of the metadata checked below.
                continue

            alerts += 1
            check_alert_rule(report, relative, alert, rule)

    return alerts


def check_alert_rule(report, relative, alert, rule):
    """Whoever is paged needs the urgency, what happened, and where the procedure is."""
    subject = f"{relative} alert {alert}"

    report.record(bool(rule.get("expr")), f"{subject} declares an expression")

    labels = rule.get("labels")
    labels = labels if isinstance(labels, dict) else {}
    for key in ALERT_LABELS:
        report.record(bool(labels.get(key)), f"{subject} carries the {key} label")

    annotations = rule.get("annotations")
    annotations = annotations if isinstance(annotations, dict) else {}
    for key in ALERT_ANNOTATIONS:
        report.record(bool(annotations.get(key)), f"{subject} carries the {key} annotation")

    # The reference is a repository-relative path, so it can be resolved here. A
    # runbook that names a procedure nobody can open is the same as no runbook.
    runbook = annotations.get("runbook")
    if isinstance(runbook, str) and runbook:
        target = (REPO_ROOT / runbook).resolve()
        report.record(target.is_file() and target.is_relative_to(REPO_ROOT),
                      f"{subject} points at a runbook in the repository", runbook)


def check_dashboards(report):
    report.section("Grafana dashboards")

    root = REPO_ROOT / DASHBOARD_DIR
    if not report.record(root.is_dir(), f"{DASHBOARD_DIR}/ is present"):
        return

    dashboards = sorted(root.glob("*.json"))
    if not report.record(bool(dashboards), f"{DASHBOARD_DIR}/ holds at least one dashboard",
                         f"{len(dashboards)} found"):
        return

    for path in dashboards:
        relative = path.relative_to(REPO_ROOT)

        try:
            dashboard = json.loads(path.read_text(encoding="utf-8"))
        except json.JSONDecodeError as error:
            report.record(False, f"{relative} parses as JSON", str(error))
            continue

        report.record(True, f"{relative} parses as JSON")

        if not report.record(isinstance(dashboard, dict), f"{relative} is a JSON object",
                             f"parsed as {type(dashboard).__name__}"):
            continue

        report.record(bool(dashboard.get("title")), f"{relative} declares a title")

        # The uid is what the dashboard is addressed by, so an import that
        # replaces it in place depends on it staying the same.
        report.record(bool(dashboard.get("uid")), f"{relative} declares a uid")

        panels = dashboard.get("panels")
        if not report.record(isinstance(panels, list) and bool(panels),
                             f"{relative} declares at least one panel"):
            continue

        untyped = [
            index
            for index, panel in enumerate(panels)
            if not (isinstance(panel, dict) and panel.get("type"))
        ]
        report.record(not untyped, f"{relative} declares a type on every panel",
                      f"panels {untyped}" if untyped else "")

    check_dashboards_are_loaded(report, dashboards)


def check_dashboards_are_loaded(report, dashboards):
    """A dashboard the generated ConfigMap does not list never reaches Grafana.

    The sidecar loads the dashboards out of that ConfigMap, so a file added to
    the directory but forgotten in the generator is tracked and never displayed,
    exactly as a manifest missing from a Kustomization is never applied.
    """
    kustomization = REPO_ROOT / DASHBOARD_DIR / "kustomization.yaml"
    relative = kustomization.relative_to(REPO_ROOT)

    if not report.record(kustomization.is_file(), f"{relative} is present"):
        return

    try:
        documents = load_yaml_documents(kustomization)
    except yaml.YAMLError as error:
        report.record(False, f"{relative} parses as YAML", str(error).replace("\n", " "))
        return

    report.record(True, f"{relative} parses as YAML")

    document = check_kustomization_shape(report, relative, documents)
    if document is None:
        return

    listed = set()
    for generator in kustomization_list(report, relative, document, "configMapGenerator"):
        if not report.record(isinstance(generator, dict),
                             f"{relative} configMapGenerator entry is a mapping",
                             f"parsed as {type(generator).__name__}"):
            continue

        for entry in generator.get("files") or []:
            if isinstance(entry, str):
                # A files entry is either a path or key=path.
                listed.add(entry.rsplit("=", 1)[-1])

    for path in dashboards:
        report.record(path.name in listed, f"{path.relative_to(REPO_ROOT)} is loaded by {relative}")


def check_pinned_dev_requirements(report):
    report.section("Pinned tooling")

    path = REPO_ROOT / "requirements-dev.txt"
    if not path.is_file():
        report.record(False, "requirements-dev.txt is readable")
        return

    requirements = [
        line.strip()
        for line in path.read_text(encoding="utf-8").splitlines()
        if line.strip() and not line.strip().startswith("#")
    ]

    report.record(bool(requirements), "requirements-dev.txt lists at least one tool")

    # An unpinned entry would let two runs of the same commit install different
    # linters and disagree about whether the commit is clean.
    unpinned = [entry for entry in requirements if "==" not in entry]
    report.record(not unpinned,
                  "requirements-dev.txt pins every tool to an exact version",
                  "; ".join(unpinned))


def main():
    print(f"Validating repository at {REPO_ROOT}")

    report = Report()
    check_repository_layout(report)
    check_dockerfiles(report)
    check_pinned_dev_requirements(report)

    report.section("Kustomize configuration")
    manifests = collect_referenced_manifests(
        report, [REPO_ROOT / root for root in KUSTOMIZATION_ROOTS]
    )

    check_every_manifest_is_referenced(report, manifests)
    check_manifests(report, manifests)

    check_monitoring_manifests(report)
    check_dashboards(report)

    print(f"\n{report.checks - report.failures}/{report.checks} checks passed")

    if report.failures:
        print(f"Validation failed: {report.failures} check(s) did not pass")
        return 1

    print("Validation passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
