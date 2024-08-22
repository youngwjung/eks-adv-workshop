# Kubecost를 설치할 네임스페이스
resource "kubernetes_namespace" "kubecost" {
  metadata {
    name = "kubecost"
  }
}

# Kubecost
resource "helm_release" "kubecost" {
  name       = "kubecost"
  repository = "https://kubecost.github.io/cost-analyzer"
  chart      = "cost-analyzer"
  version    = var.kubecost_chart_version
  namespace  = kubernetes_namespace.kubecost.metadata[0].name

  values = [
    templatefile("${path.module}/helm-values/kubecost.yaml", {
      hostname            = "kubecost.${aws_route53_zone.this.name}"
      thanos_query_fqdn   = "http://thanos-query.thanos.svc.cluster.local:9090"
      grafana_domain_name = "grafana.${aws_route53_zone.this.name}"
      vpc_cidr            = module.vpc.vpc_cidr_block
    })
  ]

  depends_on = [
    helm_release.thanos
  ]
}