variable "aws_region" {
  description = "AWS region"
  type        = string
  default     = "us-east-1"
}

variable "aws_account_id" {
  description = "AWS account ID"
  type        = string
}

variable "project_name" {
  description = "Project name"
  type        = string
  default     = "devops-platform"
}

variable "vpc_cidr" {
  description = "VPC CIDR block"
  type        = string
  default     = "10.0.0.0/16"
}

variable "availability_zones" {
  description = "Availability zones to use"
  type        = list(string)
  default     = ["us-east-1a", "us-east-1b", "us-east-1c"]
}

variable "kubernetes_version" {
  description = "Kubernetes version for EKS"
  type        = string
  default     = "1.29"
}

variable "public_access_cidrs" {
  description = "CIDRs that can reach the EKS API server publicly"
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

variable "admin_iam_users" {
  description = "IAM users to add to aws-auth as cluster admins"
  type = list(object({
    userarn  = string
    username = string
    groups   = list(string)
  }))
  default = []
}
