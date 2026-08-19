# -----------------------------------------------------------------------------
# Jenkins node group - node IAM role
#
# This role exists as its own small module for one reason: ordering. The EKS
# module's node group takes an existing role ARN, but nothing in that value
# ties the node group to the role's policy attachments, and the module's own
# safeguard (its launch template depends_on aws_iam_role_policy_attachment.this)
# is inert when create_iam_role = false. Nodes that launch before their
# policies are attached cannot call eks:DescribeCluster or pull images, and
# fail to register.
#
# Wrapping the role here lets the role_arn output carry an explicit depends_on
# for both attachments, so every consumer of the ARN waits for them. The same
# guarantee at the root would require depends_on on the whole EKS module,
# which defers every data source inside it and makes unrelated resources plan
# as (known after apply).
#
# Policy pair: AmazonEKSWorkerNodePolicy plus AmazonEC2ContainerRegistryPullOnly,
# AWS's current guidance for a node role. PullOnly grants the 4 ECR actions a
# kubelet needs to pull an image, rather than the 12 read actions of
# AmazonEC2ContainerRegistryReadOnly. AmazonEKSWorkerNodePolicy also carries
# eks-auth:AssumeRoleForPodIdentity for the EKS Pod Identity Agent. No CNI
# policy: VPC CNI and EBS CSI permissions live on their own Pod Identity roles
# bound to their ServiceAccounts, never on a node role.
# -----------------------------------------------------------------------------

data "aws_iam_policy_document" "trust" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "this" {
  name               = var.name
  assume_role_policy = data.aws_iam_policy_document.trust.json

  tags = merge(var.tags, {
    Name = var.name
  })
}

resource "aws_iam_role_policy_attachment" "worker" {
  role       = aws_iam_role.this.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy"
}

resource "aws_iam_role_policy_attachment" "ecr_pull" {
  role       = aws_iam_role.this.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryPullOnly"
}
