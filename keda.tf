# KEDA에 부여할 AWS 권한
resource "aws_iam_policy" "keda_sqs_access" {
  name = "keda-sqs-access"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action   = ["sqs:GetQueueAttributes"]
        Effect   = "Allow"
        Resource = ["*"]
      }
    ]
  })
}

# KEDA에 부여할 IAM 역할
module "keda_irsa" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version = "5.39.0"

  role_name = "${module.eks.cluster_name}-cluster-keda-role"

  role_policy_arns = {
    sqs_access = aws_iam_policy.keda_sqs_access.arn
  }

  oidc_providers = {
    fluent_bit = {
      provider_arn = module.eks.oidc_provider_arn
      namespace_service_accounts = [
        "keda:keda-operator"
      ]
    }
  }
}

# KEDA를 설치할 네임스페이스
resource "kubernetes_namespace" "keda" {
  metadata {
    name = "keda"
  }
}

# KEDA
resource "helm_release" "keda" {
  name       = "keda"
  repository = "https://kedacore.github.io/charts"
  chart      = "keda"
  version    = var.keda_chart_version
  namespace  = kubernetes_namespace.keda.metadata[0].name

  values = [
    <<-EOT
    podIdentity:
      aws:
        irsa:
          enabled: true
          roleArn: ${module.keda_irsa.iam_role_arn}
    EOT
  ]

  depends_on = [
    helm_release.karpenter
  ]
}

# SQS
module "sqs" {
  source  = "terraform-aws-modules/sqs/aws"
  version = "4.2.0"

  name = "my-queue"
}