variable "ibmcloud_api_key" {
  sensitive = true
  type      = string
}

variable "ibmcloud_api_key_value" {
  sensitive   = true
  type        = string
  description = "IBM Cloud API Key value (alternative parameter name)"
  default     = ""
}

variable "region" {
  type    = string
  default = "us-south"
}

# ============================================================================
# Pipeline Property Variables - Text Properties
# ============================================================================

variable "artifactory_docker_url" {
  type        = string
  description = "Artifactory Docker registry URL"
  default     = "docker-na-public.artifactory.swg-devops.com"
}

variable "artifactory_reader" {
  type        = string
  description = "Artifactory reader email"
  default     = "nisha.patil@ibm.com"
}

variable "assignedto" {
  type        = string
  description = "Email address for assignment"
  default     = "afi1@ibm.com"
}

variable "collect_evidence" {
  type        = string
  description = "Flag to collect evidence (0 or 1)"
  default     = "0"
}

variable "cos_auth_endpoint" {
  type        = string
  description = "COS authentication endpoint"
  default     = "https://iam.cloud.ibm.com/identity/token/"
}

variable "cos_bucket_name" {
  type        = string
  description = "COS bucket name for evidence storage"
  default     = "team-mod-afi-cos"
}

variable "cos_endpoint" {
  type        = string
  description = "COS endpoint URL"
  default     = "https://s3.us-south.cloud-object-storage.appdomain.cloud"
}

variable "ibmcloud_api" {
  type        = string
  description = "IBM Cloud API endpoint"
  default     = "https://cloud.ibm.com"
}

variable "ibmcloud_api_url" {
  type        = string
  description = "IBM Cloud DevOps API URL"
  default     = "https://api.us-south.devops.cloud.ibm.com"
}

variable "ibmcloud_domain" {
  type        = string
  description = "IBM Cloud domain"
  default     = "cloud.ibm.com"
}

variable "max_retries" {
  type        = string
  description = "Maximum number of retries"
  default     = "3"
}

variable "ops_repo" {
  type        = string
  description = "Operations metadata repository URL"
  default     = "https://github.ibm.com/Nisha-Patil1/sample-operations-metadata"
}

variable "ops_repo_branch" {
  type        = string
  description = "Operations repository branch"
  default     = "main"
}

variable "pipeline_config" {
  type        = string
  description = "Pipeline configuration file name"
  default     = ".afi-config.yaml"
}

variable "pipeline_config_branch" {
  type        = string
  description = "Pipeline configuration repository branch"
  default     = "main"
}

variable "pipeline_config_repo" {
  type        = string
  description = "Pipeline configuration repository URL"
  default     = "https://github.ibm.com/Nisha-Patil1/afi"
}

variable "secret_group_name" {
  type        = string
  description = "Secrets Manager secret group name"
  default     = "afi_sg"
}

variable "service_now_base_url" {
  type        = string
  description = "ServiceNow base URL"
  default     = "https://pnp-api-oss.cloud.ibm.com"
}

variable "service_url_secret_manager" {
  type        = string
  description = "Secrets Manager service URL"
  default     = "https://ee181c2a-078f-481b-892a-a43b31a544fe.us-south.secrets-manager.appdomain.cloud"
}

variable "servicenow_api_base_url" {
  type        = string
  description = "ServiceNow API base URL"
  default     = "https://pnp-api-oss.test.cloud.ibm.com"
}

variable "upload_to_git" {
  type        = string
  description = "Git platform for uploads"
  default     = "GitHub"
}

variable "validate_exported_var" {
  type        = string
  description = "Variables to validate (comma-separated)"
  default     = "ENVIRONMENT,REGION"
}

# ============================================================================
# Pipeline Property Variables - Secure Properties (SM secret names)
# No raw secret values — all resolved from Secrets Manager at pipeline runtime
# secret_group_name variable (defined above) is reused for the group
# ============================================================================

variable "sm_secret_ibmcloud_api_key" {
  type        = string
  description = "SM secret name for IBM Cloud API key"
}

variable "sm_secret_account_id" {
  type        = string
  description = "SM secret name for IBM Cloud account ID"
}

variable "sm_secret_cos_api_key" {
  type        = string
  description = "SM secret name for COS API key"
}

variable "sm_secret_cos_service_credentials" {
  type        = string
  description = "SM secret name for COS service credentials"
}

variable "sm_secret_artifactory_token" {
  type        = string
  description = "SM secret name for Artifactory token"
}

variable "sm_secret_git_token" {
  type        = string
  description = "SM secret name for GitHub PAT (used by pipeline properties)"
}

variable "sm_secret_pipeline_dockerconfigjson" {
  type        = string
  description = "SM secret name for Docker config JSON"
}

variable "sm_secret_pnp_ibmcloud_api_key" {
  type        = string
  description = "SM secret name for PnP IBM Cloud API key"
}

variable "subpipeline_webhook_token" {
  type        = string
  description = "Subpipeline webhook token"
  sensitive   = true
  default     = ""
}

# ============================================================================
# Toolchain Identity
# ============================================================================

variable "tc_name" {
  type        = string
  description = "Toolchain name — will be prefixed with 'tc-' in the UI"
}

# ============================================================================
# Secrets Manager Configuration
# ============================================================================

variable "sm_name" {
  type        = string
  description = "Secrets Manager instance name (used as integration name in toolchain)"
}

variable "sm_resource_group" {
  type        = string
  description = "Resource group where the Secrets Manager instance lives"
}

variable "sm_secret_ref" {
  type        = string
  description = "Secrets Manager ref path used in ref:// URIs. Format: secrets-manager.<region>.<resource-group>.<sm-name> — e.g. 'secrets-manager.us-south.AIF_DEV.team_mod_afi_sm'. Must match tc_git_token_secret_ref prefix."
}

# ============================================================================
# COS Integration
# ============================================================================

variable "cos_integration_name" {
  type        = string
  description = "Display name of the COS toolchain integration"
  default     = "afi-evidence-cos"
}

variable "cos_instance_crn" {
  type        = string
  description = "CRN of the Cloud Object Storage instance"
}

variable "cos_integration_endpoint" {
  type        = string
  description = "COS endpoint for the toolchain integration (no https:// prefix)"
}

# ============================================================================
# GitHub Repository Variables
# ============================================================================

variable "tc_operations_repo_url" {
  type        = string
  description = "SCM trigger repo — GitHub Issues opened here fire the pipeline (e.g. sample-operations-metadata)"
}

variable "tc_afi_repo_url" {
  type        = string
  description = "AFI config and pipeline scripts repository URL (e.g. afi)"
}

