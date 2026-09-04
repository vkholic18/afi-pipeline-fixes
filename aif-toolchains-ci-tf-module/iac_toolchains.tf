# ---------------------------------------------------------------------------
# - This module serves as the main configuration for all toolchains/pipelines
# ---------------------------------------------------------------------------

# Build pipeline properties map from individual variables
locals {
  # Get the first toolchain guid from module's toolchain_ids output
  toolchain_guid = keys(module.toolchains.toolchain_ids)[0]

  # Build trigger data here (not in tfvars) so var.tc_afi_repo_url can be referenced
  iac_trigger_data = {
    "pipeline" = [
      {
        trigger_type        = "scm"
        filter              = " header['x-github-event'] == 'issues' && body.action == 'opened' "
        event_listener      = "simple-listener"
        trigger_name        = "afi_git_issue"
        enabled             = true
        max_concurrent_runs = 0
        properties = {
          "pipeline-config" = {
            type         = "text"
            value        = var.pipeline_config
            secret_group = null
          }
          "pipeline-config-repo-path" = {
            type         = "text"
            value        = "."
            secret_group = null
          }
          # 3. afi repo — referenced by name so it stays in sync with tc_afi_repo_url
          "repository" = {
            type         = "text"
            value        = var.tc_afi_repo_url
            secret_group = null
          }
        }
      },
      {
        trigger_type   = "generic"
        worker         = "IBM-INTERNAL-WORKER"
        event_listener = "async-stage-listener"
        trigger_name   = "trigger-exection-subtask"
        enabled        = true
        type           = "token_matches"
        key_name       = "x-async-stage-token"
        source         = "header"
        properties     = {}
      }
    ]
  }

  iac_afi_tf_vars = {
    # Text properties - using individual variables from variables.tf
    "artifactory-docker-url" = {
      type  = "text"
      value = var.artifactory_docker_url
    }
    "artifactory_reader" = {
      type  = "text"
      value = var.artifactory_reader
    }
    "assignedto" = {
      type  = "text"
      value = var.assignedto
    }
    "collect-evidence" = {
      type  = "text"
      value = var.collect_evidence
    }
    "cos-auth-endpoint" = {
      type  = "text"
      value = var.cos_auth_endpoint
    }
    "cos-bucket-name" = {
      type  = "text"
      value = var.cos_bucket_name
    }
    "cos-endpoint" = {
      type  = "text"
      value = var.cos_endpoint
    }
    "ibmcloud-api" = {
      type  = "text"
      value = var.ibmcloud_api
    }
    "ibmcloud-api-url" = {
      type  = "text"
      value = var.ibmcloud_api_url
    }
    "ibmcloud-domain" = {
      type  = "text"
      value = var.ibmcloud_domain
    }
    "max_retries" = {
      type  = "text"
      value = var.max_retries
    }
    "ops-repo" = {
      type  = "text"
      value = var.ops_repo
    }
    "ops-repo-branch" = {
      type  = "text"
      value = var.ops_repo_branch
    }
    "pipeline-config" = {
      type  = "text"
      value = var.pipeline_config
    }
    "pipeline-config-branch" = {
      type  = "text"
      value = var.pipeline_config_branch
    }
    "pipeline-config-repo" = {
      type  = "text"
      value = var.pipeline_config_repo
    }
    "secret-group-name" = {
      type  = "text"
      value = var.secret_group_name
    }
    "service-now-base-url" = {
      type  = "text"
      value = var.service_now_base_url
    }
    "service-url-secret-manager" = {
      type  = "text"
      value = var.service_url_secret_manager
    }
    "servicenow-api-base-url" = {
      type  = "text"
      value = var.servicenow_api_base_url
    }
    "upload-to-git" = {
      type  = "text"
      value = var.upload_to_git
    }
    "validate_exported_var" = {
      type  = "text"
      value = var.validate_exported_var
    }

    # Secure properties — all resolved from Secrets Manager via ref://
    # Secret names come from variables.tf / terraform.tfvars (no hardcoding)
    "COS_SERVICE_CREDENTIALS" = {
      type         = "secure"
      value        = var.sm_secret_cos_service_credentials
      secret_group = var.secret_group_name
    }
    "account-id" = {
      type         = "secure"
      value        = var.sm_secret_account_id
      secret_group = var.secret_group_name
    }
    "artifactory_token" = {
      type         = "secure"
      value        = var.sm_secret_artifactory_token
      secret_group = var.secret_group_name
    }
    "cos-api-key" = {
      type         = "secure"
      value        = var.sm_secret_cos_api_key
      secret_group = var.secret_group_name
    }
    "git-token" = {
      type         = "secure"
      value        = var.sm_secret_git_token
      secret_group = var.secret_group_name
    }
    "ibmcloud-api-key" = {
      type         = "secure"
      value        = var.sm_secret_ibmcloud_api_key
      secret_group = var.secret_group_name
    }
    "pipeline-dockerconfigjson" = {
      type         = "secure"
      value        = var.sm_secret_pipeline_dockerconfigjson
      secret_group = var.secret_group_name
    }
    "pnp-ibmcloud-api-key" = {
      type         = "secure"
      value        = var.sm_secret_pnp_ibmcloud_api_key
      secret_group = var.secret_group_name
    }
  }
}

