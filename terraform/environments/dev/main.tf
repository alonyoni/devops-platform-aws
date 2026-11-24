################################################################################
# Dev Environment
################################################################################

terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.24"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
  }

  backend "s3" {
    bucket         = "devops-platform-terraform-state"
    key            = "dev/terraform.tfstate"
    region         = "us-east-1"
    encrypt        = true
    dynamodb_table = "devops-platform-terraform-locks"
  }
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Environment = "dev"
      Project     = "devops-platform"
      ManagedBy   = "terraform"
    }
  }
}

# Kubernetes provider uses EKS cluster credentials
provider "kubernetes" {
  host                   = module.eks.cluster_endpoint
  cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)

  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    args = [
      "eks", "get-token",
      "--cluster-name", module.eks.cluster_name,
      "--region", var.aws_region
    ]
  }
}

# -------------------------------------------------------------------
# VPC
# -------------------------------------------------------------------
module "vpc" {
  source = "../../modules/vpc"

  project_name       = var.project_name
  environment        = "dev"
  vpc_cidr           = var.vpc_cidr
  availability_zones = var.availability_zones
  enable_nat_gateway = true
  single_nat_gateway = true   # Cost saving for dev - single NAT
  enable_flow_logs   = true
}

# -------------------------------------------------------------------
# IAM (OIDC depends on EKS, so we pass placeholder then fill after)
# -------------------------------------------------------------------
module "iam" {
  source = "../../modules/iam"

  project_name      = var.project_name
  environment       = "dev"
  aws_region        = var.aws_region
  aws_account_id    = var.aws_account_id
  oidc_provider_arn = module.eks.oidc_provider_arn
  oidc_provider_url = module.eks.oidc_provider_url

  depends_on = [module.eks]
}

# -------------------------------------------------------------------
# EKS Cluster
# -------------------------------------------------------------------
module "eks" {
  source = "../../modules/eks"

  project_name        = var.project_name
  environment         = "dev"
  vpc_id              = module.vpc.vpc_id
  public_subnet_ids   = module.vpc.public_subnet_ids
  private_subnet_ids  = module.vpc.private_subnet_ids
  cluster_role_arn    = module.iam.eks_cluster_role_arn
  node_group_role_arn = module.iam.eks_node_group_role_arn

  kubernetes_version     = var.kubernetes_version
  endpoint_public_access = true
  public_access_cidrs    = var.public_access_cidrs

  # Dev node sizes — smaller/cheaper
  system_node_instance_types = ["t3.medium"]
  system_node_desired        = 2
  system_node_min            = 1
  system_node_max            = 3

  app_node_instance_types = ["t3.large", "t3.xlarge"]
  app_node_capacity_type  = "SPOT"
  app_node_desired        = 2
  app_node_min            = 1
  app_node_max            = 6

  additional_map_users = var.admin_iam_users

  depends_on = [module.iam]
}

# -------------------------------------------------------------------
# ECR
# -------------------------------------------------------------------
module "ecr" {
  source = "../../modules/ecr"

  project_name     = var.project_name
  environment      = "dev"
  repository_names = ["app", "jenkins-agent"]
  max_image_count  = 10
}
