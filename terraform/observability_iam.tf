locals {
  observability_namespace      = "observability"
  alertmanager_service_account = "alertmanager"
}

# Bound to the Alertmanager ServiceAccount through EKS Pod Identity.
data "aws_iam_policy_document" "alertmanager_pod_identity_trust" {
  statement {
    actions = ["sts:AssumeRole", "sts:TagSession"]

    principals {
      type        = "Service"
      identifiers = ["pods.eks.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:RequestTag/kubernetes-namespace"
      values   = [local.observability_namespace]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:RequestTag/kubernetes-service-account"
      values   = [local.alertmanager_service_account]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:RequestTag/eks-cluster-arn"
      values   = [module.eks.cluster_arn]
    }
  }
}

resource "aws_iam_role" "alertmanager_pod_identity" {
  name               = "${local.cluster_name}-alertmanager-pod-identity"
  assume_role_policy = data.aws_iam_policy_document.alertmanager_pod_identity_trust.json

  tags = merge(local.common_tags, {
    Name = "${local.cluster_name}-alertmanager-pod-identity"
  })
}

# Least privilege: sns:Publish on the alerts topic only.
data "aws_iam_policy_document" "alertmanager_sns_publish" {
  statement {
    actions   = ["sns:Publish"]
    resources = [aws_sns_topic.alerts.arn]
  }
}

resource "aws_iam_policy" "alertmanager_sns_publish" {
  name        = "${local.cluster_name}-alertmanager-sns-publish"
  description = "Least-privilege SNS access for Alertmanager: Publish on the TaskFlow alerts topic only."

  policy = data.aws_iam_policy_document.alertmanager_sns_publish.json

  tags = merge(local.common_tags, {
    Name = "${local.cluster_name}-alertmanager-sns-publish"
  })
}

resource "aws_iam_role_policy_attachment" "alertmanager_sns_publish" {
  role       = aws_iam_role.alertmanager_pod_identity.name
  policy_arn = aws_iam_policy.alertmanager_sns_publish.arn
}

resource "aws_eks_pod_identity_association" "alertmanager" {
  cluster_name    = module.eks.cluster_name
  namespace       = local.observability_namespace
  service_account = local.alertmanager_service_account
  role_arn        = aws_iam_role.alertmanager_pod_identity.arn

  tags = local.common_tags
}
