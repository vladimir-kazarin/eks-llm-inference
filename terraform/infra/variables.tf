variable "region" {
  type    = string
  default = "us-east-1"
}

variable "cluster_name" {
  type    = string
  default = "llm-inference"
}

variable "kubernetes_version" {
  type    = string
  default = "1.36"
}

variable "gpu_instance_type" {
  type    = string
  default = "g5.xlarge"
}

variable "allowed_cidrs" {
  description = "CIDRs allowed to reach the EKS API and the inference NLB. scripts/up.sh passes your current IP/32."
  type        = list(string)
  validation {
    condition     = length(var.allowed_cidrs) > 0 && alltrue([for c in var.allowed_cidrs : can(cidrnetmask(c)) && c != "0.0.0.0/0"])
    error_message = "allowed_cidrs must be a non-empty list of valid CIDRs and must not contain 0.0.0.0/0."
  }
}

variable "gitops_repo_url" {
  type    = string
  default = "https://github.com/vladimir-kazarin/eks-llm-inference.git"
}

variable "gitops_revision" {
  type    = string
  default = "main"
}
