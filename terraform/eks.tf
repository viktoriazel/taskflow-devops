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
# Amazon EBS CSI Driver - EKS Pod Identity IAM role
#
# EKS does not install the EBS CSI driver by default, and this cluster has no
# ebs.csi.aws.com CSIDriver registered - there is currently no path for dynamic
# EBS provisioning. The driver is added as a managed add-on below; this role is
# the AWS-side identity its controller uses.
#
# As with the VPC CNI role above, the permission lives on a dedicated Pod
# Identity role tied to the controller's own ServiceAccount rather than on the
# shared Node IAM role, so volume create/attach/delete permissions are not
# implicitly available to every Pod that happens to run on a node.
#
# Policy choice: AmazonEBSCSIDriverEKSClusterScopedPolicy, deliberately
# narrower than both service-role/AmazonEBSCSIDriverPolicy and
# AmazonEBSCSIDriverPolicyV2 (the latter is what the add-on itself recommends).
# It scopes every mutating action to resources tagged
# ebs.csi.aws.com/cluster-name = this cluster, matched against the
# eks-cluster-name session tag that EKS Pod Identity sets automatically. The
# managed add-on supplies the cluster name to the driver, so that tag is
# applied without extra configuration. Requires driver v1.58.0 or later.
#
# The policy carries no KMS permissions of its own, and none are needed as
# things stand: the StorageClass sets no kmsKeyId, so volumes are encrypted
# with the AWS-managed aws/ebs key, whose own key policy already allows use
# through EC2. Moving to a customer-managed KMS key would additionally require
# a KMS policy on this role.
# -----------------------------------------------------------------------------

