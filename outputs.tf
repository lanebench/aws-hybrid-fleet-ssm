output "vpc_id" {
  description = "Fleet VPC."
  value       = aws_vpc.main.id
}

output "logs_bucket" {
  description = "Bucket holding session transcripts (sessions/), Run Command output (run-command/), association output (state-manager/) and patch output (patching/)."
  value       = aws_s3_bucket.logs.id
}

output "linux_launch_template" {
  description = "Launch this to bring up fleet-lab-lnx01."
  value       = aws_launch_template.linux.name
}

output "windows_launch_template" {
  description = "Launch this to bring up fleet-lab-win01."
  value       = aws_launch_template.windows.name
}

output "hybrid_role_name" {
  description = "Role to select when creating a hybrid activation for a new on-prem server."
  value       = aws_iam_role.hybrid.name
}

output "default_patch_baselines" {
  description = "Custom baselines now registered as the account defaults."
  value = {
    windows = aws_ssm_patch_baseline.windows.id
    ubuntu  = aws_ssm_patch_baseline.ubuntu.id
  }
}

output "patch_window" {
  description = "Weekly patch window and whether it is enabled."
  value = {
    id       = aws_ssm_maintenance_window.patch.id
    schedule = "${var.patch_window_schedule} ${var.patch_window_timezone}"
    enabled  = var.patch_window_enabled
  }
}
