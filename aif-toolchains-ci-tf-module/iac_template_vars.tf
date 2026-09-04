# ============================================================================
# Pipeline Trigger Configuration
# ============================================================================

variable "iac_afi_generic_pipeline_types_trigger_data" {
  type = map(list(object({
    trigger_type             = string
    worker                   = optional(string, "")
    type                     = optional(string, "")
    cron                     = optional(string, "")
    key_name                 = optional(string, "")
    source                   = optional(string, "")
    trigger_branch           = optional(string, "")
    events                   = optional(list(string), [])
    event_listener           = string
    trigger_name             = string
    enabled                  = bool
    max_concurrent_runs      = optional(number, 0)
    enable_events_from_forks = optional(bool)
    filter                   = optional(string, "")
    properties = optional(map(object({
      type         = string
      value        = string
      secret_group = optional(string, null)
    })), {})
  })))
  default = {
    "pipeline" = [{
      "trigger_type"        = "scm",
      "filter"              = " header['x-github-event'] == 'issues' &&  body.action == 'opened' ",
      "event_listener"      = "dev-mode-cd-listener",
      "trigger_name"        = "AFI",
      "enabled"             = true,
      "max_concurrent_runs" = 15
      }
    ],
  }
}

# ============================================================================
# Pipeline Integration Configuration
# ============================================================================

variable "iac_afi_integrations_pr_pipeline_master" {
  type = list(any)
  # COMMENTED OUT - evidence-repo and inventory-repo don't exist, causing null value errors
  # default = ["evidence-repo", "inventory-repo", "incident-repo"]
  default = [] # Empty list to prevent creating properties for non-existent repos
}

# ============================================================================
# Pipeline Metadata Configuration
# ============================================================================

variable "iac_afi_pr_master_pipeline_meta" {
  type = map(object({
    type  = string
    value = string
  }))
  default = {
    "pipeline-config" = {
      "type"  = "text",
      "value" = ".afi-config.yaml"
    }
  }
}
