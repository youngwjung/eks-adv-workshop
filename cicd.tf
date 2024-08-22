# GitLab을 설치할 네임스페이스
resource "kubernetes_namespace" "gitlab" {
  metadata {
    name = "gitlab"
  }
}

# GitLab
resource "helm_release" "gitlab" {
  name       = "gitlab"
  repository = "https://charts.gitlab.io"
  chart      = "gitlab"
  version    = var.gitlab_chart_version
  namespace  = kubernetes_namespace.gitlab.metadata[0].name

  values = [
    templatefile("${path.module}/helm-values/gitlab.yaml", {
      domain = aws_route53_zone.this.name
    })
  ]

  depends_on = [
    helm_release.ingress_nginx
  ]
}

# GitLab URL
data "kubernetes_ingress_v1" "gitlab" {
  metadata {
    name      = "${helm_release.gitlab.name}-webservice-default"
    namespace = kubernetes_namespace.gitlab.metadata[0].name
  }

  depends_on = [
    helm_release.gitlab
  ]
}

# GitLab 어드민 유저 비밀번호
data "kubernetes_secret_v1" "gitlab" {
  metadata {
    name      = "${helm_release.gitlab.name}-gitlab-initial-root-password"
    namespace = kubernetes_namespace.gitlab.metadata[0].name
  }

  depends_on = [
    helm_release.gitlab
  ]
}

# ECR 리포지토리
module "ecr" {
  source  = "terraform-aws-modules/ecr/aws"
  version = "2.2.1"

  repository_name                 = "nginx"
  repository_image_tag_mutability = "MUTABLE"

  repository_lifecycle_policy = jsonencode({
    rules = [
      {
        rulePriority = 1,
        description  = "Expire untagged images",
        selection = {
          tagStatus   = "untagged",
          countType   = "imageCountMoreThan",
          countNumber = 3
        },
        action = {
          type = "expire"
        }
      }
    ]
  })

  repository_force_delete = true
}

# GitLab에 있는 리포지토리와 연결
resource "aws_codestarconnections_host" "this" {
  name              = "gitlab"
  provider_endpoint = "https://${data.kubernetes_ingress_v1.gitlab.spec.0.rule.0.host}"
  provider_type     = "GitLabSelfManaged"
}

resource "aws_codestarconnections_connection" "this" {
  name     = "gitlab"
  host_arn = aws_codestarconnections_host.this.arn
}

# 코드 파이프라인에서 사용할 버킷
resource "aws_s3_bucket" "codepipeline" {
  bucket = "${random_string.domain_prefix.result}-codepipeline-storage"

  force_destroy = true
}

# 코드 파이프라인에서 사용할 IAM 역할
resource "aws_iam_policy" "codepipeline" {
  name = "codepipeline-policy"

  policy = <<-POLICY
    {
      "Version": "2012-10-17",
      "Statement": [
        {
          "Action": [
            "s3:*",
            "codestar-connections:UseConnection",
            "codebuild:*"
          ],
          "Effect": "Allow",
          "Resource": "*"
        }
      ]
    }
  POLICY
}

resource "aws_iam_role" "codepipeline" {
  name = "ezl-codepipeline-service-role"
  path = "/service-role/"

  managed_policy_arns = [aws_iam_policy.codepipeline.arn]

  assume_role_policy = <<-POLICY
    {
      "Version": "2012-10-17",
      "Statement": [
        {
          "Action": "sts:AssumeRole",
          "Effect": "Allow",
          "Principal": {
            "Service": "codepipeline.amazonaws.com"
          }
        }
      ]
    }
  POLICY
}

# 코드 빌드에서 사용할 IAM 역할
resource "aws_iam_policy" "codebuild" {
  name = "ezl-codebuild-policy"

  policy = <<-POLICY
    {
      "Version": "2012-10-17",
      "Statement": [
        {
          "Sid": "CloudWatchLogsPolicy",
          "Effect": "Allow",
          "Action": [
            "logs:CreateLogGroup",
            "logs:CreateLogStream",
            "logs:PutLogEvents"
          ],
          "Resource": "*"
        },
        {
          "Sid": "CodeStartPolicy",
          "Effect": "Allow",
          "Action": [
            "codestar-connections:UseConnection"
          ],
          "Resource": "*"
        },
        {
          "Sid": "S3GetObjectPolicy",
          "Effect": "Allow",
          "Action": [
            "s3:GetObject",
            "s3:GetObjectVersion"
          ],
          "Resource": "*"
        },
        {
          "Sid": "S3PutObjectPolicy",
          "Effect": "Allow",
          "Action": [
            "s3:PutObject"
          ],
          "Resource": "*"
        },
        {
          "Sid": "ECRPolicy",
          "Effect": "Allow",
          "Action": [
            "ecr:GetDownloadUrlForLayer",
            "ecr:BatchGetImage",
            "ecr:BatchCheckLayerAvailability",
            "ecr:CompleteLayerUpload",
            "ecr:GetAuthorizationToken",
            "ecr:InitiateLayerUpload",
            "ecr:PutImage",
            "ecr:DescribeImages",
            "ecr:UploadLayerPart"
          ],
          "Resource": "*"
        },
        {
          "Sid": "S3BucketIdentity",
          "Effect": "Allow",
          "Action": [
            "s3:GetBucketAcl",
            "s3:GetBucketLocation"
          ],
          "Resource": "*"
        },
        {
          "Sid": "CodePipelinePolicy",
          "Effect": "Allow",
          "Action": [
            "codepipeline:ListPipelineExecutions"
          ],
          "Resource": "*"
        }
      ]
    }
  POLICY
}

