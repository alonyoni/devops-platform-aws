variable "project_name" {
  description = "Project name prefix"
  type        = string
}

variable "environment" {
  description = "Deployment environment"
  type        = string
}

variable "vpc_id" {
  description = "VPC ID to deploy the cluster into"
  type        = string
}

variable "public_subnet_ids" {
  description = "Public subnet IDs"
  type        = list(string)
}

variable "private_subnet_ids" {
  description = "Private subnet IDs (worker nodes go here)"
  type        = list(string)
}

variable "cluster_role_arn" {
  description = "IAM role ARN for the EKS cluster"
  type        = string
}

variable "node_group_role_arn" {
  description = "IAM role ARN for the EKS node groups"
  type        = string
}

variable "kubernetes_version" {
  description = "Kubernetes version for EKS"
  type        = string
  default     = "1.29"
}

variable "endpoint_public_access" {
  description = "Enable public access to the EKS API server"
  type        = bool
  default     = true
}

variable "public_access_cidrs" {
  description = "CIDRs allowed to access the public EKS API endpoint"
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

# System node group
variable "system_node_instance_types" {
  type    = list(string)
  default = ["t3.medium"]
}

variable "system_node_desired" {
  type    = number
  default = 2
}

variable "system_node_min" {
  type    = number
  default = 1
}

variable "system_node_max" {
  type    = number
  default = 4
}

# Application node group
variable "app_node_instance_types" {
  type    = list(string)
  default = ["t3.large"]
}

variable "app_node_capacity_type" {
  description = "ON_DEMAND or SPOT"
  type        = string
  default     = "SPOT"
}

variable "app_node_desired" {
  type    = number
  default = 2
}

variable "app_node_min" {
  type    = number
  default = 1
}

variable "app_node_max" {
  type    = number
  default = 10
}

# EKS Add-on versions
variable "coredns_version" {
  type    = string
  default = "v1.11.1-eksbuild.4"
}

variable "kube_proxy_version" {
  type    = string
  default = "v1.29.0-eksbuild.1"
}

variable "vpc_cni_version" {
  type    = string
  default = "v1.16.0-eksbuild.1"
}

variable "ebs_csi_version" {
  type    = string
  default = "v1.26.0-eksbuild.1"
}

variable "additional_map_roles" {
  description = "Additional IAM roles to add to the aws-auth ConfigMap"
  type = list(object({
    rolearn  = string
    username = string
    groups   = list(string)
  }))
  default = []
}

variable "additional_map_users" {
  description = "Additional IAM users to add to the aws-auth ConfigMap"
  type = list(object({
    userarn  = string
    username = string
    groups   = list(string)
  }))
  default = []
}

variable "tags" {
  description = "Tags to apply to all resources"
  type        = map(string)
  default     = {}
}
