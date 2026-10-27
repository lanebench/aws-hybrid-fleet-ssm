# Adopt two console-built resources instead of deleting and recreating them.
#
# 1. The hybrid role: the registered Proxmox nodes get their credentials through it.
#    Deleting it would knock both mi- nodes offline.
# 2. The Session Manager preferences document: it already exists from the console,
#    so creating it again would fail.
#
# Terraform reads these into state on the first apply. Safe to leave in place afterwards.

import {
  to = aws_iam_role.hybrid
  id = "fleet-lab-hybrid-ssm-role"
}

import {
  to = aws_iam_role_policy_attachment.hybrid_core
  id = "fleet-lab-hybrid-ssm-role/arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

import {
  to = aws_iam_role_policy.hybrid_logs
  id = "fleet-lab-hybrid-ssm-role:fleet-lab-session-logs-write"
}

import {
  to = aws_ssm_document.session_prefs
  id = "SSM-SessionManagerRunShell"
}
