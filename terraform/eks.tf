# -----------------------------------------------------------------------------
# Amazon VPC CNI - EKS Pod Identity IAM role
#
# The AmazonEKS_CNI_Policy is intentionally NOT attached to the shared Node
# IAM role (see the Managed Node Group below, iam_role_attach_cni_policy =
# false). Instead it lives on this dedicated role, associated only with the
# aws-node ServiceAccount via EKS Pod Identity. This keeps ENI/IP management
# permissions scoped to the CNI DaemonSet, not implicitly available to every
# Pod that happens to run on a node.
# -----------------------------------------------------------------------------

data "aws_iam_policy_document" "vpc_cni_pod_identity_trust" {
  statement {
    actions = ["sts:AssumeRole", "sts:TagSession"]

    principals {
      type        = "Service"
      identifiers = ["pods.eks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "vpc_cni_pod_identity" {
  name               = "${local.cluster_name}-vpc-cni-pod-identity"
  assume_role_policy = data.aws_iam_policy_document.vpc_cni_pod_identity_trust.json

  tags = merge(local.common_tags, {
    Name = "${local.cluster_name}-vpc-cni-pod-identity"
  })
}

resource "aws_iam_role_policy_attachment" "vpc_cni_pod_identity" {
  role       = aws_iam_role.vpc_cni_pod_identity.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy"
}

# -----------------------------------------------------------------------------
# EKS Cluster + Managed Node Group + managed add-ons
# -----------------------------------------------------------------------------

module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "21.24.2"

  name               = local.cluster_name
  kubernetes_version = var.kubernetes_version

  vpc_id     = aws_vpc.main.id
  subnet_ids = [aws_subnet.private_app_1.id, aws_subnet.private_app_2.id]

  endpoint_private_access      = true
  endpoint_public_access       = true
  endpoint_public_access_cidrs = [var.admin_access_cidr]

  # No customer-managed KMS key for Secrets envelope encryption: the module's
  # own defaults (encryption_config = {}, create_kms_key = true) would
  # otherwise create one implicitly. Kubernetes Secrets remain protected by
  # AWS's baseline at-rest encryption either way; a dedicated CMK is an
  # explicit, deliberately deferred decision for this short-lived project,
  # not a silent default.
  create_kms_key    = false
  encryption_config = null

  # No EKS control-plane logging / CloudWatch Log Group: the module defaults
  # to enabling audit/api/authenticator logging and creating a log group with
  # 90-day retention. Deliberately deferred - can be added later as an
  # explicit, scoped change if troubleshooting needs it.
  enabled_log_types           = []
  create_cloudwatch_log_group = false

  # Access-entry-only authentication (no aws-auth ConfigMap): this is a new
  # cluster with no legacy ConfigMap dependency, and API_AND_CONFIG_MAP would
  # otherwise leave two independently-driftable sources of truth for cluster
  # access. EKS Managed Node Groups authenticate through a separate,
  # mode-independent bootstrap path, so this has no effect on node join.
  authentication_mode = "API"

  enable_irsa = true

  # Operator admin access is granted explicitly below via a named EKS Access
  # Entry, not via this convenience flag - keep it disabled so the module
  # does not also create an implicit entry.
  enable_cluster_creator_admin_permissions = false

  eks_managed_node_groups = {
    default = {
      instance_types = ["t3.small"]
      capacity_type  = "ON_DEMAND"
      ami_type       = "AL2023_x86_64_STANDARD"

      min_size     = 2
      desired_size = 3
      max_size     = 3

      # AmazonEKS_CNI_Policy is granted via the dedicated Pod Identity role
      # above, not to the shared node role.
      iam_role_attach_cni_policy = false

      update_config = {
        max_unavailable = 1
      }

      # IMDSv2 required, hop limit 1: hardens the node's instance-profile
      # credentials against SSRF-style theft from a Pod. Written explicitly
      # even though it currently matches the module default, so the decision
      # is visible in code rather than implicit.
      metadata_options = {
        http_tokens                 = "required"
        http_put_response_hop_limit = 1
      }

      # Root volume is not encrypted by default at either the account level
      # (EBS encryption-by-default is off in this account/region) or the
      # module level - encrypted = true must be explicit.
      block_device_mappings = {
        xvda = {
          device_name = "/dev/xvda"
          ebs = {
            volume_size = 20
            volume_type = "gp3"
            encrypted   = true
          }
        }
      }

      # No labels/taints: a single shared node group is sufficient for
      # Frontend/Backend/Worker - Kubernetes Namespaces provide workload
      # isolation, not separate node groups.
      # No remote_access/key_name: no SSH access to nodes.
    }
  }

  addons = {
    coredns    = {}
    kube-proxy = {}

    # before_compute = true on vpc-cni and eks-pod-identity-agent: both must
    # be ready before nodes attempt to join, or nodes fail with
    # NetworkPluginNotReady. The module does not guarantee creation order
    # between these two before_compute addons relative to each other (known,
    # documented upstream limitation) - verify aws-node health after apply
    # (Phase 7.14); do not pre-emptively attach AmazonEKS_CNI_Policy to the
    # node role as a workaround unless the race actually manifests.
    vpc-cni = {
      before_compute = true

      pod_identity_association = [{
        role_arn        = aws_iam_role.vpc_cni_pod_identity.arn
        service_account = "aws-node"
      }]
    }

    eks-pod-identity-agent = {
      before_compute = true
    }
  }

  tags = local.common_tags
}

# -----------------------------------------------------------------------------
# Operator access - explicit EKS Access Entry
#
# Grants the current Terraform caller (a permanent IAM user, not an STS
# session) cluster-admin via the EKS Access Entry API, so kubectl/verification
# work after apply. This is operator bootstrap access, not an application
# permission - kept as an explicit, named resource rather than the module's
# enable_cluster_creator_admin_permissions flag so the grant is visible in
# code rather than implicit in "whoever happens to run apply".
# -----------------------------------------------------------------------------

resource "aws_eks_access_entry" "admin" {
  cluster_name  = module.eks.cluster_name
  principal_arn = data.aws_caller_identity.current.arn
  type          = "STANDARD"

  tags = local.common_tags
}

resource "aws_eks_access_policy_association" "admin" {
  cluster_name  = module.eks.cluster_name
  principal_arn = aws_eks_access_entry.admin.principal_arn
  policy_arn    = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"

  access_scope {
    type = "cluster"
  }
}
