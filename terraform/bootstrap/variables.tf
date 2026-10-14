variable "region" {
  type    = string
  default = "us-east-1"
}

variable "monthly_budget_usd" {
  description = "Account-wide monthly cost budget; alerts at 80% actual and 100% forecast."
  type        = number
  default     = 50
}

variable "alert_email" {
  description = "Budget alert recipient. Set in terraform.tfvars (gitignored)."
  type        = string
  validation {
    condition     = can(regex("^[^@\\s]+@[^@\\s]+\\.[^@\\s]+$", var.alert_email))
    error_message = "alert_email must be an email address."
  }
}
