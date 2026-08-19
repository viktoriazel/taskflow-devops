# -----------------------------------------------------------------------------
# Jenkins CI/CD - AWS identities via EKS Pod Identity
#
# AWS-side identity only. The jenkins Namespace and the jenkins-ci-agent
# ServiceAccount referenced below do not exist yet - they arrive with the
# Jenkins installation. A Pod Identity association can reference a
# namespace/ServiceAccount that does not exist yet; it simply has nothing to
# hand credentials out to until the manifests create them. Same pattern as the
# application identities in application_iam.tf.
#
# No static AWS credentials exist anywhere in this design: the agent Pod
# receives short-lived credentials from the EKS Pod Identity Agent at runtime,
# so nothing has to be stored in Jenkins, in Git, or in a Jenkinsfile.
#
# Kubernetes permissions are deliberately absent here. The CI pipeline builds
# and pushes images and never deploys, so it gets no Role, no RoleBinding, and
# no kubeconfig - only the AWS access the push itself requires.
# -----------------------------------------------------------------------------

locals {
  jenkins_namespace        = "jenkins"
  ci_agent_service_account = "jenkins-ci-agent"
  cd_agent_service_account = "jenkins-cd-agent"
}

# -----------------------------------------------------------------------------
# CI agent - trust
#
# Scoped by the session tags EKS Pod Identity sets automatically, exactly as
# the Load Balancer Controller and application roles are: without them, any
# future Pod Identity association in this account could assume this role.
# Referencing module.eks.cluster_arn is safe here - unlike the EBS CSI role,
# this role's ARN is never passed into the EKS module, so there is no
# dependency cycle to avoid.
# -----------------------------------------------------------------------------

