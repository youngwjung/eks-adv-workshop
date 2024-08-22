# EKS 클러스터
module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "20.23.0"

  cluster_name    = local.project
  cluster_version = var.eks_cluster_version

  # 클러스터 엔드포인트(API 서버)에 퍼블릭 접근 허용
  cluster_endpoint_public_access = true

  # 클러스터 보안그룹을 생성할 VPC
  vpc_id = module.vpc.vpc_id

  # 노드그룹/노드가 생성되는 서브넷
  subnet_ids = module.vpc.private_subnets

  # 컨트롤 플레인으로 연결될 ENI를 생성할 서브넷
  control_plane_subnet_ids = module.vpc.private_subnets

  # 클러스터를 생성한 IAM 객체에서 쿠버네티스 어드민 권한 할당
  enable_cluster_creator_admin_permissions = true

  create_kms_key              = false
  create_cloudwatch_log_group = false
  create_node_security_group  = false

  fargate_profiles = {
    # Karpenter를 Fargate에 실행
    karpenter = {
      selectors = [
        {
          namespace = "karpenter"
        }
      ]
    }
    # CoreDNS를 Fargate에 실행
    coredns = {
      selectors = [
        {
          namespace = "kube-system"
          labels = {
            "k8s-app" = "kube-dns"
          }
        }
      ]
    }
  }

  # 로깅 비활성화
  cluster_enabled_log_types = []
  # 암호화 비활성화
  cluster_encryption_config = {}

  depends_on = [
    module.vpc.natgw_ids
  ]
}

# EKS 클러스터 버전에 맞는 CoreDNS 애드온 버전 불러오기
data "aws_eks_addon_version" "coredns" {
  addon_name         = "coredns"
  kubernetes_version = module.eks.cluster_version
}

# CoreDNS
resource "aws_eks_addon" "coredns" {
  cluster_name                = module.eks.cluster_name
  addon_name                  = "coredns"
  addon_version               = data.aws_eks_addon_version.coredns.version
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"
  configuration_values = jsonencode({
    # Karpenter가 실행되려면 CoreDNS가 필수 구성요소기 때문에 Fargate에 배포
    computeType = "Fargate"
  })

  depends_on = [
    module.eks.fargate_profiles
  ]
}

# Karpenter 구성에 필요한 AWS 리소스 생성
module "karpenter" {
  source  = "terraform-aws-modules/eks/aws//modules/karpenter"
  version = "20.23.0"

  cluster_name                  = module.eks.cluster_name
  node_iam_role_name            = "${module.eks.cluster_name}-node-role"
  node_iam_role_use_name_prefix = false

  # Karpenter에 부여할 IAM 역할 생성
  enable_irsa            = true
  irsa_oidc_provider_arn = module.eks.oidc_provider_arn

  # Karpenter가 생성할 노드에 부여할 역할에 기본 정책 이외에 추가할 IAM 정책
  node_iam_role_additional_policies = {
    AmazonSSMManagedInstanceCore = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
    AmazonEBSCSIDriverPolicy     = "arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"
  }
}

# Karpenter를 배포할 네임 스페이스
resource "kubernetes_namespace" "karpenter" {
  metadata {
    name = "karpenter"
  }
}

# Karpenter
resource "helm_release" "karpenter-crd" {
  name       = "karpenter-crd"
  repository = "oci://public.ecr.aws/karpenter"
  chart      = "karpenter-crd"
  version    = var.karpenter_chart_version
  namespace  = kubernetes_namespace.karpenter.metadata[0].name
}

resource "helm_release" "karpenter" {
  name       = "karpenter"
  repository = "oci://public.ecr.aws/karpenter"
  chart      = "karpenter"
  version    = var.karpenter_chart_version
  namespace  = kubernetes_namespace.karpenter.metadata[0].name

  skip_crds = true

  values = [
    <<-EOT
    settings:
      clusterName: ${module.eks.cluster_name}
      clusterEndpoint: ${module.eks.cluster_endpoint}
      interruptionQueue: ${module.karpenter.queue_name}
      featureGates:
        spotToSpotConsolidation: true
    serviceAccount:
      annotations:
        eks.amazonaws.com/role-arn: ${module.karpenter.iam_role_arn}
    serviceMonitor:
      enabled: true
    EOT
  ]

  depends_on = [
    aws_eks_addon.coredns,
    helm_release.karpenter-crd,
    module.karpenter,
    module.vpc.private_route_table_ids,
    module.vpc.private_nat_gateway_route_ids,
    module.vpc.private_route_table_association_ids,
    module.vpc.public_route_table_ids,
    module.vpc.public_internet_gateway_route_id,
    module.vpc.public_route_table_association_ids
  ]

  provisioner "local-exec" {
    when       = destroy
    command    = "kubectl delete node $(kubectl get node -l eks.amazonaws.com/compute-type!=fargate -o jsonpath='{.items[*].metadata.name}')"
    on_failure = continue
  }
}

