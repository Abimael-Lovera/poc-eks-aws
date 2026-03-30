# EBS CSI Driver - Persistent storage for EKS
# Deployed as Helm chart to avoid circular dependency with IRSA

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
  default = "kube-system"
}

variable "chart_version" {
  type    = string
  default = "2.28.0"
}

variable "tags" {
  type    = map(string)
  default = {}
}

resource "helm_release" "ebs_csi" {
  name       = "aws-ebs-csi-driver"
  repository = "https://kubernetes-sigs.github.io/aws-ebs-csi-driver"
  chart      = "aws-ebs-csi-driver"
  version    = var.chart_version
  namespace  = var.namespace

  values = [yamlencode({
    controller = {
      serviceAccount = {
        create = true
        name   = "ebs-csi-controller-sa"
        annotations = {
          "eks.amazonaws.com/role-arn" = var.iam_role_arn
        }
      }
    }
  })]
}

output "namespace" {
  value = var.namespace
}

output "release_name" {
  value = helm_release.ebs_csi.name
}
