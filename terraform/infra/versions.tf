terraform {
  required_version = ">= 1.10"

  # bucket/region passed via -backend-config by scripts/up.sh (keeps account id out of git)
  backend "s3" {
    key          = "infra/terraform.tfstate"
    use_lockfile = true
    encrypt      = true
  }

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.69"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 3.3"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 3.3"
    }
  }
}
