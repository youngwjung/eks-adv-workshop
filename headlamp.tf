# Headlamp를 설치할 네임스페이스
resource "kubernetes_namespace" "headlamp" {
  metadata {
    name = "headlamp"
  }
}

# Headlamp
resource "helm_release" "headlamp" {
  name       = "headlamp"
  repository = "https://kubernetes-sigs.github.io/headlamp"
  chart      = "headlamp"
  version    = var.headlamp_chart_version
  namespace  = kubernetes_namespace.headlamp.metadata[0].name

  values = [
    templatefile("${path.module}/helm-values/headlamp.yaml", {
      hostname = "headlamp.${aws_route53_zone.this.name}"
    })
  ]
}