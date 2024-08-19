output "update_kubeconfig" {
  value = "aws eks update-kubeconfig --name ${module.eks.cluster_name} --region ${data.aws_region.current.name}"
}

output "gitlab_url" {
  value = data.kubernetes_ingress_v1.gitlab.spec.0.rule.0.host
}

output "gitlab_password" {
  value     = data.kubernetes_secret_v1.gitlab.data["password"]
  sensitive = true
}

output "ecr_repository_url" {
  value = module.ecr.repository_url
}

output "domain" {
  value = aws_route53_zone.this.name
}

output "argocd_url" {
  value = data.kubernetes_ingress_v1.argocd.spec.0.rule.0.host
}

output "sqs_url" {
  value = module.sqs.queue_url
}