data "aws_iam_policy_document" "ebs_csi_pod_identity_trust" {
  statement {
    actions = ["sts:AssumeRole", "sts:TagSession"]

    principals {
      type        = "Service"
      identifiers = ["pods.eks.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:RequestTag/kubernetes-namespace"
      values   = ["kube-system"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:RequestTag/kubernetes-service-account"
      values   = ["ebs-csi-controller-sa"]
    }

    # The cluster ARN is composed from known inputs rather than read from
    # module.eks.cluster_arn: this role's ARN is consumed *inside* the module
    # (the addons block below), so referencing a module output here would risk
    # a dependency cycle. Every component is static - local.cluster_name is the
    # same value passed to the module as `name` - so the two forms cannot drift
    # apart.
    condition {
      test     = "StringEquals"
      variable = "aws:RequestTag/eks-cluster-arn"
      values   = ["arn:aws:eks:${var.aws_region}:${data.aws_caller_identity.current.account_id}:cluster/${local.cluster_name}"]
    }
  }
}

resource "aws_iam_role" "ebs_csi_pod_identity" {
  name               = "${local.cluster_name}-ebs-csi-pod-identity"
  assume_role_policy = data.aws_iam_policy_document.ebs_csi_pod_identity_trust.json

  tags = merge(local.common_tags, {
    Name = "${local.cluster_name}-ebs-csi-pod-identity"
  })
}

resource "aws_iam_role_policy_attachment" "ebs_csi_pod_identity" {
  role       = aws_iam_role.ebs_csi_pod_identity.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEBSCSIDriverEKSClusterScopedPolicy"
}

# -----------------------------------------------------------------------------
# Jenkins node group - dedicated node IAM role
#
# Deliberately not the role the EKS module would create: that one hardcodes
# AmazonEC2ContainerRegistryReadOnly, which grants 12 ECR actions on "*",
# including repository metadata and image scan findings. The module offers no
# way to swap it, so the role is built here instead - see the child module for
# the policy pair and for why the role lives in a module at all.
#
# The application node group keeps the module-created role: changing the IAM
# role of an existing node group forces the node group to be replaced.
# -----------------------------------------------------------------------------

module "jenkins_node_role" {
  source = "./modules/jenkins-node-role"

  name = "${local.cluster_name}-jenkins-node"
  tags = local.common_tags
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

      # Pinned to the AMI release already running on the nodes. The module
      # otherwise resolves the recommended release from SSM at plan time, so a
      # newly published EKS-optimized AMI turns up as a node group update
      # inside whatever plan happens to run next - and applying it replaces
      # every node in the group. Nodes should be replaced because we decided
      # to replace them, not because a newer AMI existed at plan time.
      #
      # Both settings are required: release_version reads ami_release_version
      # only when use_latest_ami_release_version is false, so pinning the
      # version alone would have no effect. Setting the flag to false also
      # drops the SSM lookup for this group entirely.
      use_latest_ami_release_version = false
      ami_release_version            = "1.35.6-20260810"

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

      # No labels/taints: this group carries the TaskFlow application
      # workloads - Frontend, Backend, Worker - and Kubernetes Namespaces
      # remain the logical separation between them. Jenkins does not share
      # this group; it runs on the dedicated node group below, for
      # predictable workload/scheduling and capacity isolation.
      # No remote_access/key_name: no SSH access to nodes.
    }

    # Dedicated node group for Jenkins. This is workload/scheduling and
    # capacity isolation, not a security boundary: a taint only influences
    # where the scheduler places Pods. It buys predictable capacity for a
    # workload whose Pod count fluctuates (dynamic build agents) on a cluster
    # whose existing group runs at desired == max with 11 Pods per t3.small.
    #
    # Single subnet, single AZ, deliberately. WaitForFirstConsumer provisions
    # the volume in the AZ of whichever node the Pod lands on, so a multi-AZ
    # group would work - but the Jenkins home volume pins the Pod to one AZ
    # from then on. With one controller and desired_size = 1, a single subnet
    # makes node and volume co-location deterministic rather than dependent on
    # where a replacement node happens to launch. private_app_1 also shares
    # eu-north-1a with the NAT Gateway, keeping agent egress inside one AZ.
    #
    # 30 GiB root, not the 20 GiB the application nodes carry: those hold no
    # BuildKit cache, Trivy database, or OCI build artifacts. A measured
    # application node uses 3.9 GiB of 20 GiB; the build workload adds several
    # GiB per run, and running out triggers image GC or Pod eviction mid-build.
    #
    # Label and taint are the node-side half only. The matching nodeSelector
    # and tolerations arrive with the Jenkins workloads themselves, so until
    # then this node runs the tolerating system DaemonSets and nothing else.
    jenkins = {
      instance_types = ["m7i-flex.large"]
      capacity_type  = "ON_DEMAND"
      ami_type       = "AL2023_x86_64_STANDARD"

      # Pinned for the reason given on the application group above, and more
      # sharply here: this group carries a single Jenkins controller with a
      # PersistentVolumeClaim, so an unplanned node replacement evicts the
      # controller Pod and detaches its EBS volume.
      use_latest_ami_release_version = false
      ami_release_version            = "1.35.6-20260810"

      min_size     = 1
      desired_size = 1
      max_size     = 2

      subnet_ids = [aws_subnet.private_app_1.id]

      # Own IAM role instead of the module's - see the module above. Reading
      # role_arn from that module is also what orders this node group behind
      # both of the role's policy attachments.
      create_iam_role = false
      iam_role_arn    = module.jenkins_node_role.role_arn

      labels = {
        workload = "jenkins"
      }

      taints = {
        jenkins = {
          key    = "workload"
          value  = "jenkins"
          effect = "NO_SCHEDULE"
        }
      }

      update_config = {
        max_unavailable = 1
      }

      metadata_options = {
        http_tokens                 = "required"
        http_put_response_hop_limit = 1
      }

      block_device_mappings = {
        xvda = {
          device_name = "/dev/xvda"
          ebs = {
            volume_size = 30
            volume_type = "gp3"
            encrypted   = true
          }
        }
      }

      # No remote_access/key_name: no SSH access to nodes.
    }
  }

  addons = {
    # Pinned to the version already running on the cluster. The module resolves
    # the most recent compatible version by default, so a newly published
    # CoreDNS build showed up as an in-place update inside an unrelated plan.
    # Cluster DNS should move because we decided to move it, not because a
    # newer build existed at plan time.
    #
    # addon_version alone is sufficient: the module coalesces it ahead of the
    # aws_eks_addon_version lookup, and most_recent feeds nothing but that
    # lookup. Deliberately scoped to CoreDNS - the other add-ons keep the
    # module's default behaviour until that is decided separately.
    coredns = {
      addon_version = "v1.14.3-eksbuild.3"
    }

    kube-proxy = {}

    # before_compute = true on vpc-cni and eks-pod-identity-agent: both must
    # be ready before nodes attempt to join, or nodes fail with
    # NetworkPluginNotReady. The module does not guarantee creation order
    # between these two before_compute addons relative to each other (known,
    # documented upstream limitation) - verify aws-node health after apply.
    # Do not pre-emptively attach AmazonEKS_CNI_Policy to the node role as a
    # workaround unless the race actually manifests.
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

    # Deliberately not before_compute: unlike the CNI and Pod Identity agent,
    # the EBS CSI driver does not gate node join - it needs nodes that already
    # exist, and the module orders regular add-ons after the node groups.
    #
    # configuration_values is intentionally left unset. The add-on can create
    # its own cluster-default gp3 StorageClass (defaultStorageClass.enabled);
    # that stays off, and the project declares its own StorageClass explicitly
    # instead of relying on an implicit cluster-wide default.
    aws-ebs-csi-driver = {
      pod_identity_association = [{
        role_arn        = aws_iam_role.ebs_csi_pod_identity.arn
        service_account = "ebs-csi-controller-sa"
      }]
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
