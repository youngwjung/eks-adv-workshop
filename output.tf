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

output "alertmanager_url" {
  value = yamldecode(helm_release.prometheus.metadata[0].values)["alertmanager"]["ingress"]["hosts"][0]
}

output "grafana_url" {
  value = yamldecode(helm_release.prometheus.metadata[0].values)["grafana"]["ingress"]["hosts"][0]
}

output "thanos_url" {
  value = yamldecode(helm_release.thanos.metadata[0].values)["queryFrontend"]["ingress"]["hostname"]
}

output "opensearch_dashboard_url" {
  value = module.opensearch_log.domain_dashboard_endpoint
}

output "fluentbit_role_arn" {
  value = module.fluentbit_role.iam_role_arn
}

output "kubecost_url" {
  value = yamldecode(helm_release.kubecost.metadata[0].values)["ingress"]["hosts"][0]
}