data "aws_iam_policy_document" "jenkins_ci_agent_trust" {
  statement {
    actions = ["sts:AssumeRole", "sts:TagSession"]

    principals {
      type        = "Service"
      identifiers = ["pods.eks.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:RequestTag/kubernetes-namespace"
      values   = [local.jenkins_namespace]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:RequestTag/kubernetes-service-account"
      values   = [local.ci_agent_service_account]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:RequestTag/eks-cluster-arn"
      values   = [module.eks.cluster_arn]
    }
  }
}

resource "aws_iam_role" "jenkins_ci_agent" {
  name               = "${local.cluster_name}-jenkins-ci-agent"
  assume_role_policy = data.aws_iam_policy_document.jenkins_ci_agent_trust.json

  tags = merge(local.common_tags, {
    Name = "${local.cluster_name}-jenkins-ci-agent"
  })
}

# -----------------------------------------------------------------------------
# CI agent - ECR permissions
#
# The pipeline builds images with rootless BuildKit from public base images,
# scans the resulting artifact locally, pushes exactly that artifact, and then
# reads back the digest to prove the pushed image is the one that was built.
# Only the push and that read-back need AWS.
#
# ecr:GetAuthorizationToken is the one action that cannot be scoped to a
# repository - it is a registry-level operation and Amazon ECR defines no
# repository resource type for it, so "*" is required rather than chosen. The
# token it returns opens nothing on its own: every subsequent registry call is
# authorized again against the statement below, which names only the three
# TaskFlow repositories.
#
# The repository-scoped statement holds three distinct groups, not one
# undifferentiated "push" set:
#
#   - Five upload actions - BatchCheckLayerAvailability, InitiateLayerUpload,
#     UploadLayerPart, CompleteLayerUpload, PutImage - AWS's documented set for
#     pushing an image to a private repository.
#   - ecr:BatchGetImage - a manifest metadata read, not an upload action. ECR
#     maps a HEAD/GET of the destination manifest onto it, which registry
#     clients (skopeo, crane, buildx) may issue while pushing. On its own it
#     grants no layer pull: that needs ecr:GetDownloadUrlForLayer, which is
#     absent below.
#   - ecr:DescribeImages - the tag guard before the build (the run's tag must
#     not already exist) and the digest read-back after the push.
#
# Deliberately excluded: ecr:GetDownloadUrlForLayer (nothing is pulled from
# ECR - every Dockerfile starts from a public base image), every delete action
# (BatchDeleteImage, DeleteRepository), repository management (CreateRepository,
# SetRepositoryPolicy, PutImageTagMutability), lifecycle policy actions, and
# scan-result actions (scanning happens with Trivy before the push). No S3,
# SNS, or RDS access - the CI agent has no business touching application data.
# -----------------------------------------------------------------------------

data "aws_iam_policy_document" "jenkins_ci_agent_ecr" {
  statement {
    sid       = "EcrAuthorizationToken"
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"]
  }

  statement {
    sid = "PushAndVerifyTaskFlowImages"

    actions = [
      "ecr:BatchCheckLayerAvailability",
      "ecr:InitiateLayerUpload",
      "ecr:UploadLayerPart",
      "ecr:CompleteLayerUpload",
      "ecr:PutImage",
      "ecr:BatchGetImage",
      "ecr:DescribeImages",
    ]

    resources = [
      aws_ecr_repository.backend.arn,
      aws_ecr_repository.frontend.arn,
      aws_ecr_repository.worker.arn,
    ]
  }
}

resource "aws_iam_policy" "jenkins_ci_agent_ecr" {
  name        = "${local.cluster_name}-jenkins-ci-agent-ecr"
  description = "Least-privilege ECR access for the Jenkins CI agent: push and digest verification on the three TaskFlow repositories only."

  policy = data.aws_iam_policy_document.jenkins_ci_agent_ecr.json

  tags = merge(local.common_tags, {
    Name = "${local.cluster_name}-jenkins-ci-agent-ecr"
  })
}

resource "aws_iam_role_policy_attachment" "jenkins_ci_agent_ecr" {
  role       = aws_iam_role.jenkins_ci_agent.name
  policy_arn = aws_iam_policy.jenkins_ci_agent_ecr.arn
}

resource "aws_eks_pod_identity_association" "jenkins_ci_agent" {
  cluster_name    = module.eks.cluster_name
  namespace       = local.jenkins_namespace
  service_account = local.ci_agent_service_account
  role_arn        = aws_iam_role.jenkins_ci_agent.arn

  tags = local.common_tags
}

# -----------------------------------------------------------------------------
# CD agent - trust
#
# Same three conditions as the CI agent, differing only in the ServiceAccount.
# That difference is what actually separates the two pipelines on the AWS side:
# the CD agent cannot assume the CI role and gain push permissions, even though
# both run in the same Namespace and land on the same node.
# -----------------------------------------------------------------------------

data "aws_iam_policy_document" "jenkins_cd_agent_trust" {
  statement {
    actions = ["sts:AssumeRole", "sts:TagSession"]

    principals {
      type        = "Service"
      identifiers = ["pods.eks.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:RequestTag/kubernetes-namespace"
      values   = [local.jenkins_namespace]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:RequestTag/kubernetes-service-account"
      values   = [local.cd_agent_service_account]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:RequestTag/eks-cluster-arn"
      values   = [module.eks.cluster_arn]
    }
  }
}

resource "aws_iam_role" "jenkins_cd_agent" {
  name               = "${local.cluster_name}-jenkins-cd-agent"
  assume_role_policy = data.aws_iam_policy_document.jenkins_cd_agent_trust.json

  tags = merge(local.common_tags, {
    Name = "${local.cluster_name}-jenkins-cd-agent"
  })
}

# -----------------------------------------------------------------------------
# CD agent - ECR permissions
#
# The CD pipeline touches AWS exactly once per run: to confirm that the image
# CI produced really exists in the registry before anything is deployed. One
# action covers it. ecr:DescribeImages accepts either an image digest or a tag
# and returns the digest, the tags, and the manifest media type, which is
# everything the Input Validation stage checks; a missing image comes back as
# ImageNotFoundException, which is the check itself.
#
# No ecr:GetAuthorizationToken. An authorization token authenticates the Docker
# Registry HTTP API, which exists because the Docker CLI cannot use IAM
# credentials natively. AWS API calls such as DescribeImages are signed with
# the caller's IAM credentials directly, so the token buys nothing here. This
# is why the validation step must use `aws ecr describe-images` rather than a
# registry client like skopeo or crane - those speak the registry protocol and
# would drag GetAuthorizationToken, and with it a "*" resource, into this
# policy.
#
# Nothing else is granted: no push or upload actions (CD never builds or
# pushes), no pull actions (the kubelet pulls application images under the node
# IAM role, not under this identity), no delete, lifecycle, or repository
# management, no scan results, and no S3, SNS, or RDS access. No eks:* either -
# the agent authenticates to the cluster with its in-cluster ServiceAccount
# token, so it never calls the EKS API. The result is a policy with no broad
# permission at all.
#
# Deploy permissions live in Kubernetes RBAC, namespace-scoped, added with the
# Jenkins installation - deliberately not here.
# -----------------------------------------------------------------------------

data "aws_iam_policy_document" "jenkins_cd_agent_ecr" {
  statement {
    sid     = "VerifyTaskFlowImagesExist"
    actions = ["ecr:DescribeImages"]

    resources = [
      aws_ecr_repository.backend.arn,
      aws_ecr_repository.frontend.arn,
      aws_ecr_repository.worker.arn,
    ]
  }
}

resource "aws_iam_policy" "jenkins_cd_agent_ecr" {
  name        = "${local.cluster_name}-jenkins-cd-agent-ecr"
  description = "Least-privilege ECR access for the Jenkins CD agent: read-only image metadata on the three TaskFlow repositories, for release verification only."

  policy = data.aws_iam_policy_document.jenkins_cd_agent_ecr.json

  tags = merge(local.common_tags, {
    Name = "${local.cluster_name}-jenkins-cd-agent-ecr"
  })
}

resource "aws_iam_role_policy_attachment" "jenkins_cd_agent_ecr" {
  role       = aws_iam_role.jenkins_cd_agent.name
  policy_arn = aws_iam_policy.jenkins_cd_agent_ecr.arn
}

resource "aws_eks_pod_identity_association" "jenkins_cd_agent" {
  cluster_name    = module.eks.cluster_name
  namespace       = local.jenkins_namespace
  service_account = local.cd_agent_service_account
  role_arn        = aws_iam_role.jenkins_cd_agent.arn

  tags = local.common_tags
}
