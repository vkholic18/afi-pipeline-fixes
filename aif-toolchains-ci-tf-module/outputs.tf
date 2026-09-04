# ---------------------------------------------------------------------------
# Outputs to expose toolchain information
# ---------------------------------------------------------------------------

# Output the toolchain IDs created by the module
output "toolchain_ids" {
  description = "Map of toolchain GUIDs to their resource IDs"
  value       = { for guid, tc in module.toolchains.toolchain_instance : guid => tc.id }
}

# Output the toolchain names
output "toolchain_names" {
  description = "Map of toolchain GUIDs to their names"
  value       = { for guid, tc in module.toolchains.toolchain_instance : guid => tc.name }
}