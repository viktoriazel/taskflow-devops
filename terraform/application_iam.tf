# -----------------------------------------------------------------------------
# Application IAM - Backend/Worker EKS Pod Identity foundation
#
# Provisions only the AWS-side IAM identity for the Backend and Worker
# application workloads (Phase 9). Permissions live on dedicated Pod Identity
# roles tied to each service's own ServiceAccount - not on the shared Node
# IAM role - matching the pattern already used for the VPC CNI and AWS Load
# Balancer Controller roles above.
#
# The devops-app Namespace and the taskflow-backend/taskflow-worker
# ServiceAccounts referenced below do not exist yet - they are created later
# by the application Kubernetes manifests. A Pod Identity association can
# reference a namespace/ServiceAccount that doesn't exist yet; it simply has
# nothing to hand out credentials to until the manifests create them.
# -----------------------------------------------------------------------------

locals {
  app_namespace           = "devops-app"
  backend_service_account = "taskflow-backend"
  worker_service_account  = "taskflow-worker"
}

# -----------------------------------------------------------------------------
# Backend - S3 uploads (PutObject / GetObject / AbortMultipartUpload only)
# -----------------------------------------------------------------------------

data "aws_iam_policy_document" "backend_pod_identity_trust" {
  statement {
    actions = ["sts:AssumeRole", "sts:TagSession"]

    principals {
      type        = "Service"
      identifiers = ["pods.eks.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:RequestTag/kubernetes-namespace"
      values   = [local.app_namespace]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:RequestTag/kubernetes-service-account"
      values   = [local.backend_service_account]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:RequestTag/eks-cluster-arn"
      values   = [module.eks.cluster_arn]
    }
  }
}

resource "aws_iam_role" "backend_pod_identity" {
  name               = "${local.cluster_name}-backend-pod-identity"
  assume_role_policy = data.aws_iam_policy_document.backend_pod_identity_trust.json

  tags = merge(local.common_tags, {
    Name = "${local.cluster_name}-backend-pod-identity"
  })
}

# Backend only ever calls S3 through boto3's upload_fileobj (PutObject, and -
# above the s3transfer default 8 MiB multipart threshold, up to the app's own
# 30 MB upload cap - CreateMultipartUpload/UploadPart/CompleteMultipartUpload,
# all mapped to the s3:PutObject action) and generate_presigned_url("get_object")
# (GetObject, evaluated against this role when the browser follows the signed
# URL). AbortMultipartUpload is what s3transfer calls itself to clean up a
# failed multipart transfer - not requested "just in case". No list/head/delete
# call exists in the Backend code, so no bucket-level action (s3:ListBucket,
# s3:ListBucketMultipartUploads) is granted.
data "aws_iam_policy_document" "backend_s3_access" {
  statement {
    actions = [
      "s3:PutObject",
      "s3:GetObject",
      "s3:AbortMultipartUpload",
    ]

    resources = ["${aws_s3_bucket.uploads.arn}/uploads/*"]
  }
}

resource "aws_iam_policy" "backend_s3_access" {
  name        = "${local.cluster_name}-backend-s3-access"
  description = "Least-privilege S3 access for the Backend service: PutObject/GetObject/AbortMultipartUpload on uploads/* only."

  policy = data.aws_iam_policy_document.backend_s3_access.json

  tags = merge(local.common_tags, {
    Name = "${local.cluster_name}-backend-s3-access"
  })
}

resource "aws_iam_role_policy_attachment" "backend_s3_access" {
  role       = aws_iam_role.backend_pod_identity.name
  policy_arn = aws_iam_policy.backend_s3_access.arn
}

resource "aws_eks_pod_identity_association" "backend" {
  cluster_name    = module.eks.cluster_name
  namespace       = local.app_namespace
  service_account = local.backend_service_account
  role_arn        = aws_iam_role.backend_pod_identity.arn

  tags = local.common_tags
}

# -----------------------------------------------------------------------------
# Worker - SNS publish only
# -----------------------------------------------------------------------------

data "aws_iam_policy_document" "worker_pod_identity_trust" {
  statement {
    actions = ["sts:AssumeRole", "sts:TagSession"]

    principals {
      type        = "Service"
      identifiers = ["pods.eks.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:RequestTag/kubernetes-namespace"
      values   = [local.app_namespace]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:RequestTag/kubernetes-service-account"
      values   = [local.worker_service_account]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:RequestTag/eks-cluster-arn"
      values   = [module.eks.cluster_arn]
    }
  }
}

resource "aws_iam_role" "worker_pod_identity" {
  name               = "${local.cluster_name}-worker-pod-identity"
  assume_role_policy = data.aws_iam_policy_document.worker_pod_identity_trust.json

  tags = merge(local.common_tags, {
    Name = "${local.cluster_name}-worker-pod-identity"
  })
}

# Worker's only AWS call is sns_client.publish(TopicArn=SNS_TOPIC_ARN, ...) -
# no create_topic/subscribe/list_topics anywhere in the code, so sns:Publish
# on the exact topic ARN is the entire permission set.
data "aws_iam_policy_document" "worker_sns_publish" {
  statement {
    actions   = ["sns:Publish"]
    resources = [aws_sns_topic.main.arn]
  }
}

resource "aws_iam_policy" "worker_sns_publish" {
  name        = "${local.cluster_name}-worker-sns-publish"
  description = "Least-privilege SNS access for the Worker service: Publish on the TaskFlow notifications topic only."

  policy = data.aws_iam_policy_document.worker_sns_publish.json

  tags = merge(local.common_tags, {
    Name = "${local.cluster_name}-worker-sns-publish"
  })
}

resource "aws_iam_role_policy_attachment" "worker_sns_publish" {
  role       = aws_iam_role.worker_pod_identity.name
  policy_arn = aws_iam_policy.worker_sns_publish.arn
}

resource "aws_eks_pod_identity_association" "worker" {
  cluster_name    = module.eks.cluster_name
  namespace       = local.app_namespace
  service_account = local.worker_service_account
  role_arn        = aws_iam_role.worker_pod_identity.arn

  tags = local.common_tags
}
