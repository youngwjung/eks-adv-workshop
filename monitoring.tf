# Prometheus를 설치할 네임스페이스
resource "kubernetes_namespace" "prometheus" {
  metadata {
    name = "monitoring"
  }
}

# Thanos 사이드카에서 Prometheus 지표를 보낼 버킷
resource "aws_s3_bucket" "thanos" {
  bucket = "${random_string.domain_prefix.result}-thanos-storage"

  force_destroy = true
}

# 위에서 생성한 버킷에 대한 접근 설정
resource "aws_iam_policy" "thanos_s3_access" {
  name = "thanos-s3-access"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = [
          "s3:ListBucket",
          "s3:GetObject",
          "s3:DeleteObject",
          "s3:PutObject"
        ]
        Effect = "Allow"
        Resource = [
          aws_s3_bucket.thanos.arn,
          "${aws_s3_bucket.thanos.arn}/*"
        ]
      },
    ]
  })
}

# Thanos 컴포넌트에 부여할 IAM 역할
module "thanos_irsa" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version = "5.39.0"

  role_name = "${module.eks.cluster_name}-cluster-thanos-role"

  role_policy_arns = {
    thanos_s3_access = aws_iam_policy.thanos_s3_access.arn
  }

  oidc_providers = {
    thanos = {
      provider_arn = module.eks.oidc_provider_arn
      namespace_service_accounts = [
        "thanos:thanos-bucketweb",
        "thanos:thanos-compactor",
        "thanos:thanos-storegateway",
        "monitoring:kube-prometheus-prometheus"
      ]
    }
  }
}

# Thanos 사이드카 설정 파일 (https://thanos.io/tip/thanos/storage.md/#s3)
resource "kubernetes_secret_v1" "prometheus_object_store_config" {
  metadata {
    name      = "thanos-objstore-config"
    namespace = kubernetes_namespace.prometheus.metadata[0].name
  }

  data = {
    "thanos.yml" = yamlencode({
      type = "s3"
      config = {
        bucket   = aws_s3_bucket.thanos.bucket
        endpoint = replace(aws_s3_bucket.thanos.bucket_regional_domain_name, "${aws_s3_bucket.thanos.bucket}.", "")
      }
    })
  }
}

# 모니터링 구성요소에 사용할 비밀번호
locals {
  monitoring_password = "Asdf!234"
}

resource "htpasswd_password" "monitoring" {
  password = local.monitoring_password
}

# AlertManager에 적용할 HTTP 인증 정보
resource "kubernetes_secret" "alertmanager" {
  metadata {
    name      = "alertmanager-password"
    namespace = kubernetes_namespace.prometheus.metadata[0].name
  }

  data = {
    auth = "admin:${htpasswd_password.monitoring.bcrypt}"
  }

  type = "Opaque"
}

# Kube-prometheus-stack
resource "helm_release" "prometheus" {
  name       = "prometheus"
  repository = "https://prometheus-community.github.io/helm-charts"
  chart      = "kube-prometheus-stack"
  version    = var.kube_prometheus_stack_chart_version
  namespace  = kubernetes_namespace.prometheus.metadata[0].name

  values = [
    templatefile("${path.module}/helm-values/prometheus.yaml", {
      cluster_name                      = data.aws_caller_identity.current.account_id
      alertmanager_hostname             = "alertmanager.${aws_route53_zone.this.name}"
      grafana_hostname                  = "grafana.${aws_route53_zone.this.name}"
      thanos_hostname                   = "thanos-query.${aws_route53_zone.this.name}"
      slack_channel                     = var.alert_slack_channel
      slack_webhook_url                 = var.alert_slack_webhook_url
      thanos_sidecar_role_arn           = module.thanos_irsa.iam_role_arn
      thanos_objconfig_secret_name      = kubernetes_secret_v1.prometheus_object_store_config.metadata[0].name
      alertmanager_password_secret_name = kubernetes_secret.alertmanager.metadata[0].name
      grafana_admin_password            = local.monitoring_password
    })
  ]

  depends_on = [
    helm_release.ingress_nginx
  ]
}

# Thanos를 설치할 네임스페이스
resource "kubernetes_namespace" "thanos" {
  metadata {
    name = "thanos"
  }
}

# Thanos 컴포넌트에서 사용할 오브젝트 스토리지 (S3) 설정 파일
resource "kubernetes_secret_v1" "thanos_object_store_config" {
  metadata {
    name      = "objstore-config"
    namespace = kubernetes_namespace.thanos.metadata[0].name
  }

  data = {
    "objstore.yml" = yamlencode({
      type = "s3"
      config = {
        bucket   = aws_s3_bucket.thanos.bucket
        endpoint = replace(aws_s3_bucket.thanos.bucket_regional_domain_name, "${aws_s3_bucket.thanos.bucket}.", "")
      }
    })
  }
}

# Thanos에 적용할 HTTP 인증 정보
resource "kubernetes_secret" "thanos" {
  metadata {
    name      = "thanos-password"
    namespace = kubernetes_namespace.thanos.metadata[0].name
  }

  data = {
    auth = "admin:${htpasswd_password.monitoring.bcrypt}"
  }

  type = "Opaque"
}

# Thanos
resource "helm_release" "thanos" {
  name       = "thanos"
  repository = "https://charts.bitnami.com/bitnami"
  chart      = "thanos"
  version    = var.thanos_chart_version
  namespace  = kubernetes_namespace.thanos.metadata[0].name

  values = [
    templatefile("${path.module}/helm-values/thanos.yaml", {
      query_frontend_hostname      = "thanos-query.${aws_route53_zone.this.name}"
      thanos_password_secret_name  = kubernetes_secret.thanos.metadata[0].name
      thanos_role_arn              = module.thanos_irsa.iam_role_arn
      thanos_objconfig_secret_name = kubernetes_secret_v1.thanos_object_store_config.metadata[0].name
    })
  ]

  depends_on = [
    helm_release.prometheus
  ]
}