output "eks_cluster_role_arn" {
  description = "ARN of the EKS cluster IAM role"
  value       = aws_iam_role.eks_cluster.arn
}

output "eks_node_group_role_arn" {
  description = "ARN of the EKS node group IAM role"
  value       = aws_iam_role.eks_node_group.arn
}

output "cluster_autoscaler_role_arn" {
  description = "ARN of the cluster autoscaler IRSA role"
  value       = aws_iam_role.cluster_autoscaler.arn
}

output "alb_controller_role_arn" {
  description = "ARN of the AWS Load Balancer Controller IRSA role"
  value       = aws_iam_role.alb_controller.arn
}

output "jenkins_role_arn" {
  description = "ARN of the Jenkins IRSA role"
  value       = aws_iam_role.jenkins.arn
}