# Karpenter EC2NodeClass
resource "kubernetes_manifest" "ec2nodeclass_default" {
  manifest = {
    "apiVersion" = "karpenter.k8s.aws/v1"
    "kind"       = "EC2NodeClass"
    "metadata" = {
      "name" = "default"
    }
    "spec" = {
      "amiSelectorTerms" = [
        {
          "alias" = "al2023@latest"
        }
      ],
      "blockDeviceMappings" = [
        {
          "deviceName" = "/dev/xvda"
          "ebs" = {
            "encrypted"  = true
            "volumeSize" = "20Gi"
            "volumeType" = "gp3"
          }
        },
      ]
      "role" = module.karpenter.node_iam_role_name
      "securityGroupSelectorTerms" = [
        {
          "id" = module.eks.cluster_primary_security_group_id
        },
      ]
      "subnetSelectorTerms" = [
        {
          "tags" = {
            "karpenter.sh/discovery" = module.eks.cluster_name
          }
        },
      ],
      "metadataOptions" = {
        "httpPutResponseHopLimit" = 2
      }
    }
  }

  depends_on = [
    helm_release.karpenter
  ]
}

# Karpenter NodePool
resource "kubernetes_manifest" "nodepool_default" {
  manifest = {
    "apiVersion" = "karpenter.sh/v1"
    "kind"       = "NodePool"
    "metadata" = {
      "name" = "default"
    }
    "spec" = {
      "disruption" = {
        "consolidationPolicy" = "WhenEmptyOrUnderutilized"
        "consolidateAfter"    = "Never"
      }
      "limits" = {
        "cpu" = 1000
      }
      "template" = {
        "spec" = {
          "nodeClassRef" = {
            "group" = split("/", kubernetes_manifest.ec2nodeclass_default.manifest.apiVersion)[0]
            "kind"  = kubernetes_manifest.ec2nodeclass_default.manifest.kind
            "name"  = kubernetes_manifest.ec2nodeclass_default.manifest.metadata.name
          }
          "requirements" = [
            {
              "key"      = "kubernetes.io/arch"
              "operator" = "In"
              "values" = [
                "amd64",
              ]
            },
            {
              "key"      = "kubernetes.io/os"
              "operator" = "In"
              "values" = [
                "linux",
              ]
            },
            {
              "key"      = "karpenter.sh/capacity-type"
              "operator" = "In"
              "values" = [
                "on-demand",
                "spot",
              ]
            },
            {
              "key"      = "karpenter.k8s.aws/instance-memory"
              "operator" = "Gt"
              "values" = [
                "1024",
              ]
            },
          ]
        }
      }
    }
  }
}

# EKS-Addon
locals {
  eks_addons = [
    "kube-proxy",
    "vpc-cni",
    "aws-ebs-csi-driver",
    "eks-pod-identity-agent"
  ]
}

data "aws_eks_addon_version" "this" {
  for_each = toset(local.eks_addons)

  addon_name         = each.key
  kubernetes_version = module.eks.cluster_version
}

resource "aws_eks_addon" "this" {
  for_each = toset(local.eks_addons)

  cluster_name                = module.eks.cluster_name
  addon_name                  = each.key
  addon_version               = data.aws_eks_addon_version.this[each.key].version
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"

  depends_on = [
    kubernetes_manifest.nodepool_default
  ]

  timeouts {
    create = "5m"
  }
}

# EBS CSI 드라이버를 사용하는 스토리지 클래스
resource "kubernetes_storage_class" "ebs_sc" {
  # EBS CSI 드라이버가 EKS Addon을 통해서 생성될 경우
  count = contains(local.eks_addons, "aws-ebs-csi-driver") ? 1 : 0

  metadata {
    name = "ebs-sc"
    annotations = {
      "storageclass.kubernetes.io/is-default-class" : "true"
    }
  }
  storage_provisioner = "ebs.csi.aws.com"
  volume_binding_mode = "WaitForFirstConsumer"
  parameters = {
    type      = "gp3"
    encrypted = "true"
  }
}

