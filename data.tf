# 현재 설정된 AWS 리전 정보 불러오기
data "aws_region" "current" {}

# 현재 설정된 AWS 리전에 있는 가용영역 정보 불러오기
data "aws_availability_zones" "azs" {}

# AWS 자격증명 정보
data "aws_caller_identity" "current" {}

# EKS 클러스터 인증 토큰
data "aws_eks_cluster_auth" "this" {
  name = module.eks.cluster_name

  depends_on = [
    module.eks.fargate_profiles
  ]
}

# Route53 호스트존
data "aws_route53_zone" "youngwjung" {
  provider = aws.youngwjung

  name = "youngwjung.com."
}