variable "vpc_cidr" {
  description = "VPC 대역대"
  type        = string
  default     = "10.0.0.0/16"
}

variable "eks_cluster_version" {
  description = "EKS 클러스터 버전"
  type        = string
}

variable "karpenter_chart_version" {
  description = "Karpenter Helm 차트 버전"
  type        = string
}

variable "aws_load_balancer_controller_chart_version" {
  description = "AWS Load Balancer Controller Helm 차트 버전"
  type        = string
}

variable "metrics_server_chart_version" {
  description = "Kubernetes Metrics Server Helm 차트 버전"
  type        = string
}

variable "external_dns_chart_version" {
  description = "Kubernetes ExternalDNS Helm 차트 버전"
  type        = string
}

variable "ingress_nginx_chart_version" {
  description = "Ingess-nginx Controller Helm 차트 버전 "
  type        = string
}

variable "gitlab_chart_version" {
  description = "GitLab Helm 차트 버전 "
  type        = string
}

variable "argocd_chart_version" {
  description = "ArgoCD Helm 차트 버전 "
  type        = string
}

variable "keda_chart_version" {
  description = "Keda Helm 차트 버전 "
  type        = string
}

variable "kube_prometheus_stack_chart_version" {
  description = "Kube-prometheus-stack Helm 차트 버전 "
  type        = string
}

variable "thanos_chart_version" {
  description = "Thanos Helm 차트 버전 "
  type        = string
}

variable "alert_slack_channel" {
  description = "경보를 수신할 슬랙 채널"
  type        = string
}

variable "alert_slack_webhook_url" {
  description = "슬랙 메세지를 전송할 Webhook URL"
  type        = string
}

variable "fluentbit_chart_version" {
  description = "Fluent Bit Helm 차트 버전 "
  type        = string
}