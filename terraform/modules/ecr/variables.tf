variable "project_name" {
  description = "Project name prefix for repositories"
  type        = string
}

variable "environment" {
  description = "Deployment environment"
  type        = string
}

variable "repository_names" {
  description = "List of ECR repository names to create (will be prefixed with project_name)"
  type        = list(string)
  default     = ["app"]
}

variable "image_tag_mutability" {
  description = "MUTABLE or IMMUTABLE image tags"
  type        = string
  default     = "MUTABLE"
}

variable "max_image_count" {
  description = "Maximum number of tagged images to keep per repository"
  type        = number
  default     = 20
}

variable "allow_account_ids" {
  description = "Additional AWS account IDs allowed to pull from ECR"
  type        = list(string)
  default     = []
}

variable "tags" {
  description = "Tags to apply to all resources"
  type        = map(string)
  default     = {}
}
