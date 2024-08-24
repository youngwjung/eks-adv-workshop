# 로그 저장용 OpenSearch
module "opensearch_log" {
  source  = "terraform-aws-modules/opensearch/aws"
  version = "1.2.2"

  domain_name    = "${local.project}-log"
  engine_version = "OpenSearch_2.13"

  cluster_config = {
    dedicated_master_enabled = false
    instance_type            = "t3.medium.search"
    instance_count           = 1
    zone_awareness_enabled   = false
  }

  ebs_options = {
    volume_size = 20
  }

  advanced_security_options = {
    enabled                        = true
    internal_user_database_enabled = true
    master_user_options = {
      master_user_arn      = null
      master_user_name     = "admin"
      master_user_password = "Asdf!234"
    }
  }

  access_policy_statements = [
    {
      effect = "Allow"

      principals = [{
        type        = "*"
        identifiers = ["*"]
      }]

      actions = ["es:*"]
    }
  ]

  auto_tune_options = {
    desired_state = "DISABLED"
  }

  log_publishing_options = []
}

# 로그 저장용 OpenSearch 도메인에 대한 접근 권한을 명시한 정책
resource "aws_iam_policy" "opensearch_log_access" {
  name = "${local.project}-opensearch-log-access"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = [
          "es:ESHttp*"
        ]
        Effect = "Allow"
        Resource = [
          "${module.opensearch_log.domain_arn}/*"
        ]
      },
    ]
  })
}

# Fluent Bit에 부여할 역할
module "fluentbit_role" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version = "5.39.1"

  role_name = "${local.project}-fluentbit"

  role_policy_arns = {
    opensearch_access = aws_iam_policy.opensearch_log_access.arn
  }

  oidc_providers = {
    fluent_bit = {
      provider_arn = module.eks.oidc_provider_arn
      namespace_service_accounts = [
        "logging:fluent-bit"
      ]
    }
  }
}

# # 로그 저장용 OpenSearch 접근 제어
# resource "opensearch_roles_mapping" "opensearch_log_roles_mapping" {
#   role_name = "all_access"
#   users = [
#     "admin"
#   ]
#   backend_roles = [
#     module.fluentbit_role.iam_role_arn
#   ]
# }

# Fluentbit
resource "kubernetes_namespace" "fluent_bit" {
  metadata {
    name = "logging"
  }
}

resource "helm_release" "fluent_bit" {
  name       = "fluent-bit"
  repository = "https://fluent.github.io/helm-charts"
  chart      = "fluent-bit"
  version    = var.fluentbit_chart_version
  namespace  = kubernetes_namespace.fluent_bit.metadata[0].name

  values = [
    templatefile("${path.module}/helm-values/fluent-bit.yaml", {
      fluentbit_role_arn = module.fluentbit_role.iam_role_arn
      es_endpoint        = module.opensearch_log.domain_endpoint
      cluster_name       = local.project
      app_namespace      = "argocd"
    })
  ]
}