# 기본값으로 생성된 스토리지 클래스 해제
resource "kubernetes_annotations" "default_storageclass" {
  count = contains(local.eks_addons, "aws-ebs-csi-driver") ? 1 : 0

  api_version = "storage.k8s.io/v1"
  kind        = "StorageClass"
  force       = "true"

  metadata {
    name = "gp2"
  }
  annotations = {
    "storageclass.kubernetes.io/is-default-class" = "false"
  }

  depends_on = [
    kubernetes_storage_class.ebs_sc
  ]
}

/* 필수 라이브러리 */
# AWS Load Balancer Controller에 부여할 IAM 역할 및 Pod Identity Association
module "aws_load_balancer_controller_pod_identity" {
  source  = "terraform-aws-modules/eks-pod-identity/aws"
  version = "1.4.0"

  name = "aws-load-balancer-controller"

  attach_aws_lb_controller_policy = true

  associations = {
    (module.eks.cluster_name) = {
      cluster_name    = module.eks.cluster_name
      namespace       = "kube-system"
      service_account = "aws-load-balancer-controller"
    }
  }

  tags = {
    app = "aws-load-balancer-controller"
  }
}

# AWS Load Balancer Controller
resource "helm_release" "aws_load_balancer_controller" {
  name       = "aws-load-balancer-controller"
  repository = "https://aws.github.io/eks-charts"
  chart      = "aws-load-balancer-controller"
  version    = var.aws_load_balancer_controller_chart_version
  namespace  = "kube-system"

  values = [
    <<-EOT
    clusterName: ${module.eks.cluster_name}
    vpcId: ${module.vpc.vpc_id}
    replicaCount: 1
    serviceAccount:
      create: true
      annotations:
        eks.amazonaws.com/role-arn: ${module.aws_load_balancer_controller_pod_identity.iam_role_arn}
    EOT
  ]

  depends_on = [
    kubernetes_manifest.nodepool_default,
    module.aws_load_balancer_controller_pod_identity
  ]
}

# Metrics Server
resource "helm_release" "metrics_server" {
  name       = "metrics-server"
  repository = "https://kubernetes-sigs.github.io/metrics-server"
  chart      = "metrics-server"
  version    = var.metrics_server_chart_version
  namespace  = "kube-system"

  depends_on = [
    helm_release.aws_load_balancer_controller
  ]
}

# ExternalDNS에 부여할 IAM 역할 및 Pod Identity Association
module "external_dns_pod_identity" {
  source  = "terraform-aws-modules/eks-pod-identity/aws"
  version = "1.4.0"

  name = "external-dns"

  attach_external_dns_policy = true
  external_dns_hosted_zone_arns = [
    aws_route53_zone.this.arn
  ]

  associations = {
    (module.eks.cluster_name) = {
      cluster_name    = module.eks.cluster_name
      namespace       = "kube-system"
      service_account = "external-dns"
    }
  }

  tags = {
    app = "external-dns"
  }
}

# ExternalDNS
resource "helm_release" "external_dns" {
  name       = "external-dns"
  repository = "https://kubernetes-sigs.github.io/external-dns"
  chart      = "external-dns"
  version    = var.external_dns_chart_version
  namespace  = "kube-system"

  values = [
    <<-EOT
    serviceAccount:
      create: true
      annotations:
        eks.amazonaws.com/role-arn: ${module.external_dns_pod_identity.iam_role_arn}
    txtOwnerId: ${module.eks.cluster_name}
    policy: sync
    resources:
      requests:
        memory: 100Mi
    EOT
  ]

  depends_on = [
    helm_release.aws_load_balancer_controller
  ]
}

# Ingress NGINX를 설치할 네임스페이스
resource "kubernetes_namespace" "ingress_nginx" {
  metadata {
    name = "ingress-nginx"
  }
}

# Ingress NGINX
resource "helm_release" "ingress_nginx" {
  name       = "ingress-nginx"
  repository = "https://kubernetes.github.io/ingress-nginx"
  chart      = "ingress-nginx"
  version    = var.ingress_nginx_chart_version
  namespace  = kubernetes_namespace.ingress_nginx.metadata[0].name

  values = [
    templatefile("${path.module}/helm-values/ingress-nginx.yaml", {
      lb_acm_certificate_arn = aws_acm_certificate_validation.this.certificate_arn
    })
  ]

  depends_on = [
    helm_release.aws_load_balancer_controller,
    aws_eks_addon.this
  ]
}