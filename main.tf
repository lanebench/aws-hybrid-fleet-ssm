locals {
  name       = var.project
  account_id = data.aws_caller_identity.current.account_id

  # AMI IDs resolved by EC2 at launch time from public SSM parameters,
  # so every launch gets the latest patched image and Terraform never drifts.
  ubuntu_ami  = "resolve:ssm:/aws/service/canonical/ubuntu/server/24.04/stable/current/amd64/hvm/ebs-gp3/ami-id"
  windows_ami = "resolve:ssm:/aws/service/ami-windows-latest/Windows_Server-2022-English-Full-Base"

  linux_ntp_script = <<-EOT
    if [ "$(timedatectl show -p NTP --value)" = "yes" ]; then
      echo "COMPLIANT: NTP sync enabled on $(hostname)"
    else
      timedatectl set-ntp true
      echo "DRIFT CORRECTED: NTP sync re-enabled on $(hostname)"
    fi
  EOT

  windows_firewall_script = <<-EOT
    $off = Get-NetFirewallProfile | Where-Object { $_.Enabled -ne 'True' }
    if (-not $off) {
      "COMPLIANT: firewall on for all profiles on $env:COMPUTERNAME"
    } else {
      $names = $off.Name -join ', '
      Set-NetFirewallProfile -Profile Domain,Private,Public -Enabled True
      "DRIFT CORRECTED: firewall re-enabled ($names) on $env:COMPUTERNAME"
    }
  EOT
}

data "aws_caller_identity" "current" {}

data "aws_availability_zones" "available" {
  state = "available"
}

# =====================================================================
# Network: one public subnet, no NAT, no inbound rules
# =====================================================================

resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = { Name = "${local.name}-vpc" }
}

resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id
  tags   = { Name = "${local.name}-igw" }
}

resource "aws_subnet" "public" {
  vpc_id            = aws_vpc.main.id
  cidr_block        = var.public_subnet_cidr
  availability_zone = data.aws_availability_zones.available.names[0]

  # Public IPs are assigned on the launch template's network interface instead.
  map_public_ip_on_launch = false

  tags = { Name = "${local.name}-subnet-public1" }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id
  tags   = { Name = "${local.name}-rtb-public" }
}

# The agent's only path to Systems Manager. Remove this and every EC2 node goes offline.
resource "aws_route" "internet" {
  route_table_id         = aws_route_table.public.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.main.id
}

resource "aws_route_table_association" "public" {
  subnet_id      = aws_subnet.public.id
  route_table_id = aws_route_table.public.id
}

# Free private path to S3 (agent updates, logs).
resource "aws_vpc_endpoint" "s3" {
  vpc_id            = aws_vpc.main.id
  service_name      = "com.amazonaws.${var.region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = [aws_route_table.public.id]

  tags = { Name = "${local.name}-vpce-s3" }
}

resource "aws_security_group" "nodes" {
  name        = "${local.name}-nodes-sg"
  description = "fleet-lab nodes - no inbound, SSM only"
  vpc_id      = aws_vpc.main.id

  tags = { Name = "${local.name}-nodes-sg" }
}

# Outbound only. Deliberately no ingress rules: Session Manager and RDP ride the agent's outbound connection.
resource "aws_vpc_security_group_egress_rule" "all_out" {
  security_group_id = aws_security_group.nodes.id
  description       = "All outbound (agent to SSM endpoints, OS patch repos)"
  ip_protocol       = "-1"
  cidr_ipv4         = "0.0.0.0/0"
}

# =====================================================================
# Logs bucket: session transcripts, Run Command output, patch output
# =====================================================================

resource "random_id" "suffix" {
  byte_length = 4
}

resource "aws_s3_bucket" "logs" {
  bucket = "${local.name}-logs-${random_id.suffix.hex}"

  # Lab convenience: lets terraform destroy remove the bucket with logs still in it.
  # Production would keep this false and use Object Lock or a separate log-archive account.
  force_destroy = true
}