module "toolchains" {

  # Using Nisha's forked repository - test1 branch with OAuth modifications (SSH for authentication)
  source = "git::ssh://git@github.ibm.com/Nisha-Patil1/devops-toolchain-afi-infra-module.git//modules/toolchain?ref=test1"

  ibmcloud_api_key = var.ibmcloud_api_key
  region           = var.region

  # Override module defaults - empty maps to use only variables defined in iac_template_vars.tf
  base_image_props           = {}
  tc_contrast_sast_env_props = {}
  tc_iac_env_props           = {}
  tc_razee_env_props         = {}

  # Secrets Manager configuration
  secrets_manager_data = {
    "sm-name"         = var.sm_name
    "sm-instance"     = var.sm_name
    "sm-resource-grp" = var.sm_resource_group
    "sm-secret-ref"   = var.sm_secret_ref
  }

  # Only use IBM-INTERNAL-WORKER, no private workers
  workers = [
    {
      name = "IBM-INTERNAL-WORKER"
    }
  ]

  # ---------------------------------------------------------------------------
  # - ENV PROPS (global) THAT WILL BE COPIED TO EACH PIPELINE OF EACH TOOLCHAIN
  # ---------------------------------------------------------------------------
  template_type = "afi"

  toolchains = [
    {
      guid = "afi-f458a058-82be-438e-878d-6ae3f0ec9fd5" # run something like 'uuidgen' to generate or online tool

      # toolchain name. note: all toolchains will get 'tc-' prepended to the name to help with sorting and denote
      # which toolchains were created with automation
      name = var.tc_name
      # 1. operations repo — sample-operations-metadata where GitHub Issues fire from
      operations_repo_url = var.tc_operations_repo_url
      pipeline_name       = "afi"
      resource_grp        = "AIF_DEV" # we cannot use optional
      tags                = ["type:AFI", "toolchains:AFI"]

      # afi repo — AFI pipeline config and scripts repo
      afi_repo_url = var.tc_afi_repo_url

      # GitHub PAT Secrets Manager reference (used by toolchain GitHub integrations)
      git_token_secret_ref = "ref://${var.sm_secret_ref}/${var.secret_group_name}/${var.sm_secret_git_token}"

      # ---------------------------------------------------------------------------------
      # - ENV PROPS (toolchain) THAT WILL BE COPIED TO EACH PIPELINE OF A GIVEN TOOLCHAIN
      # ---------------------------------------------------------------------------------
      tc_env_props                = local.iac_afi_tf_vars
      pipeline_types_trigger_data = local.iac_trigger_data
      # ---------------------------------------------------------------------------------
      # - PIPELINE SPECIFIC METADATA (pipeline) ie ENV PROPERTIES FOR A GIVEN PIPELINE
      # ---------------------------------------------------------------------------------
      pipeline_meta = local.iac_afi_pipeline_meta_default
    }

  ]
}

