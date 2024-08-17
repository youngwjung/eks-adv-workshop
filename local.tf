# 로컬 환경변수 지정
locals {
  project = "eks-workshop"
}

# 태그
locals {
  tags = {
    Project = local.project
  }
}