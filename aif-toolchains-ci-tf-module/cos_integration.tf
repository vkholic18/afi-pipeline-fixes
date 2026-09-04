# ---------------------------------------------------------------------------
# Cloud Object Storage (COS) Integration
# Native IBM Cloud Object Storage integration for the toolchain
# cos_api_key uses SM ref:// — lifecycle ignore_changes prevents update failures
# ---------------------------------------------------------------------------

# Cloud Object Storage Integration (IBM Native Tool)
resource "ibm_cd_toolchain_tool_cos" "cos_integration" {
  toolchain_id = module.toolchains.toolchain_ids[local.toolchain_guid]

  parameters {
    name         = var.cos_integration_name
    bucket_name  = var.cos_bucket_name
    endpoint     = var.cos_integration_endpoint
    instance_crn = var.cos_instance_crn
    cos_api_key  = "ref://${var.sm_secret_ref}/${var.secret_group_name}/${var.sm_secret_cos_api_key}"
  }

  # SM ref:// cannot be validated by the provider on update.
  # Token is set correctly on create — ignore changes to prevent failed updates.
  lifecycle {
    ignore_changes = [parameters]
  }
}