variable "region" {
  description = "AWS region for every resource in this project."
  type        = string
  default     = "us-east-1"
}

variable "project" {
  description = "Name prefix for every resource."
  type        = string
  default     = "fleet-lab"
}

# ---------- Network ----------

variable "vpc_cidr" {
  description = "CIDR for the fleet VPC. Must not overlap the home LAN."
  type        = string
  default     = "10.60.0.0/16"
}

variable "public_subnet_cidr" {
  description = "CIDR for the single public subnet."
  type        = string
  default     = "10.60.0.0/20"
}

# ---------- EC2 ----------

variable "linux_instance_type" {
  description = "Instance type for the Ubuntu node."
  type        = string
  default     = "t3.micro"
}

variable "windows_instance_type" {
  description = "Instance type for the Windows node. t3.micro (1 GiB) is too small for Windows patching."
  type        = string
  default     = "t3.small"
}

variable "windows_key_name" {
  description = "Existing EC2 key pair used only to decrypt the Windows Administrator password. Created in the console, not managed here, so the private key never lands in Terraform state."
  type        = string
  default     = "fleet-lab-win-key"
}

# ---------- Operations ----------

variable "association_schedule" {
  description = "How often State Manager re-checks config and rescans patches. Daily in the lab to limit hybrid pay-as-you-go cost; production would use rate(30 minutes) for config rules."
  type        = string
  default     = "rate(1 day)"
}

variable "patch_window_schedule" {
  description = "When the patch window opens. Sunday 2 AM."
  type        = string
  default     = "cron(0 2 ? * SUN *)"
}

variable "patch_window_timezone" {
  description = "IANA time zone for the patch window schedule."
  type        = string
  default     = "America/Chicago"
}

variable "patch_window_enabled" {
  description = "Turn the weekly patch window on. Off by default in the lab so it doesn't reboot the homelab VMs every Sunday."
  type        = bool
  default     = false
}

variable "log_retention_days" {
  description = "Days before session, command and patch logs expire from S3."
  type        = number
  default     = 30
}

# ---------- Cost guardrail ----------

variable "budget_limit_usd" {
  description = "Monthly budget alert threshold in USD."
  type        = string
  default     = "5"
}

variable "budget_email" {
  description = "Email address for budget alerts. Set in terraform.tfvars (git-ignored)."
  type        = string
}
