terraform {
  backend "s3" {
    # Values provided via -backend-config flag or backend.conf file
    # Run ./scripts/aws-init.sh first to create the bucket and DynamoDB table
    # Then: terraform init -backend-config=../../state/backend.conf
    key = "prod/terraform.tfstate"
  }
}
