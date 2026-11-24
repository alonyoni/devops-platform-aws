terraform {
  backend "s3" {
    bucket         = "devops-platform-terraform-state"
    key            = "terraform.tfstate"
    region         = "us-east-1"
    encrypt        = true
    dynamodb_table = "devops-platform-terraform-locks"
  }
}
