terraform {
  backend "s3" {
    bucket         = "poc-eks-terraform-state"
    key            = "dev/terraform.tfstate"
    region         = "us-east-1"
    encrypt        = true
    dynamodb_table = "poc-eks-terraform-locks"
  }
}
