# -----------------------------------------------------------------------------
# Amazon VPC CNI - EKS Pod Identity IAM role
#
# AmazonEKS_CNI_Policy is attached here rather than to the shared node role
# (iam_role_attach_cni_policy = false below), so ENI/IP permissions reach only
# the aws-node ServiceAccount instead of every Pod running on a node.
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
# AWS-side identity for the driver's controller, installed as a managed add-on
# below. Like the CNI role above, the permissions sit on a dedicated role bound
# to the controller's ServiceAccount, not on the shared node role, so volume
# create/attach/delete is not available to every Pod on a node.
#
# AmazonEBSCSIDriverEKSClusterScopedPolicy is narrower than the recommended
# AmazonEBSCSIDriverPolicyV2: it scopes mutating actions to resources tagged
# ebs.csi.aws.com/cluster-name = this cluster, matched against the session tag
# EKS Pod Identity sets automatically. Requires driver v1.58.0 or later.
#
# No KMS permissions, and none are needed: the StorageClass sets no kmsKeyId,
# so volumes use the AWS-managed aws/ebs key, whose key policy already allows
# use through EC2. A customer-managed key would require adding a KMS policy.
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

    # Cluster ARN composed from known inputs rather than read from
    # module.eks.cluster_arn: this role is consumed inside the module below, so
    # referencing a module output here would risk a dependency cycle.
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
# Not the role the EKS module would create: that one hardcodes
# AmazonEC2ContainerRegistryReadOnly, which grants ECR read actions on "*" with
# no way to swap it. The application node group keeps the module-created role,
# because changing a node group's IAM role forces the node group to be replaced.
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

  # No customer-managed KMS key for Secrets envelope encryption - the module
  # would otherwise create one implicitly. Secrets keep AWS's baseline at-rest
  # encryption; a dedicated CMK is a deliberately deferred decision.
  create_kms_key    = false
  encryption_config = null

  # No control-plane logging or CloudWatch Log Group; the module enables both by
  # default. Deferred - can be added later if troubleshooting needs it.
  enabled_log_types           = []
  create_cloudwatch_log_group = false

  # Access entries only, no aws-auth ConfigMap: API_AND_CONFIG_MAP would leave
  # two independently-driftable sources of truth for cluster access. Managed
  # node groups join through a separate path, so this does not affect them.
  authentication_mode = "API"

  enable_irsa = true

  # Operator admin access is granted by the named access entry at the end of
  # this file - keep the module's implicit entry off.
  enable_cluster_creator_admin_permissions = false

  eks_managed_node_groups = {
    default = {
      instance_types = ["t3.small"]
      capacity_type  = "ON_DEMAND"
      ami_type       = "AL2023_x86_64_STANDARD"

      # Pinned to the AMI release the nodes already run. Otherwise the module
      # resolves the recommended release from SSM at plan time, so a newly
      # published AMI appears as a node group update in whatever plan runs
      # next - and applying it replaces every node in the group.
      #
      # Both settings are needed: ami_release_version is read only when
      # use_latest_ami_release_version is false.
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
      # credentials against SSRF-style theft from a Pod. Set explicitly even
      # though it matches the module default.
      metadata_options = {
        http_tokens                 = "required"
        http_put_response_hop_limit = 1
      }

      # encrypted must be explicit: EBS encryption-by-default is off in this
      # account/region, and the module does not set it either.
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

      # No labels/taints: this group runs the TaskFlow application workloads,
      # which stay separated by Namespace. Jenkins runs on its own group below.
      # No remote_access/key_name: no SSH access to nodes.
    }

    # Dedicated group for Jenkins: workload and capacity isolation, not a
    # security boundary - a taint only influences where the scheduler places
    # Pods. It buys predictable capacity for a workload whose Pod count
    # fluctuates (dynamic build agents).
    #
    # Single subnet, single AZ on purpose: the Jenkins home volume pins the
    # controller Pod to one AZ anyway, so one subnet makes node and volume
    # co-location deterministic instead of dependent on where a replacement
    # node launches. private_app_1 also shares eu-north-1a with the NAT
    # Gateway, keeping agent egress inside one AZ.
    #
    # 30 GiB root instead of the 20 GiB on application nodes: BuildKit cache,
    # Trivy database and build artifacts. Running out triggers image GC or Pod
    # eviction mid-build.
    #
    # Label and taint are the node-side half only - the matching nodeSelector
    # and tolerations arrive with the Jenkins workloads.
    jenkins = {
      instance_types = ["m7i-flex.large"]
      capacity_type  = "ON_DEMAND"
      ami_type       = "AL2023_x86_64_STANDARD"

      # Pinned for the reason given on the application group, and more sharply
      # here: an unplanned node replacement evicts the single Jenkins
      # controller Pod and detaches its EBS volume.
      use_latest_ami_release_version = false
      ami_release_version            = "1.35.6-20260810"

      min_size     = 1
      desired_size = 1
      max_size     = 2

      subnet_ids = [aws_subnet.private_app_1.id]

      # Own IAM role instead of the module's - see the module above. Reading
      # role_arn from it also orders this node group behind the role's policy
      # attachments.
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
    # Pin add-on versions so new compatible builds do not appear as unrelated
    # plan updates. Upgrades remain explicit changes to this configuration.
    coredns = {
      addon_version = "v1.14.3-eksbuild.3"
    }

    kube-proxy = {
      addon_version = "v1.35.3-eksbuild.18"
    }

    # before_compute on vpc-cni and eks-pod-identity-agent: both must be ready
    # before nodes join, or nodes come up NetworkPluginNotReady. The module
    # does not guarantee ordering between these two, so verify aws-node health
    # after apply.
    vpc-cni = {
      addon_version  = "v1.23.0-eksbuild.1"
      before_compute = true

      pod_identity_association = [{
        role_arn        = aws_iam_role.vpc_cni_pod_identity.arn
        service_account = "aws-node"
      }]
    }

    eks-pod-identity-agent = {
      addon_version  = "v1.4.0-eksbuild.1"
      before_compute = true
    }

    # Deliberately not before_compute: the EBS CSI driver does not gate node
    # join - it needs nodes that already exist, and the module orders regular
    # add-ons after the node groups.
    #
    # configuration_values left unset so the add-on does not create its own
    # cluster-default gp3 StorageClass; the project declares its own instead.
    aws-ebs-csi-driver = {
      addon_version = "v1.63.1-eksbuild.1"

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
# Cluster-admin for the current Terraform caller (a permanent IAM user), so
# kubectl and post-apply verification work. Kept as a named resource rather
# than enable_cluster_creator_admin_permissions, so the grant points at a
# specific principal instead of "whoever happens to run apply".
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