resource "aws_iam_role" "codebuild" {
  name = "ezl-codebuild-service-role"
  path = "/service-role/"

  managed_policy_arns = [aws_iam_policy.codebuild.arn]

  assume_role_policy = <<-POLICY
    {
      "Version": "2012-10-17",
      "Statement": [
        {
          "Effect": "Allow",
          "Principal": {
            "Service": "codebuild.amazonaws.com"
          },
          "Action": "sts:AssumeRole"
        }
      ]
    }
  POLICY

  lifecycle {
    ignore_changes = [
      # 자동으로 추가되는 정책 삭제 방지
      managed_policy_arns
    ]
  }
}

# 코드 빌드 로그를 저장할 로그 그룹
resource "aws_cloudwatch_log_group" "this" {
  name              = "/aws/codebuild/nginx"
  retention_in_days = 7
}

# 코드 빌드 프로젝트
resource "aws_codebuild_project" "this" {
  name         = "nginx"
  service_role = aws_iam_role.codebuild.arn

  artifacts {
    type = "NO_ARTIFACTS"
  }

  environment {
    compute_type    = "BUILD_GENERAL1_SMALL"
    image           = "aws/codebuild/standard:5.0"
    privileged_mode = "true"
    type            = "LINUX_CONTAINER"
  }

  logs_config {
    cloudwatch_logs {
      status     = "ENABLED"
      group_name = aws_cloudwatch_log_group.this.name
    }
  }

  source {
    type      = "GITLAB_SELF_MANAGED"
    location  = "https://${data.kubernetes_ingress_v1.gitlab.spec.0.rule.0.host}/root/nginx.git"
    buildspec = file("${path.module}/buildspec/nginx.yaml")
  }
}

# CodePipeline
resource "aws_codepipeline" "this" {
  name          = "nginx"
  pipeline_type = "V2"
  role_arn      = aws_iam_role.codepipeline.arn

  artifact_store {
    type     = "S3"
    location = aws_s3_bucket.codepipeline.bucket
  }

  stage {
    name = "Source"

    action {
      name             = "Source"
      category         = "Source"
      owner            = "AWS"
      provider         = "CodeStarSourceConnection"
      version          = "1"
      namespace        = "SourceVariables"
      output_artifacts = ["SourceArtifact"]

      configuration = {
        ConnectionArn        = aws_codestarconnections_connection.this.arn
        FullRepositoryId     = "root/nginx"
        BranchName           = "main"
        OutputArtifactFormat = "CODEBUILD_CLONE_REF"
      }
    }
  }

  stage {
    name = "Build"

    action {
      category = "Build"

      configuration = {
        ProjectName = aws_codebuild_project.this.name
        EnvironmentVariables = jsonencode([
          {
            name  = "AUTHOR_EMAIL"
            value = "#{SourceVariables.AuthorEmail}"
            type  = "PLAINTEXT"
          },
          {
            name  = "AUTHOR_ID"
            value = "#{SourceVariables.AuthorId}"
            type  = "PLAINTEXT"
          },
          {
            name  = "FULL_REPOSITORY_NAME"
            value = "#{SourceVariables.FullRepositoryName}"
            type  = "PLAINTEXT"
          },
          {
            name  = "ECR_REPO"
            value = module.ecr.repository_url
            type  = "PLAINTEXT"
          },
          {
            name  = "HELM_CHART_URL"
            value = "${data.kubernetes_ingress_v1.gitlab.spec.0.rule.0.host}/root/helm-charts.git"
            type  = "PLAINTEXT"
          },
          {
            name  = "GITLAB_ROOT_PASSWORD"
            value = data.kubernetes_secret_v1.gitlab.data["password"]
            type  = "PLAINTEXT"
          },
        ])
      }

      input_artifacts  = ["SourceArtifact"]
      name             = "Build"
      namespace        = "BuildVariables"
      output_artifacts = ["BuildArtifact"]
      owner            = "AWS"
      provider         = "CodeBuild"
      version          = "1"
    }
  }

  trigger {
    provider_type = "CodeStarSourceConnection"

    git_configuration {
      source_action_name = "Source"
      push {
        branches {
          includes = ["main"]
        }
      }
    }
  }
}

