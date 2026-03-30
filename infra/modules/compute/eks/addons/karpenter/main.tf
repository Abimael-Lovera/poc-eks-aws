# Karpenter Addon - Helm + SQS + EventBridge
# IAM role ARNs are passed from the environment's IAM modules

terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.0"
    }
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

variable "cluster_certificate_authority" {
  type = string
}

variable "controller_iam_role_arn" {
  type = string
}

variable "node_iam_role_name" {
  type = string
}

variable "chart_version" {
  type    = string
  default = "1.0.1"
}

variable "tags" {
  type    = map(string)
  default = {}
}

# SQS Queue for spot interruption handling
resource "aws_sqs_queue" "karpenter" {
  name                      = "${var.cluster_name}-karpenter"
  message_retention_seconds = 300
  sqs_managed_sse_enabled   = true
  tags                      = var.tags
}

resource "aws_sqs_queue_policy" "karpenter" {
  queue_url = aws_sqs_queue.karpenter.url
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "EC2InterruptionPolicy"
      Effect    = "Allow"
      Principal = { Service = ["events.amazonaws.com", "sqs.amazonaws.com"] }
      Action    = "sqs:SendMessage"
      Resource  = aws_sqs_queue.karpenter.arn
    }]
  })
}

# EventBridge rules for spot interruption
resource "aws_cloudwatch_event_rule" "spot_interruption" {
  name        = "${var.cluster_name}-karpenter-spot-interruption"
  description = "Karpenter spot instance interruption warning"
  event_pattern = jsonencode({
    source      = ["aws.ec2"]
    detail-type = ["EC2 Spot Instance Interruption Warning"]
  })
  tags = var.tags
}

resource "aws_cloudwatch_event_target" "spot_interruption" {
  rule      = aws_cloudwatch_event_rule.spot_interruption.name
  target_id = "KarpenterSpotInterruption"
  arn       = aws_sqs_queue.karpenter.arn
}

resource "aws_cloudwatch_event_rule" "instance_rebalance" {
  name        = "${var.cluster_name}-karpenter-instance-rebalance"
  description = "Karpenter instance rebalance recommendation"
  event_pattern = jsonencode({
    source      = ["aws.ec2"]
    detail-type = ["EC2 Instance Rebalance Recommendation"]
  })
  tags = var.tags
}

resource "aws_cloudwatch_event_target" "instance_rebalance" {
  rule      = aws_cloudwatch_event_rule.instance_rebalance.name
  target_id = "KarpenterInstanceRebalance"
  arn       = aws_sqs_queue.karpenter.arn
}

resource "aws_cloudwatch_event_rule" "instance_state_change" {
  name        = "${var.cluster_name}-karpenter-instance-state"
  description = "Karpenter instance state change events"
  event_pattern = jsonencode({
    source      = ["aws.ec2"]
    detail-type = ["EC2 Instance State-change Notification"]
  })
  tags = var.tags
}

resource "aws_cloudwatch_event_target" "instance_state_change" {
  rule      = aws_cloudwatch_event_rule.instance_state_change.name
  target_id = "KarpenterInstanceState"
  arn       = aws_sqs_queue.karpenter.arn
}

# Helm release
resource "helm_release" "karpenter" {
  name             = "karpenter"
  repository       = "oci://public.ecr.aws/karpenter"
  chart            = "karpenter"
  version          = var.chart_version
  namespace        = "karpenter"
  create_namespace = true

  values = [yamlencode({
    settings = {
      clusterName       = var.cluster_name
      clusterEndpoint   = var.cluster_endpoint
      interruptionQueue = aws_sqs_queue.karpenter.name
    }
    serviceAccount = {
      annotations = {
        "eks.amazonaws.com/role-arn" = var.controller_iam_role_arn
      }
    }
    controller = {
      resources = {
        requests = { cpu = "100m", memory = "256Mi" }
        limits   = { cpu = "1", memory = "1Gi" }
      }
    }
  })]

  depends_on = [aws_sqs_queue.karpenter]
}

output "queue_name" {
  value = aws_sqs_queue.karpenter.name
}

output "queue_arn" {
  value = aws_sqs_queue.karpenter.arn
}