resource "aws_s3_bucket_public_access_block" "logs" {
  bucket                  = aws_s3_bucket.logs.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "logs" {
  bucket = aws_s3_bucket.logs.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "logs" {
  bucket = aws_s3_bucket.logs.id

  rule {
    id     = "expire-${var.log_retention_days}d"
    status = "Enabled"

    filter {}

    expiration {
      days = var.log_retention_days
    }
  }
}

# =====================================================================
# IAM: node roles (the superintendent badges)
# =====================================================================

data "aws_iam_policy_document" "ec2_trust" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

# Hybrid nodes: trusted by Systems Manager, locked to this account (confused-deputy protection).
data "aws_iam_policy_document" "hybrid_trust" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ssm.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [local.account_id]
    }
    condition {
      test     = "ArnLike"
      variable = "aws:SourceArn"
      values   = ["arn:aws:ssm:${var.region}:${local.account_id}:*"]
    }
  }
}

# The agent uploads session logs and command output itself, using the node's role.
data "aws_iam_policy_document" "logs_write" {
  statement {
    sid       = "WriteLogs"
    actions   = ["s3:PutObject"]
    resources = ["${aws_s3_bucket.logs.arn}/*"]
  }
  statement {
    sid       = "CheckBucketEncryption"
    actions   = ["s3:GetEncryptionConfiguration"]
    resources = [aws_s3_bucket.logs.arn]
  }
}

resource "aws_iam_role" "ec2" {
  name               = "${local.name}-ec2-ssm-role"
  description        = "SSM agent permissions for fleet-lab EC2 nodes"
  assume_role_policy = data.aws_iam_policy_document.ec2_trust.json
}

resource "aws_iam_role_policy_attachment" "ec2_core" {
  role       = aws_iam_role.ec2.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_role_policy" "ec2_logs" {
  name   = "${local.name}-session-logs-write"
  role   = aws_iam_role.ec2.id
  policy = data.aws_iam_policy_document.logs_write.json
}

resource "aws_iam_instance_profile" "ec2" {
  name = aws_iam_role.ec2.name
  role = aws_iam_role.ec2.name
}

# Adopted from the console (see imports.tf) so the registered Proxmox nodes never lose their badge.
resource "aws_iam_role" "hybrid" {
  name               = "${local.name}-hybrid-ssm-role"
  description        = "SSM permissions for fleet-lab Proxmox hybrid nodes"
  assume_role_policy = data.aws_iam_policy_document.hybrid_trust.json
}

resource "aws_iam_role_policy_attachment" "hybrid_core" {
  role       = aws_iam_role.hybrid.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_role_policy" "hybrid_logs" {
  name   = "${local.name}-session-logs-write"
  role   = aws_iam_role.hybrid.id
  policy = data.aws_iam_policy_document.logs_write.json
}

# =====================================================================
# Session Manager preferences (account + region wide)
# =====================================================================

# Adopted from the console (see imports.tf). This document IS the Preferences tab.
resource "aws_ssm_document" "session_prefs" {
  name            = "SSM-SessionManagerRunShell"
  document_type   = "Session"
  document_format = "JSON"

  content = jsonencode({
    schemaVersion = "1.0"
    description   = "fleet-lab Session Manager preferences"
    sessionType   = "Standard_Stream"
    inputs = {
      s3BucketName                = aws_s3_bucket.logs.id
      s3KeyPrefix                 = "sessions"
      s3EncryptionEnabled         = true
      cloudWatchLogGroupName      = ""
      cloudWatchEncryptionEnabled = true
      cloudWatchStreamingEnabled  = false
      kmsKeyId                    = ""
      runAsEnabled                = false
      runAsDefaultUser            = ""
      idleSessionTimeout          = "15"
      maxSessionDuration          = ""
      shellProfile = {
        windows = ""
        linux   = ""
      }
    }
  })
}

# =====================================================================
# Launch templates (EC2 nodes are cattle: terminate and relaunch freely)
# =====================================================================

