# VPC
module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "5.12.1"

  name = local.project
  cidr = var.vpc_cidr

  # 서브넷
  azs             = data.aws_availability_zones.azs.names
  public_subnets  = [for idx, _ in data.aws_availability_zones.azs.names : cidrsubnet(var.vpc_cidr, 8, idx)]
  private_subnets = [for idx, _ in data.aws_availability_zones.azs.names : cidrsubnet(var.vpc_cidr, 8, idx + 10)]

  # NAT 게이트웨이
  enable_nat_gateway = true
  single_nat_gateway = true

  # 외부 접근용 ALB/NLB를 생성할 서브넷에요구되는 태그
  public_subnet_tags = {
    "kubernetes.io/role/elb" = 1
  }

  private_subnet_tags = {
    # VPC 내부용 ALB/NLB를 생성할 서브넷에 요구되는 태그
    "kubernetes.io/role/internal-elb" = 1
    # Karpenter가 노드를 생성할 서브넷에 요구되는 태그
    "karpenter.sh/discovery" = local.project
  }
}

# Route53 호스트존
resource "random_string" "domain_prefix" {
  length  = 16
  upper   = false
  numeric = false
  special = false
}

resource "aws_route53_zone" "this" {
  name = "${random_string.domain_prefix.result}.youngwjung.com"

  force_destroy = true
}

resource "aws_route53_record" "ns" {
  provider = aws.youngwjung

  zone_id = data.aws_route53_zone.youngwjung.zone_id
  name    = aws_route53_zone.this.name
  type    = "NS"
  ttl     = "60"
  records = aws_route53_zone.this.name_servers
}

# ACM 인증서 발급 요청
resource "aws_acm_certificate" "this" {
  domain_name       = "*.${aws_route53_zone.this.name}"
  validation_method = "DNS"

  lifecycle {
    create_before_destroy = true
  }
}

# 위에서 생성한 ACM 인증서 검증하는 DNS 레코드 생성
resource "aws_route53_record" "acm_validation" {
  for_each = {
    for dvo in aws_acm_certificate.this.domain_validation_options : dvo.domain_name => {
      name   = dvo.resource_record_name
      record = dvo.resource_record_value
      type   = dvo.resource_record_type
    }
  }

  allow_overwrite = true
  name            = each.value.name
  records         = [each.value.record]
  ttl             = 60
  type            = each.value.type
  zone_id         = aws_route53_zone.this.zone_id
}

# 인증서 발급 상태
resource "aws_acm_certificate_validation" "this" {
  certificate_arn         = aws_acm_certificate.this.arn
  validation_record_fqdns = [for record in aws_route53_record.acm_validation : record.fqdn]
}