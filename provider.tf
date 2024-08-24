# 요구되는 테라폼 제공자 목록
terraform {
  required_version = "1.9.4"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "5.62.0"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "2.31.0"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "2.14.1"
    }
    random = {
      source  = "hashicorp/random"
      version = "3.6.2"
    }
    htpasswd = {
      source  = "loafoe/htpasswd"
      version = "1.0.4"
    }
    # opensearch = {
    #   source  = "opensearch-project/opensearch"
    #   version = "2.3.0"
    # }
  }
}

# AWS 제공자 설정
provider "aws" {
  region = "ap-northeast-2"

  # 해당 테라폼 모듈을 통해서 생성되는 모든 AWS 리소스에 아래의 태그 부여
  default_tags {
    tags = local.tags
  }
}

provider "aws" {
  alias = "youngwjung"

  assume_role {
    role_arn = "arn:aws:iam::491818659652:role/CrossRoute53Role"
  }
}

# Kubernetes 제공자 설정
provider "kubernetes" {
  host                   = module.eks.cluster_endpoint
  cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)
  token                  = data.aws_eks_cluster_auth.this.token
}

# Helm 제공자 설정
provider "helm" {
  kubernetes {
    host                   = module.eks.cluster_endpoint
    cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)
    token                  = data.aws_eks_cluster_auth.this.token
  }
}

# # Opensearch 제공자
# provider "opensearch" {
#   url               = "https://${module.opensearch_log.domain_endpoint}"
#   username          = "admin"
#   password          = "Asdf!234"
#   sign_aws_requests = false
# }