resource "aws_launch_template" "linux" {
  name                   = "${local.name}-linux-lt"
  description            = "Ubuntu 24.04 SSM-managed node"
  image_id               = local.ubuntu_ami
  instance_type          = var.linux_instance_type
  update_default_version = true

  iam_instance_profile {
    name = aws_iam_instance_profile.ec2.name
  }

  metadata_options {
    http_endpoint = "enabled"
    http_tokens   = "required" # IMDSv2 only
  }

  network_interfaces {
    device_index                = 0
    subnet_id                   = aws_subnet.public.id
    security_groups             = [aws_security_group.nodes.id]
    associate_public_ip_address = true
    delete_on_termination       = true
  }

  block_device_mappings {
    device_name = "/dev/sda1"
    ebs {
      volume_size           = 8
      volume_type           = "gp3"
      encrypted             = true
      delete_on_termination = true
    }
  }

  tag_specifications {
    resource_type = "instance"
    tags = {
      Name        = "${local.name}-lnx01"
      OS          = "Linux"
      Site        = "AWS"
      Environment = "Lab"
    }
  }

  tag_specifications {
    resource_type = "volume"
    tags = {
      Name = "${local.name}-lnx01-root"
    }
  }
}

resource "aws_launch_template" "windows" {
  name                   = "${local.name}-windows-lt"
  description            = "Windows Server 2022 SSM-managed node"
  image_id               = local.windows_ami
  instance_type          = var.windows_instance_type
  key_name               = var.windows_key_name
  update_default_version = true

  iam_instance_profile {
    name = aws_iam_instance_profile.ec2.name
  }

  metadata_options {
    http_endpoint = "enabled"
    http_tokens   = "required"
  }

  network_interfaces {
    device_index                = 0
    subnet_id                   = aws_subnet.public.id
    security_groups             = [aws_security_group.nodes.id]
    associate_public_ip_address = true
    delete_on_termination       = true
  }

  block_device_mappings {
    device_name = "/dev/sda1"
    ebs {
      volume_size           = 30
      volume_type           = "gp3"
      encrypted             = true
      delete_on_termination = true
    }
  }

  tag_specifications {
    resource_type = "instance"
    tags = {
      Name        = "${local.name}-win01"
      OS          = "Windows"
      Site        = "AWS"
      Environment = "Lab"
    }
  }

  tag_specifications {
    resource_type = "volume"
    tags = {
      Name = "${local.name}-win01-root"
    }
  }
}

# =====================================================================
# State Manager: standing rules (targeted by tag, so new nodes inherit them)
# =====================================================================

resource "aws_ssm_association" "linux_ntp" {
  association_name    = "${local.name}-linux-ntp"
  name                = "AWS-RunShellScript"
  schedule_expression = var.association_schedule
  compliance_severity = "MEDIUM"
  max_concurrency     = "50%"
  max_errors          = "1"

  parameters = {
    commands = local.linux_ntp_script
  }

  targets {
    key    = "tag:OS"
    values = ["Linux"]
  }

  output_location {
    s3_bucket_name = aws_s3_bucket.logs.id
    s3_key_prefix  = "state-manager"
  }
}

resource "aws_ssm_association" "windows_firewall" {
  association_name    = "${local.name}-windows-firewall"
  name                = "AWS-RunPowerShellScript"
  schedule_expression = var.association_schedule
  compliance_severity = "MEDIUM"
  max_concurrency     = "50%"
  max_errors          = "1"

  parameters = {
    commands = local.windows_firewall_script
  }

  targets {
    key    = "tag:OS"
    values = ["Windows"]
  }

  output_location {
    s3_bucket_name = aws_s3_bucket.logs.id
    s3_key_prefix  = "state-manager"
  }
}

# Keeps compliance data current between patch windows and scans new nodes as they come online.
resource "aws_ssm_association" "patch_scan" {
  association_name    = "${local.name}-patch-scan"
  name                = "AWS-RunPatchBaseline"
  schedule_expression = var.association_schedule
  max_concurrency     = "50%"
  max_errors          = "1"

  parameters = {
    Operation = "Scan"
  }

  targets {
    key    = "tag:Environment"
    values = ["Lab"]
  }

  output_location {
    s3_bucket_name = aws_s3_bucket.logs.id
    s3_key_prefix  = "patching"
  }
}