# Argo CD를 설치할 네임스페이스
resource "kubernetes_namespace" "argocd" {
  metadata {
    name = "argocd"
  }
}

# Argo CD 어드민 비밀번호의 bcrypt hash 생성
resource "htpasswd_password" "argocd" {
  password = "Asdf!234"
}

# Argo CD
resource "helm_release" "argocd" {
  name       = "argocd"
  repository = "https://argoproj.github.io/argo-helm"
  chart      = "argo-cd"
  version    = var.argocd_chart_version
  namespace  = kubernetes_namespace.argocd.metadata[0].name

  values = [
    templatefile("${path.module}/helm-values/argocd.yaml", {
      domain                = "argocd.${aws_route53_zone.this.name}"
      server_admin_password = htpasswd_password.argocd.bcrypt
    })
  ]

  depends_on = [
    helm_release.ingress_nginx
  ]
}

# GitLab URL
data "kubernetes_ingress_v1" "argocd" {
  metadata {
    name      = "${helm_release.argocd.name}-server"
    namespace = kubernetes_namespace.argocd.metadata[0].name
  }

  depends_on = [
    helm_release.argocd
  ]
}

# GitLab 리포지토리 인증 정보
resource "kubernetes_secret_v1" "gitlab_root_cred" {
  metadata {
    name      = "gitlab"
    namespace = kubernetes_namespace.argocd.metadata[0].name
    labels = {
      "argocd.argoproj.io/secret-type" = "repo-creds"
    }
  }

  data = {
    type     = "git"
    url      = "https://${data.kubernetes_ingress_v1.gitlab.spec.0.rule.0.host}"
    username = "root"
    password = data.kubernetes_secret_v1.gitlab.data["password"]
  }

  depends_on = [
    helm_release.argocd
  ]
}

# Helm 차트 리포지토리
resource "kubernetes_secret_v1" "helm_repo" {
  metadata {
    name      = "helm-charts"
    namespace = kubernetes_namespace.argocd.metadata[0].name
    labels = {
      "argocd.argoproj.io/secret-type" = "repository"
    }
  }

  data = {
    type = "git"
    url  = "https://${data.kubernetes_ingress_v1.gitlab.spec.0.rule.0.host}/root/helm-charts.git"
  }

  depends_on = [
    helm_release.argocd
  ]
}

# Argo CD에 프로젝트 생성
resource "kubernetes_manifest" "argocd_project" {
  manifest = {
    apiVersion = "argoproj.io/v1alpha1"
    kind       = "AppProject"

    metadata = {
      name      = "dev"
      namespace = kubernetes_namespace.argocd.metadata[0].name
      # 해당 프로젝트에 속한 애플리케이션이 존재할 경우 삭제 방지
      finalizers = [
        "resources-finalizer.argocd.argoproj.io"
      ]
    }

    spec = {
      description = "Dev 환경"
      sourceRepos = ["*"]
      destinations = [
        {
          name      = "*"
          server    = "*"
          namespace = "*"
        }
      ]
      clusterResourceWhitelist = [
        {
          group = "*"
          kind  = "*"
        }
      ]
    }
  }

  depends_on = [
    helm_release.argocd
  ]
}

# Argo CD 애플리케이션 생성
resource "kubernetes_manifest" "argocd_app" {
  manifest = {
    apiVersion = "argoproj.io/v1alpha1"
    kind       = "Application"

    metadata = {
      name      = "nginx"
      namespace = kubernetes_namespace.argocd.metadata[0].name
      finalizers = [
        "resources-finalizer.argocd.argoproj.io"
      ]
    }

    spec = {
      project = kubernetes_manifest.argocd_project.manifest.metadata.name

      source = {
        repoURL        = "https://${data.kubernetes_ingress_v1.gitlab.spec.0.rule.0.host}/root/helm-charts.git"
        targetRevision = "HEAD"
        path           = "nginx"
        helm = {
          releaseName = "nginx"
          valueFiles = [
            "values_dev.yaml"
          ]
        }
      }

      destination = {
        name      = "in-cluster"
        namespace = "app"
      }

      syncPolicy = {
        syncOptions = ["CreateNamespace=true"]
        automated   = {}
      }
    }
  }

  depends_on = [
    helm_release.argocd
  ]
}