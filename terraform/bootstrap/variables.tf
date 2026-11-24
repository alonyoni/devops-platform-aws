variable "aws_region" {
  description = "AWS region for the bootstrap resources"
  type        = string
  default     = "us-east-1"
}

variable "project_name" {
  description = "Project name used as a prefix for all resources"
  type        = string
  default     = "devops-platform"
}
