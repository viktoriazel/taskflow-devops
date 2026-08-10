# -----------------------------------------------------------------------------
# AWS Load Balancer Controller - EKS Pod Identity IAM foundation
#
# This provisions only the AWS-side IAM identity for the AWS Load Balancer
# Controller (v3.5.0), installed later via Helm into kube-system. As with the
# VPC CNI role above, permissions live on a dedicated Pod Identity role tied
# to the Controller's own ServiceAccount - not on the shared Node IAM role -
# so a compromised or misconfigured node cannot implicitly gain ELB/EC2
# management permissions meant only for this one controller.
#
# No Ingress or ALB is created here. This only prepares the identity the
# Controller will use once installed.
# -----------------------------------------------------------------------------

data "aws_iam_policy_document" "lb_controller_pod_identity_trust" {
  statement {
    actions = ["sts:AssumeRole", "sts:TagSession"]

    principals {
      type        = "Service"
      identifiers = ["pods.eks.amazonaws.com"]
    }

    # Scopes this role to exactly the Controller's own namespace/ServiceAccount
    # and this specific cluster, using the session tags EKS Pod Identity sets
    # automatically on every assume-role call. Without these, the role's trust
    # relationship would allow any future Pod Identity association in this AWS
    # account (a different ServiceAccount, namespace, or even another cluster
    # reusing this role) to assume it - these conditions keep that from being
    # possible by accident.
    condition {
      test     = "StringEquals"
      variable = "aws:RequestTag/kubernetes-namespace"
      values   = ["kube-system"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:RequestTag/kubernetes-service-account"
      values   = ["aws-load-balancer-controller"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:RequestTag/eks-cluster-arn"
      values   = [module.eks.cluster_arn]
    }
  }
}

resource "aws_iam_role" "lb_controller_pod_identity" {
  name               = "${local.cluster_name}-lb-controller-pod-identity"
  assume_role_policy = data.aws_iam_policy_document.lb_controller_pod_identity_trust.json

  tags = merge(local.common_tags, {
    Name = "${local.cluster_name}-lb-controller-pod-identity"
  })
}

# Policy source: kubernetes-sigs/aws-load-balancer-controller, tag v3.5.0,
# docs/install/iam_policy.json - https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/v3.5.0/docs/install/iam_policy.json
#
# terraform/lb_controller_iam_policy.json.tpl is that official document
# unmodified, with exactly one local change: the upstream-documented VPC
# restriction (see the installation guide's "Configure IAM" section) added to
# the ec2:AuthorizeSecurityGroupIngress / ec2:RevokeSecurityGroupIngress
# statement, scoping it to this project's own VPC via ec2:Vpc ArnEquals. No
# other statement, action, or permission was added, removed, or altered.
resource "aws_iam_policy" "lb_controller" {
  name        = "${local.cluster_name}-lb-controller"
  description = "AWS Load Balancer Controller v3.5.0 permissions (official upstream policy + VPC-scoped SG ingress/revoke), for the dedicated Pod Identity role only."

  policy = templatefile("${path.module}/lb_controller_iam_policy.json.tpl", {
    vpc_arn = aws_vpc.main.arn
  })

  tags = merge(local.common_tags, {
    Name = "${local.cluster_name}-lb-controller"
  })
}

resource "aws_iam_role_policy_attachment" "lb_controller_pod_identity" {
  role       = aws_iam_role.lb_controller_pod_identity.name
  policy_arn = aws_iam_policy.lb_controller.arn
}

# The ServiceAccount this association points at is created later by Helm, not
# here - EKS Pod Identity associations can reference a namespace/ServiceAccount
# that doesn't exist yet; the association simply has nothing to hand out
# credentials to until Helm creates the ServiceAccount and schedules Pods that
# use it.
resource "aws_eks_pod_identity_association" "lb_controller" {
  cluster_name    = module.eks.cluster_name
  namespace       = "kube-system"
  service_account = "aws-load-balancer-controller"
  role_arn        = aws_iam_role.lb_controller_pod_identity.arn

  tags = local.common_tags
}