# =====================================================================
# Patch Manager: baselines (set as default) + weekly maintenance window
# =====================================================================

# Approve 7 days after release + weekly window = patched within 14 days.
resource "aws_ssm_patch_baseline" "windows" {
  name             = "${local.name}-windows-baseline"
  description      = "Security and critical, auto-approve after 7 days"
  operating_system = "WINDOWS"

  approval_rule {
    approve_after_days = 7
    compliance_level   = "CRITICAL"

    patch_filter {
      key    = "PRODUCT"
      values = ["WindowsServer2022"]
    }
    patch_filter {
      key    = "CLASSIFICATION"
      values = ["CriticalUpdates", "SecurityUpdates"]
    }
    patch_filter {
      key    = "MSRC_SEVERITY"
      values = ["Critical", "Important"]
    }
  }
}

# Ubuntu packages carry no release dates, so no approval delay; security pocket only.
resource "aws_ssm_patch_baseline" "ubuntu" {
  name             = "${local.name}-ubuntu-baseline"
  description      = "Ubuntu 24.04 security updates only"
  operating_system = "UBUNTU"

  approval_rule {
    compliance_level    = "HIGH"
    enable_non_security = false

    patch_filter {
      key    = "PRODUCT"
      values = ["Ubuntu24.04"]
    }
    patch_filter {
      key    = "SECTION"
      values = ["*"]
    }
    patch_filter {
      key    = "PRIORITY"
      values = ["*"]
    }
  }
}

# The step the console wouldn't show. On destroy, defaults revert to the AWS baselines.
resource "aws_ssm_default_patch_baseline" "windows" {
  baseline_id      = aws_ssm_patch_baseline.windows.id
  operating_system = "WINDOWS"
}

resource "aws_ssm_default_patch_baseline" "ubuntu" {
  baseline_id      = aws_ssm_patch_baseline.ubuntu.id
  operating_system = "UBUNTU"
}

resource "aws_ssm_maintenance_window" "patch" {
  name                       = "${local.name}-patch-window"
  description                = "Weekly patch install with reboot"
  schedule                   = var.patch_window_schedule
  schedule_timezone          = var.patch_window_timezone
  duration                   = 3
  cutoff                     = 1
  allow_unassociated_targets = false
  enabled                    = var.patch_window_enabled
}

resource "aws_ssm_maintenance_window_target" "all" {
  window_id     = aws_ssm_maintenance_window.patch.id
  name          = "${local.name}-all"
  resource_type = "INSTANCE"

  targets {
    key    = "tag:Environment"
    values = ["Lab"]
  }
}

# No service_role_arn: the window uses the AWSServiceRoleForAmazonSSM service-linked role.
resource "aws_ssm_maintenance_window_task" "install_patches" {
  window_id       = aws_ssm_maintenance_window.patch.id
  name            = "${local.name}-install-patches"
  task_type       = "RUN_COMMAND"
  task_arn        = "AWS-RunPatchBaseline"
  priority        = 1
  max_concurrency = "2"
  max_errors      = "1"

  targets {
    key    = "WindowTargetIds"
    values = [aws_ssm_maintenance_window_target.all.id]
  }

  task_invocation_parameters {
    run_command_parameters {
      output_s3_bucket     = aws_s3_bucket.logs.id
      output_s3_key_prefix = "patching"

      parameter {
        name   = "Operation"
        values = ["Install"]
      }
      parameter {
        name   = "RebootOption"
        values = ["RebootIfNeeded"]
      }
    }
  }
}

# =====================================================================
# Cost guardrail
# =====================================================================

resource "aws_budgets_budget" "monthly" {
  name         = "${local.name}-budget"
  budget_type  = "COST"
  limit_amount = var.budget_limit_usd
  limit_unit   = "USD"
  time_unit    = "MONTHLY"

  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 85
    threshold_type             = "PERCENTAGE"
    notification_type          = "ACTUAL"
    subscriber_email_addresses = [var.budget_email]
  }

  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 100
    threshold_type             = "PERCENTAGE"
    notification_type          = "FORECASTED"
    subscriber_email_addresses = [var.budget_email]
  }
}
