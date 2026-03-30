# ALB Controller Addon - Helm chart only
# IAM role ARN is passed from the environment's IAM module

terraform {
  required_providers {
    helm = {
      source  = "hashicorp/helm"
      version = ">= 2.0"
    }
  }
}

variable "cluster_name" {
  type = string
}

variable "cluster_endpoint" {
  type = string
}

variable "vpc_id" {
  type = string
}

variable "region" {
  type = string
}

variable "iam_role_arn" {
  type = string
}

variable "chart_version" {
  type    = string
  default = "1.7.1"
}

variable "default_target_type" {
  type    = string
  default = "instance"
}

resource "helm_release" "alb_controller" {
  name       = "aws-load-balancer-controller"
  repository = "https://aws.github.io/eks-charts"
  chart      = "aws-load-balancer-controller"
  version    = var.chart_version
  namespace  = "kube-system"

  values = [yamlencode({
    clusterName = var.cluster_name
    serviceAccount = {
      create = true
      name   = "aws-load-balancer-controller"
      annotations = {
        "eks.amazonaws.com/role-arn" = var.iam_role_arn
      }
    }
    region                      = var.region
    vpcId                       = var.vpc_id
    defaultTargetType           = var.default_target_type
    enableServiceMutatorWebhook = false
  })]
}

output "release_name" {
  value = helm_release.alb_controller.name
}
