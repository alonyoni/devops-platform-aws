################################################################################
# EKS Module
# Creates: EKS control plane, managed node groups, OIDC provider,
#          cluster add-ons (CoreDNS, kube-proxy, vpc-cni, ebs-csi)
################################################################################

locals {
  name = "${var.project_name}-${var.environment}"

  common_tags = merge(var.tags, {
    Environment = var.environment
    Project     = var.project_name
    ManagedBy   = "terraform"
  })
}

# -------------------------------------------------------------------
# EKS Cluster
# -------------------------------------------------------------------
resource "aws_eks_cluster" "this" {
  name     = local.name
  version  = var.kubernetes_version
  role_arn = var.cluster_role_arn

  vpc_config {
    subnet_ids              = concat(var.public_subnet_ids, var.private_subnet_ids)
    endpoint_private_access = true
    endpoint_public_access  = var.endpoint_public_access
    public_access_cidrs     = var.public_access_cidrs
    security_group_ids      = [aws_security_group.cluster.id]
  }

  enabled_cluster_log_types = ["api", "audit", "authenticator", "controllerManager", "scheduler"]

  encryption_config {
    provider {
      key_arn = aws_kms_key.eks.arn
    }
    resources = ["secrets"]
  }

  depends_on = [aws_cloudwatch_log_group.eks]

  tags = local.common_tags
}

# -------------------------------------------------------------------
# CloudWatch Log Group for EKS control plane logs
# -------------------------------------------------------------------
resource "aws_cloudwatch_log_group" "eks" {
  name              = "/aws/eks/${local.name}/cluster"
  retention_in_days = 30
  tags              = local.common_tags
}

# -------------------------------------------------------------------
# KMS key for secrets encryption
# -------------------------------------------------------------------
resource "aws_kms_key" "eks" {
  description             = "EKS Secret Encryption Key - ${local.name}"
  deletion_window_in_days = 7
  enable_key_rotation     = true
  tags                    = local.common_tags
}

resource "aws_kms_alias" "eks" {
  name          = "alias/${local.name}-eks"
  target_key_id = aws_kms_key.eks.key_id
}

# -------------------------------------------------------------------
# Security Group for EKS control plane
# -------------------------------------------------------------------
resource "aws_security_group" "cluster" {
  name        = "${local.name}-cluster-sg"
  description = "EKS cluster security group"
  vpc_id      = var.vpc_id

  tags = merge(local.common_tags, {
    Name = "${local.name}-cluster-sg"
  })
}

resource "aws_security_group_rule" "cluster_ingress_nodes" {
  description              = "Allow worker nodes to communicate with the cluster API Server"
  from_port                = 443
  protocol                 = "tcp"
  security_group_id        = aws_security_group.cluster.id
  source_security_group_id = aws_security_group.nodes.id
  to_port                  = 443
  type                     = "ingress"
}

resource "aws_security_group_rule" "cluster_egress" {
  description       = "Allow cluster egress to nodes"
  from_port         = 0
  protocol          = "-1"
  security_group_id = aws_security_group.cluster.id
  cidr_blocks       = ["0.0.0.0/0"]
  to_port           = 0
  type              = "egress"
}

# -------------------------------------------------------------------
# Security Group for worker nodes
# -------------------------------------------------------------------
resource "aws_security_group" "nodes" {
  name        = "${local.name}-nodes-sg"
  description = "EKS worker node security group"
  vpc_id      = var.vpc_id

  tags = merge(local.common_tags, {
    Name                                  = "${local.name}-nodes-sg"
    "kubernetes.io/cluster/${local.name}" = "owned"
  })
}

resource "aws_security_group_rule" "nodes_ingress_self" {
  description              = "Allow nodes to communicate with each other"
  from_port                = 0
  protocol                 = "-1"
  security_group_id        = aws_security_group.nodes.id
  source_security_group_id = aws_security_group.nodes.id
  to_port                  = 65535
  type                     = "ingress"
}

resource "aws_security_group_rule" "nodes_ingress_cluster" {
  description              = "Allow worker nodes to receive communication from the cluster control plane"
  from_port                = 1025
  protocol                 = "tcp"
  security_group_id        = aws_security_group.nodes.id
  source_security_group_id = aws_security_group.cluster.id
  to_port                  = 65535
  type                     = "ingress"
}

resource "aws_security_group_rule" "nodes_egress" {
  description       = "Allow all outbound traffic"
  from_port         = 0
  protocol          = "-1"
  security_group_id = aws_security_group.nodes.id
  cidr_blocks       = ["0.0.0.0/0"]
  to_port           = 0
  type              = "egress"
}

# -------------------------------------------------------------------
# OIDC Provider (required for IRSA - IAM Roles for Service Accounts)
# -------------------------------------------------------------------
data "tls_certificate" "eks" {
  url = aws_eks_cluster.this.identity[0].oidc[0].issuer
}

resource "aws_iam_openid_connect_provider" "eks" {
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = [data.tls_certificate.eks.certificates[0].sha1_fingerprint]
  url             = aws_eks_cluster.this.identity[0].oidc[0].issuer

  tags = local.common_tags
}

