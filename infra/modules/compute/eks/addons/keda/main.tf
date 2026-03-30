# KEDA - Kubernetes Event-Driven Autoscaling
# Scales workloads based on external metrics (SQS, CloudWatch, etc.)

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

variable "oidc_provider_arn" {
  type = string
}

variable "iam_role_arn" {
  type = string
}

variable "namespace" {
  type    = string
  default = "keda"
}

variable "chart_version" {
  type    = string
  default = "2.13.0"
}

variable "tags" {
  type    = map(string)
  default = {}
}

resource "helm_release" "keda" {
  name             = "keda"
  repository       = "https://kedacore.github.io/charts"
  chart            = "keda"
  version          = var.chart_version
  namespace        = var.namespace
  create_namespace = true

  values = [yamlencode({
    serviceAccount = {
      create = true
      name   = "keda-operator"
      annotations = {
        "eks.amazonaws.com/role-arn" = var.iam_role_arn
      }
    }

    podIdentity = {
      aws = {
        irsa = {
          enabled = true
        }
      }
    }
  })]
}

output "namespace" {
  value = var.namespace
}

output "release_name" {
  value = helm_release.keda.name
}
