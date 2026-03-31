# Bastion Host Module - EC2 instance for EKS cluster management
# Uses Session Manager for secure access (no SSH keys required)
#
# This module ONLY creates the EC2 instance.
# IAM role/instance profile and security groups must be provided as inputs.

terraform {
  required_version = ">= 1.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.0"
    }
  }
}

data "aws_ami" "amazon_linux_2023" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["al2023-ami-*-x86_64"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

# Bastion Host EC2 Instance
resource "aws_instance" "bastion" {
  ami           = var.ami_id != null ? var.ami_id : data.aws_ami.amazon_linux_2023.id
  instance_type = var.instance_type

  subnet_id                   = var.subnet_id
  vpc_security_group_ids      = var.security_group_ids
  iam_instance_profile        = var.iam_instance_profile_name
  associate_public_ip_address = var.associate_public_ip
  key_name                    = var.key_name

  root_block_device {
    volume_type           = "gp3"
    volume_size           = var.root_volume_size
    encrypted             = true
    delete_on_termination = true
  }

  user_data = base64encode(<<-EOF
    #!/bin/bash
    set -e
    
    # Enable and start SSM agent (ensure it's running for Session Manager)
    systemctl enable amazon-ssm-agent
    systemctl start amazon-ssm-agent
    
    # Update system
    dnf update -y
    
    # Install kubectl
    curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
    chmod +x kubectl
    mv kubectl /usr/local/bin/
    
    # Install Helm
    curl -fsSL -o get_helm.sh https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3
    chmod 700 get_helm.sh
    ./get_helm.sh
    rm get_helm.sh
    
    # Install AWS CLI v2 (already installed on AL2023)
    
    # Create kubectl config directory for ssm-user and ec2-user
    mkdir -p /home/ssm-user/.kube
    chown -R ssm-user:ssm-user /home/ssm-user
    mkdir -p /home/ec2-user/.kube
    chown -R ec2-user:ec2-user /home/ec2-user
    
    echo "Bastion setup complete!"
  EOF
  )

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required" # IMDSv2
    http_put_response_hop_limit = 1
  }

  tags = merge(
    var.tags,
    {
      Name = "${var.name}-bastion"
    }
  )

  lifecycle {
    ignore_changes = [ami]
  }
}
