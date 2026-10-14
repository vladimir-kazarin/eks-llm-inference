terraform {
  required_version = ">= 1.10"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.69"
    }
  }
}

provider "aws" {
  region = var.region
  default_tags {
    tags = {
      project    = "eks-llm-inference"
      managed-by = "terraform"
    }
  }
}
