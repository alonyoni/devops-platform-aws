output "vpc_id" {
  value = module.vpc.vpc_id
}

output "eks_cluster_name" {
  value = module.eks.cluster_name
}

output "eks_cluster_endpoint" {
  value = module.eks.cluster_endpoint
}

output "oidc_provider_arn" {
  value = module.eks.oidc_provider_arn
}

output "ecr_repository_urls" {
  value = module.ecr.repository_urls
}

output "cluster_autoscaler_role_arn" {
  value = module.iam.cluster_autoscaler_role_arn
}

output "alb_controller_role_arn" {
  value = module.iam.alb_controller_role_arn
}

output "jenkins_role_arn" {
  value = module.iam.jenkins_role_arn
}

output "kubeconfig_command" {
  description = "Run this command to configure kubectl"
  value       = "aws eks update-kubeconfig --region ${var.aws_region} --name ${module.eks.cluster_name}"
}
