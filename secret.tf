# 외부 비밀 저장소에서 암호 정보를 불러와서 Pod에 볼륨으로 마운트 시켜주는 라이브러리
resource "helm_release" "secrets_store_csi_driver" {
  name       = "secrets-store-csi-driver"
  repository = "https://kubernetes-sigs.github.io/secrets-store-csi-driver/charts"
  chart      = "secrets-store-csi-driver"
  version    = var.secrets_store_csi_driver_chart_version
  namespace  = "kube-system"

  values = [
    templatefile("${path.module}/helm-values/secrets-store-csi-driver.yaml", {})
  ]
}

# Secrets Store CSI Driver에 비밀 정보를 제공해주는 AWS 라이브러리
resource "helm_release" "secrets_store_csi_driver_provider_aws" {
  name       = "secrets-store-csi-driver-provider-aws"
  repository = "https://aws.github.io/secrets-store-csi-driver-provider-aws"
  chart      = "secrets-store-csi-driver-provider-aws"
  version    = var.secrets_store_csi_driver_provider_aws_chart_version
  namespace  = "kube-system"

  values = [
    templatefile("${path.module}/helm-values/secrets-store-csi-driver-provider-aws.yaml", {})
  ]
}

# Pod에 부여할 역할
module "pod_role" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version = "5.39.1"

  role_name = "${local.project}-pod"

  role_policy_arns = {
    secet_manager_access = "arn:aws:iam::aws:policy/SecretsManagerReadWrite"
  }

  oidc_providers = {
    pod = {
      provider_arn = module.eks.oidc_provider_arn
      namespace_service_accounts = [
        "default:nginx"
      ]
    }
  }
}

# Pod에 부여할 ServiceAccount
resource "kubernetes_service_account_v1" "pod" {
  metadata {
    name = "nginx"
    annotations = {
      "eks.amazonaws.com/role-arn" = module.pod_role.iam_role_arn
    }
  }
}

# Secret 객체에 변경이 감지되면 Pod를 재생성해주는 라이브버리
resource "helm_release" "reloader" {
  name       = "reloader"
  repository = "https://stakater.github.io/stakater-charts"
  chart      = "reloader"
  version    = var.reloader_chart_version
  namespace  = "kube-system"

  values = [
    templatefile("${path.module}/helm-values/reloader.yaml", {})
  ]
}