# -------------------------------------------------------------------
# Managed Node Groups
# -------------------------------------------------------------------
resource "aws_eks_node_group" "system" {
  cluster_name    = aws_eks_cluster.this.name
  node_group_name = "${local.name}-system"
  node_role_arn   = var.node_group_role_arn
  subnet_ids      = var.private_subnet_ids
  instance_types  = var.system_node_instance_types
  capacity_type   = "ON_DEMAND"
  ami_type        = "AL2_x86_64"

  scaling_config {
    desired_size = var.system_node_desired
    max_size     = var.system_node_max
    min_size     = var.system_node_min
  }

  update_config {
    max_unavailable = 1
  }

  labels = {
    role        = "system"
    Environment = var.environment
  }

  taint {
    key    = "CriticalAddonsOnly"
    value  = "true"
    effect = "NO_SCHEDULE"
  }

  tags = merge(local.common_tags, {
    "k8s.io/cluster-autoscaler/enabled"     = "true"
    "k8s.io/cluster-autoscaler/${local.name}" = "owned"
  })

  lifecycle {
    ignore_changes = [scaling_config[0].desired_size]
  }
}

resource "aws_eks_node_group" "application" {
  cluster_name    = aws_eks_cluster.this.name
  node_group_name = "${local.name}-application"
  node_role_arn   = var.node_group_role_arn
  subnet_ids      = var.private_subnet_ids
  instance_types  = var.app_node_instance_types
  capacity_type   = var.app_node_capacity_type
  ami_type        = "AL2_x86_64"

  scaling_config {
    desired_size = var.app_node_desired
    max_size     = var.app_node_max
    min_size     = var.app_node_min
  }

  update_config {
    max_unavailable = 1
  }

  labels = {
    role        = "application"
    Environment = var.environment
  }

  tags = merge(local.common_tags, {
    "k8s.io/cluster-autoscaler/enabled"       = "true"
    "k8s.io/cluster-autoscaler/${local.name}" = "owned"
  })

  lifecycle {
    ignore_changes = [scaling_config[0].desired_size]
  }
}

# -------------------------------------------------------------------
# EKS Add-ons
# -------------------------------------------------------------------
resource "aws_eks_addon" "coredns" {
  cluster_name                = aws_eks_cluster.this.name
  addon_name                  = "coredns"
  addon_version               = var.coredns_version
  resolve_conflicts_on_update = "OVERWRITE"
  tags                        = local.common_tags

  depends_on = [aws_eks_node_group.system]
}

resource "aws_eks_addon" "kube_proxy" {
  cluster_name                = aws_eks_cluster.this.name
  addon_name                  = "kube-proxy"
  addon_version               = var.kube_proxy_version
  resolve_conflicts_on_update = "OVERWRITE"
  tags                        = local.common_tags
}

resource "aws_eks_addon" "vpc_cni" {
  cluster_name                = aws_eks_cluster.this.name
  addon_name                  = "vpc-cni"
  addon_version               = var.vpc_cni_version
  resolve_conflicts_on_update = "OVERWRITE"
  tags                        = local.common_tags
}

resource "aws_eks_addon" "ebs_csi_driver" {
  cluster_name                = aws_eks_cluster.this.name
  addon_name                  = "aws-ebs-csi-driver"
  addon_version               = var.ebs_csi_version
  resolve_conflicts_on_update = "OVERWRITE"
  service_account_role_arn    = aws_iam_role.ebs_csi.arn
  tags                        = local.common_tags

  depends_on = [aws_eks_node_group.system]
}

# -------------------------------------------------------------------
# EBS CSI Driver IRSA
# -------------------------------------------------------------------
data "aws_iam_policy_document" "ebs_csi_assume" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    effect  = "Allow"

    condition {
      test     = "StringEquals"
      variable = "${replace(aws_iam_openid_connect_provider.eks.url, "https://", "")}:sub"
      values   = ["system:serviceaccount:kube-system:ebs-csi-controller-sa"]
    }

    principals {
      identifiers = [aws_iam_openid_connect_provider.eks.arn]
      type        = "Federated"
    }
  }
}

resource "aws_iam_role" "ebs_csi" {
  name               = "${local.name}-ebs-csi-role"
  assume_role_policy = data.aws_iam_policy_document.ebs_csi_assume.json
  tags               = local.common_tags
}

resource "aws_iam_role_policy_attachment" "ebs_csi" {
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"
  role       = aws_iam_role.ebs_csi.name
}

# -------------------------------------------------------------------
# aws-auth ConfigMap: grant additional IAM roles/users cluster access
# -------------------------------------------------------------------
resource "kubernetes_config_map_v1_data" "aws_auth" {
  metadata {
    name      = "aws-auth"
    namespace = "kube-system"
  }

  data = {
    mapRoles = yamlencode(concat(
      [
        {
          rolearn  = var.node_group_role_arn
          username = "system:node:{{EC2PrivateDNSName}}"
          groups   = ["system:bootstrappers", "system:nodes"]
        }
      ],
      var.additional_map_roles
    ))

    mapUsers = yamlencode(var.additional_map_users)
  }

  force = true

  depends_on = [aws_eks_cluster.this]
}
