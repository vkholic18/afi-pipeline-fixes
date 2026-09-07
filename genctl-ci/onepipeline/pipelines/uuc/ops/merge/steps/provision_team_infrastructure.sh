#!/usr/bin/env bash
# =============================================================================================
# IBM Confidential
# (C) Copyright IBM Corp. 2026
# The source code for this program is not published or otherwise divested of its trade secrets,
# irrespective of what has been deposited with the U.S. Copyright Office.
# =============================================================================================

# Team Infrastructure Provisioning Script
# This script runs in the merge pipeline of uuc-service-cicd-onboarding repo
# It detects new/changed teams and creates a PR in uuc-infrastructure-tf-module repo
# to provision: Resource Groups, Secret Groups, CD Instances, COS Buckets, Access Groups
#
# Branch strategy
# ---------------
# Each team owns a dedicated branch in the infra repo named after its team slug
# (e.g. "observability").  The PR created by this script targets that branch.
# For a brand-new team the branch is forked from main.
#
# tfvars file location
# --------------------
# Team-specific Terraform variables live in a <team-slug>.auto.tfvars file at the
# repo root.  Terraform auto-loads all *.auto.tfvars files automatically so no
# -var-file flag is required.
#
# Secrets scripts
# ---------------
# scripts/secrets/ (including extract_custom_secrets.py and
# mandatory_secrets_template.yaml) only exist on the main branch of the infra
# repo.  This script fetches main separately into a temp directory so it can run
# those scripts regardless of which team branch is being processed.

set -e  # Exit on error

# Source common utilities
source "${PATH_TO_GENCTL_CI}/onepipeline/utils/onboarding_validation_utils.sh"
source "${PATH_TO_GENCTL_CI}/onepipeline/utils/one_pipeline_utils.sh"

# Configuration
INFRASTRUCTURE_REPO="github.ibm.com/genctl-cicd/uuc-infrastructure-tf-module"
INFRASTRUCTURE_REPO_URL="https://${GITHUB_TOKEN}@${INFRASTRUCTURE_REPO}.git"
INFRASTRUCTURE_BRANCH="main"
# Path to secrets scripts relative to the repo root (only present on main branch)
SECRETS_SCRIPT_PATH="scripts/secrets/extract_custom_secrets.py"
# Path to the zone/region map utility (lives in genctl-ci, always available)
ZONE_MAP_UTILS="${PATH_TO_GENCTL_CI}/onepipeline/utils/zone_region_map_utils.py"

# Temporary working directory
WORK_DIR="/tmp/uuc-infra-provision-$$"

# Directory that contains the scripts/secrets/ tools (always cloned from main)
SECRETS_TOOLS_DIR="${WORK_DIR}/secrets-tools"

# Use pre-cloned infrastructure repo if available, otherwise clone it
if [ -n "$PATH_TO_UUC_INFRASTRUCTURE_REPO" ] && [ -d "$PATH_TO_UUC_INFRASTRUCTURE_REPO" ]; then
    INFRA_CLONE_DIR="$PATH_TO_UUC_INFRASTRUCTURE_REPO"
    USE_EXISTING_CLONE=true
else
    INFRA_CLONE_DIR="${WORK_DIR}/infrastructure"
    USE_EXISTING_CLONE=false
fi

# Initialize
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${GREEN}🏗️  UUC Team Infrastructure Provisioning${NC}"
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""

# Check prerequisites
check_python_available
check_python_dependencies
check_github_token

# ---------------------------------------------------------------------------
# Function to extract team information from onboarding file
# ---------------------------------------------------------------------------
extract_team_info() {
    local onboarding_file="$1"

    if [ ! -f "$onboarding_file" ]; then
        echo -e "${RED}[ERROR]${NC} Onboarding file not found: $onboarding_file" >&2
        return 1
    fi

    # Use Python to parse YAML
    python3 - <<EOF
import yaml
import sys

try:
    with open('$onboarding_file', 'r') as f:
        config = yaml.safe_load(f)

    if config is None:
        print(f"ERROR: YAML file is empty or invalid: $onboarding_file", file=sys.stderr)
        sys.exit(1)

    if not isinstance(config, dict):
        print(f"ERROR: YAML file does not contain a valid dictionary: $onboarding_file", file=sys.stderr)
        sys.exit(1)

    team_name = config.get('team_name', '')
    if not team_name:
        print(f"ERROR: 'team_name' field is missing or empty in: $onboarding_file", file=sys.stderr)
        sys.exit(1)

    team_slug = team_name.lower().replace(' ', '-')

    compliance_bucket = config.get('compliance_bucket', {})
    if compliance_bucket is None:
        compliance_bucket = {}
    use_existing_bucket = compliance_bucket.get('use_existing', False)

    print(f"{team_name}|{team_slug}|{use_existing_bucket}")

except yaml.YAMLError as e:
    print(f"ERROR: YAML parsing error in $onboarding_file: {e}", file=sys.stderr)
    sys.exit(1)
except Exception as e:
    print(f"ERROR: {e}", file=sys.stderr)
    sys.exit(1)
EOF
}

# ---------------------------------------------------------------------------
# Function to check if the team branch already exists on the remote
# ---------------------------------------------------------------------------
team_branch_exists() {
    local team_slug="$1"
    cd "${INFRA_CLONE_DIR}"
    git ls-remote --exit-code --heads origin "$team_slug" &>/dev/null
}

# ---------------------------------------------------------------------------
# Function to ensure scripts/secrets tools are available from main branch.
# Clones only the scripts/secrets/ subtree of main into SECRETS_TOOLS_DIR so
# the Python scripts can always be found there, independent of which team
# branch is checked out in INFRA_CLONE_DIR.
# ---------------------------------------------------------------------------
ensure_secrets_tools() {
    if [ -d "${SECRETS_TOOLS_DIR}" ]; then
        echo -e "${BLUE}[INFO]${NC} Secrets tools already fetched from main"
        return 0
    fi

    echo -e "${BLUE}[INFO]${NC} Fetching scripts/secrets from main branch..."
    mkdir -p "${SECRETS_TOOLS_DIR}"

    # Sparse-clone only the scripts/ directory from main to keep it lightweight
    git clone \
        --depth 1 \
        --branch "$INFRASTRUCTURE_BRANCH" \
        --no-checkout \
        "$INFRASTRUCTURE_REPO_URL" \
        "${SECRETS_TOOLS_DIR}" 2>&1 | grep -v "warning: " || {
        echo -e "${RED}[ERROR]${NC} Failed to clone main for secrets tools"
        return 1
    }

    git -C "${SECRETS_TOOLS_DIR}" sparse-checkout set scripts/
    git -C "${SECRETS_TOOLS_DIR}" checkout

    if [ ! -f "${SECRETS_TOOLS_DIR}/${SECRETS_SCRIPT_PATH}" ]; then
        echo -e "${RED}[ERROR]${NC} extract_custom_secrets.py not found on main branch"
        return 1
    fi

    echo -e "${GREEN}[SUCCESS]${NC} Secrets tools ready at ${SECRETS_TOOLS_DIR}"
}

# ---------------------------------------------------------------------------
# Function to generate team access groups configuration (written to .auto.tfvars)
# ---------------------------------------------------------------------------
generate_team_access_groups() {
    local team_name="$1"
    local team_slug="$2"

    local resource_group_name="UUC_${team_name// /_}"
    local var_name="${team_slug//-/_}_access_groups"

    cat <<EOF
##############################################################################
# ${team_name} Team Access Groups Configuration
# This file is auto-loaded by Terraform (*.auto.tfvars) — do not rename.
##############################################################################

${var_name} = [
  {
    name        = "UUC_${team_name// /_}_Admin"
    description = "Enables ${team_name} team members to manage and administer assigned resources with full permissions"
    policies = [
      {
        name  = "resource-group-viewer"
        roles = ["Viewer"]
        resources = {
          resource_group_id = "${resource_group_name}"
          resource_type     = "resource-group"
        }
      },
      {
        name  = "toolchain-operator"
        roles = ["Viewer", "PipelineRunner"]
        resources = {
          resource_group_id = "${resource_group_name}"
          service           = "toolchain"
        }
      },
      {
        name  = "one-pipeline-dev-toolchain-pipeline-runner"
        roles = ["Viewer", "PipelineRunner"]
        resources = {
          resource_group_id    = "One_Pipeline_Dev"
          resource_instance_id = "tc-uuc-service-cicd-onboarding-compliance-ci-toolchain"
          service              = "toolchain"
        }
      },
      {
        name  = "one-pipeline-dev-resource-group-viewer"
        roles = ["Viewer"]
        resources = {
          resource_group_id = "One_Pipeline_Dev"
          resource_type     = "resource-group"
        }
      },
      {
        name  = "tekton-workers-resource-group-viewer"
        roles = ["Viewer"]
        resources = {
          resource_group_id = "Tekton_Workers"
          resource_type     = "resource-group"
        }
      },
      {
        name  = "one-pipeline-services-resource-group-viewer"
        roles = ["Viewer"]
        resources = {
          resource_group_id = "One_Pipeline_Services"
          resource_type     = "resource-group"
        }
      },
      {
        name  = "secrets-manager-modifier"
        roles = ["Viewer", "Reader", "Secrets Modifier", "SecretsReader"]
        resources = {
          resource_group_id    = "Tekton_Workers"
          resource_instance_id = "VPC-CI-Universal-SecretsManager"
          service              = "secrets-manager"
          resource_type        = "secret-group"
          resource             = "sg-uuc-${team_slug}"
        }
      },
      {
        name  = "secrets-manager-instance-viewer"
        roles = ["Viewer"]
        resources = {
          resource_group_id    = "Tekton_Workers"
          resource_instance_id = "VPC-CI-Universal-SecretsManager"
          service              = "secrets-manager"
        }
      },
      {
        name  = "registry-sandbox-writer"
        roles = ["Viewer", "Reader", "Writer"]
        resources = {
          resource_group_id = "One_Pipeline_Services"
          service           = "container-registry"
          resource          = "vpc-sandbox-docker-local"
        }
      },
      {
        name  = "registry-all-reader"
        roles = ["Viewer", "Reader"]
        resources = {
          service = "container-registry"
        }
      }
    ]
    members = {
      users           = []
      service_ids     = []
      iam_service_ids = []
    }
  },
  {
    name        = "UUC_${team_name// /_}_User"
    description = "Extends reader permissions with pipeline execution and Secrets Manager access for ${team_name} team"
    policies = [
      {
        name  = "resource-group-viewer"
        roles = ["Viewer"]
        resources = {
          resource_group_id = "${resource_group_name}"
          resource_type     = "resource-group"
        }
      },
      {
        name  = "toolchain-operator"
        roles = ["Viewer", "PipelineRunner"]
        resources = {
          resource_group_id = "${resource_group_name}"
          service           = "toolchain"
        }
      },
      {
        name  = "one-pipeline-dev-toolchain-pipeline-runner"
        roles = ["Viewer", "PipelineRunner"]
        resources = {
          resource_group_id    = "One_Pipeline_Dev"
          resource_instance_id = "tc-uuc-service-cicd-onboarding-compliance-ci-toolchain"
          service              = "toolchain"
        }
      },
      {
        name  = "one-pipeline-dev-resource-group-viewer"
        roles = ["Viewer"]
        resources = {
          resource_group_id = "One_Pipeline_Dev"
          resource_type     = "resource-group"
        }
      },
      {
        name  = "one-pipeline-services-resource-group-viewer"
        roles = ["Viewer"]
        resources = {
          resource_group_id = "One_Pipeline_Services"
          resource_type     = "resource-group"
        }
      },
      {
        name  = "registry-sandbox-writer"
        roles = ["Viewer", "Reader", "Writer"]
        resources = {
          resource_group_id = "One_Pipeline_Services"
          service           = "container-registry"
          resource          = "vpc-sandbox-docker-local"
        }
      },
      {
        name  = "registry-all-reader"
        roles = ["Viewer", "Reader"]
        resources = {
          service = "container-registry"
        }
      }
    ]
    members = {
      users           = []
      service_ids     = []
      iam_service_ids = []
    }
  },
  {
    name        = "UUC_${team_name// /_}_Reader"
    description = "Read-only access to view ${team_name} team's pipeline logs and resource information"
    policies = [
      {
        name  = "resource-group-viewer"
        roles = ["Viewer"]
        resources = {
          resource_group_id = "${resource_group_name}"
          resource_type     = "resource-group"
        }
      },
      {
        name  = "toolchain-viewer"
        roles = ["Viewer"]
        resources = {
          resource_group_id = "${resource_group_name}"
          service           = "toolchain"
        }
      },
      {
        name  = "one-pipeline-services-resource-group-viewer"
        roles = ["Viewer"]
        resources = {
          resource_group_id = "One_Pipeline_Services"
          resource_type     = "resource-group"
        }
      },
      {
        name  = "registry-sandbox-writer"
        roles = ["Viewer", "Reader", "Writer"]
        resources = {
          resource_group_id = "One_Pipeline_Services"
          service           = "container-registry"
          resource          = "vpc-sandbox-docker-local"
        }
      },
      {
        name  = "registry-all-reader"
        roles = ["Viewer", "Reader"]
        resources = {
          service = "container-registry"
        }
      }
    ]
    members = {
      users           = []
      service_ids     = []
      iam_service_ids = []
    }
  }
]
EOF
}

# ---------------------------------------------------------------------------
# Function to create or update <team-slug>.auto.tfvars at the repo root.
# Terraform auto-loads all *.auto.tfvars files, so no -var-file flag needed.
# ---------------------------------------------------------------------------
create_or_update_team_autotfvars() {
    local team_slug="$1"
    local is_new_team="$2"
    local tfvars_file="${INFRA_CLONE_DIR}/${team_slug}.auto.tfvars"
    local var_prefix="${team_slug//-/_}"

    if [ "$is_new_team" = "true" ]; then
        echo -e "${BLUE}[INFO]${NC} Creating ${team_slug}.auto.tfvars at repo root"

        local access_groups_config
        access_groups_config=$(generate_team_access_groups "$team_name" "$team_slug")

        cat > "$tfvars_file" <<EOF
${access_groups_config}

# PSIRT ID for Mend SAST Secrets (team-level — same value for all services)
${var_prefix}_psirt_id = ""

# Custom Secrets Configuration (Team-Managed)
# Mandatory secrets (GARA, ServiceNow, FID) are hardcoded in the Terraform module
# Mend SAST secrets are generated dynamically from ${var_prefix}_psirt_id below
# Secret names will be: sg-uuc-<team-slug>-<secret-name>
# Total custom secrets: 0
${var_prefix}_custom_secrets = []

# Slack member IDs for secret notifications (populated from onboarding.yaml)
${var_prefix}_slack_member_ids = []

# Slack channel per service for secret notifications (populated from onboarding.yaml)
${var_prefix}_slack_channel = []
EOF
        echo -e "${GREEN}[SUCCESS]${NC} Created ${team_slug}.auto.tfvars with access groups configuration"
    else
        echo -e "${BLUE}[INFO]${NC} Checking for existing ${team_slug}.auto.tfvars"
        if [ ! -f "$tfvars_file" ]; then
            echo -e "${YELLOW}[WARNING]${NC} ${team_slug}.auto.tfvars not found, creating stub"
            cat > "$tfvars_file" <<EOF
# ${team_slug} Team Configuration
# Auto-loaded by Terraform (*.auto.tfvars) — do not rename.

${var_prefix}_access_groups    = []
${var_prefix}_psirt_id         = ""
${var_prefix}_custom_secrets   = []
${var_prefix}_slack_member_ids = []
${var_prefix}_slack_channel    = []
EOF
            echo -e "${GREEN}[SUCCESS]${NC} Created stub ${team_slug}.auto.tfvars"
        else
            echo -e "${BLUE}[INFO]${NC} ${team_slug}.auto.tfvars exists, will be updated with secrets below"
            # Ensure slack list variables exist in the file (may be missing on
            # team branches created before slack support was added).
            if ! grep -qE "^${var_prefix}_slack_member_ids[[:space:]]*=" "$tfvars_file"; then
                echo -e "${BLUE}[INFO]${NC} Adding missing ${var_prefix}_slack_member_ids to ${team_slug}.auto.tfvars"
                echo "" >> "$tfvars_file"
                echo "${var_prefix}_slack_member_ids = []" >> "$tfvars_file"
            fi
            if ! grep -qE "^${var_prefix}_slack_channel[[:space:]]*=" "$tfvars_file"; then
                echo -e "${BLUE}[INFO]${NC} Adding missing ${var_prefix}_slack_channel to ${team_slug}.auto.tfvars"
                echo "${var_prefix}_slack_channel = []" >> "$tfvars_file"
            fi
        fi
    fi

    return 0
}

# ---------------------------------------------------------------------------
# Function to generate custom secrets config for a team.
# IMPORTANT: scripts/secrets/ only lives on the main branch.
# We run the Python script from SECRETS_TOOLS_DIR (cloned from main) and
# write the output to WORK_DIR; the result is later appended to the team's
# .auto.tfvars on the team branch.
# ---------------------------------------------------------------------------
generate_custom_secrets_for_team() {
    local team_slug="$1"
    shift
    local onboarding_files=("$@")
    local output_file="${WORK_DIR}/${team_slug}-custom-secrets.tfvars"
    local error_file="${WORK_DIR}/${team_slug}-custom-secrets.error"

    echo -e "${BLUE}[INFO]${NC} Generating custom secrets configuration for team: ${GREEN}${team_slug}${NC}"
    echo -e "${BLUE}[INFO]${NC} Processing ${#onboarding_files[@]} service(s)"

    # Ensure secrets tools are available from main branch
    if ! ensure_secrets_tools; then
        echo -e "${RED}[ERROR]${NC} Cannot generate custom secrets: secrets tools unavailable"
        return 1
    fi

    local script="${SECRETS_TOOLS_DIR}/${SECRETS_SCRIPT_PATH}"

    # Run from SECRETS_TOOLS_DIR so the script can locate mandatory_secrets_template.yaml
    # via relative path (scripts/secrets/mandatory_secrets_template.yaml)
    pushd "${SECRETS_TOOLS_DIR}" > /dev/null

    local cmd="python3 ${script} ${team_slug}"
    for file in "${onboarding_files[@]}"; do
        cmd="$cmd \"$file\""
    done

    echo -e "${BLUE}[DEBUG]${NC} Running: $cmd"

    if ! eval "$cmd" > "$output_file" 2> "$error_file"; then
        echo -e "${RED}[ERROR]${NC} Failed to generate custom secrets configuration for ${team_slug}"
        echo -e "${RED}[ERROR]${NC} Error output:"
        cat "$error_file"
        popd > /dev/null
        return 1
    fi

    if [ -s "$error_file" ]; then
        echo -e "${YELLOW}[WARNING]${NC} Script produced warnings:"
        cat "$error_file"
    fi

    popd > /dev/null

    # Strip the trailing help-text comment emitted by extract_custom_secrets.py
    sed -i '/^# Add the above configuration/,$d' "$output_file"

    echo -e "${GREEN}[SUCCESS]${NC} Generated custom secrets configuration for ${team_slug}"
    echo "$output_file"
    return 0
}

# ---------------------------------------------------------------------------
# Function to update <team-slug>.auto.tfvars with freshly generated secrets.
#
# Strategy — sentinel-based surgical replacement:
#   extract_custom_secrets.py wraps ALL three list variables per service:
#
#   custom_secrets   → __BEGIN_SERVICE__  / __END_SERVICE__
#   slack_member_ids → __BEGIN_SLACK__    / __END_SLACK__
#   slack_channel    → __BEGIN_CHANNEL__  / __END_CHANNEL__
#   psirt_id         → flat team-level variable (validated identical across all services)
#
#   For each onboarding file changed in this PR this function:
#     1. Strips stale legacy comment headers
#     2. Removes old flat-value lines for psirt_id only
#     3. Removes the three sentinel sections for the changed file
#     4. Injects fresh sentinel sections into each list variable block
#     5. Appends psirt_id (flat team-level)
#     6. Collapses blank lines
#     7. Cross-PR dedup on custom_secrets (first-occurrence wins)
#
#   Data from services NOT in this PR is left completely untouched.
# ---------------------------------------------------------------------------
update_team_autotfvars_with_secrets() {
    local team_slug="$1"
    local custom_secrets_config_file="$2"
    shift 2
    local changed_onboarding_files=("$@")   # absolute paths of files changed in this PR

    local tfvars_file="${INFRA_CLONE_DIR}/${team_slug}.auto.tfvars"
    local var_prefix="${team_slug//-/_}"

    echo -e "${BLUE}[INFO]${NC} Updating ${team_slug}.auto.tfvars with custom secrets (sentinel strategy)"

    if [ ! -f "$tfvars_file" ]; then
        echo -e "${YELLOW}[WARNING]${NC} ${team_slug}.auto.tfvars not found, creating it"
        touch "$tfvars_file"
    fi

    cp "$tfvars_file" "${tfvars_file}.backup"

    # ── Step 1: Remove stale flat/comment headers from pre-sentinel runs ──────
    sed -i \
        -e '/^# Slack Notification Configuration.*$/d' \
        -e '/^# These IDs will be added to secret metadata for notifications$/d' \
        -e '/^# Slack Member IDs — per-service sentinel-wrapped.*$/d' \
        -e '/^# surgically update only the changed service.*$/d' \
        -e '/^# PSIRT ID for Mend SAST Secrets.*$/d' \
        -e '/^# PSIRT IDs for Mend SAST Secrets$/d' \
        -e '/^# One PSIRT ID per service - used to generate Mend SAST secrets dynamically$/d' \
        -e '/^# Custom Secrets Configuration (Team-Managed)$/d' \
        -e '/^# Each service'\''s secrets are wrapped with __BEGIN_SERVICE__.*$/d' \
        -e '/^# sentinels so the pipeline can surgically replace.*$/d' \
        -e '/^# Total custom secrets: [0-9]*$/d' \
        "$tfvars_file"

    # ── Step 1.5: Wipe flat (non-sentinel) entries from sentinel-managed lists ─
    # Any list entry that does NOT sit between sentinel comment markers is a
    # leftover from a hand-written or pre-sentinel run.  Since Step 4 will
    # re-inject the full correct content via sentinels, the safest approach is
    # to remove all non-sentinel rows from these three lists now so nothing
    # duplicates after injection.
    # This also handles the compact single-line form  var = ["a","b"]  by
    # collapsing the whole assignment to  var = [\n]  before Step 4 injects.
    for _flat_var in "${var_prefix}_slack_member_ids" \
                     "${var_prefix}_slack_channel" \
                     "${var_prefix}_custom_secrets"; do
        python3 - "$tfvars_file" "${_flat_var}" <<'PYEOF'
import sys, re

tfvars_file = sys.argv[1]
var_name    = sys.argv[2]

with open(tfvars_file) as f:
    lines = f.readlines()

out          = []
in_block     = False
depth        = 0
in_sentinel  = False

for line in lines:
    # Detect start of the target list block
    if not in_block and re.match(r'^' + re.escape(var_name) + r'\s*=\s*\[', line):
        # Compact single-line form: var = ["a", "b"] — replace with empty block
        # Also handles trailing inline comments: var = ["a"] # some comment
        if re.match(r'^' + re.escape(var_name) + r'\s*=\s*\[[^\]]*\]\s*(#.*)?$', line):
            out.append(re.sub(r'\[.*\](.*)', '[\n]', line, count=1))
            continue
        in_block = True
        depth    = 0
        for ch in line:
            if ch == '[': depth += 1
            if ch == ']': depth -= 1
        out.append(line)
        continue

    if in_block:
        # Track bracket depth FIRST so we know if this line closes the block
        for ch in line:
            if ch == '[': depth += 1
            if ch == ']': depth -= 1
        closes_block = (depth == 0)

        # Closing ] must always be emitted — do it before any drop logic
        if closes_block:
            out.append(line)
            in_block    = False
            in_sentinel = False
            continue

        # Track sentinel regions — keep those lines untouched
        if re.search(r'#\s*__(BEGIN|END)_(SERVICE|SLACK|CHANNEL)__', line):
            in_sentinel = 'BEGIN' in line
            out.append(line)
        elif in_sentinel:
            # Inside a sentinel region — keep the data lines
            out.append(line)
        else:
            # Outside a sentinel — drop non-empty, non-comment data lines
            # (flat entries left from hand-written or pre-sentinel runs)
            stripped = line.strip()
            if stripped and not stripped.startswith('#'):
                pass  # drop flat entry
            else:
                out.append(line)
        continue

    out.append(line)

with open(tfvars_file, 'w') as f:
    f.writelines(out)
PYEOF
    done

    # ── Step 2: Full-replace flat psirt_id only ───────────────────────────────
    # slack_member_ids, slack_channel, and custom_secrets are all sentinel lists
    # — do NOT flat-delete them here.
    # Also scrub any old-style flat psirt_ids list and slack_channel string
    # left from a previous run before the sentinel migration.
    sed -i -E \
        "/^psirt_id[[:space:]]*=.*/d; /^${var_prefix}_psirt_id[[:space:]]*=.*/d; \
         /^psirt_ids[[:space:]]*=.*/d; /^${var_prefix}_psirt_ids[[:space:]]*=.*/d" \
        "$tfvars_file"
    # Scrub old flat slack_channel = "..." lines (outside any list block)
    # by deleting lines that are a bare string assignment, not a list opening.
    sed -i -E \
        "/^${var_prefix}_slack_channel[[:space:]]*=[[:space:]]*\".*\".*$/d; \
         /^slack_channel[[:space:]]*=[[:space:]]*\".*\".*$/d" \
        "$tfvars_file"

    # ── Step 3: For each changed onboarding file, remove its sentinel sections ─
    # Surgical: only SERVICE, SLACK, and CHANNEL sections for files in *this PR*
    # are removed. Sections for other services are left in place.
    for onboarding_file in "${changed_onboarding_files[@]}"; do
        local canonical_path
        canonical_path=$(python3 -c "import os,sys; print(os.path.realpath(sys.argv[1]))" \
            "$onboarding_file" 2>/dev/null || echo "$onboarding_file")

        # Helper: remove one sentinel-type section for this file
        _remove_sentinel_section() {
            local begin_tag="$1"
            local end_tag="$2"
            if grep -qF "# ${begin_tag} ${canonical_path}" "$tfvars_file"; then
                echo -e "${BLUE}[INFO]${NC} Removing stale ${begin_tag} section for: $(basename "$onboarding_file")"
                awk -v b="  # ${begin_tag} ${canonical_path}" \
                    -v e="  # ${end_tag} ${canonical_path}" '
                    $0 == b { skip=1; next }
                    skip && $0 == e { skip=0; next }
                    skip { next }
                    { print }
                ' "$tfvars_file" > "${tfvars_file}.tmp"
                mv "${tfvars_file}.tmp" "$tfvars_file"
            fi
        }

        _remove_sentinel_section "__BEGIN_SERVICE__"  "__END_SERVICE__"
        _remove_sentinel_section "__BEGIN_SLACK__"    "__END_SLACK__"
        _remove_sentinel_section "__BEGIN_CHANNEL__"  "__END_CHANNEL__"
    done

    # ── Step 4: Inject new sentinel sections into each list variable block ────
    # Shared helper: inject sentinel rows from a config file into the closing ]
    # of a named list variable already present in the tfvars.
    # Args: var_name  begin_tag  end_tag  config_file
    _inject_into_list_block() {
        local var_name="$1"
        local begin_tag="$2"
        local end_tag="$3"
        local config_src="$4"

        # Extract every sentinel section for this begin/end tag pair from the
        # config file verbatim (preserves { } object blocks for custom_secrets).
        local sentinel_content
        sentinel_content=$(python3 - "$config_src" "$var_name" "$begin_tag" "$end_tag" <<'PYEOF'
import sys, re

config_file = sys.argv[1]
var_name    = sys.argv[2]
begin_tag   = sys.argv[3]
end_tag     = sys.argv[4]

with open(config_file) as f:
    lines = f.readlines()

# Find the target variable block
in_var    = False
var_depth = 0
out       = []

for line in lines:
    if not in_var and re.match(r'^' + re.escape(var_name) + r'\s*=\s*\[', line):
        in_var    = True
        var_depth = 0

    if in_var:
        for ch in line:
            if ch == '[': var_depth += 1
            if ch == ']': var_depth -= 1

        # Collect every sentinel-wrapped section verbatim
        if re.search(r'#\s*' + re.escape(begin_tag), line) or \
           re.search(r'#\s*' + re.escape(end_tag), line):
            out.append(line)
        elif out and not re.search(r'#\s*' + re.escape(end_tag), out[-1] if out else ''):
            # We are inside a sentinel section — keep all lines
            # (detect: last appended line was a BEGIN, not yet seen END)
            in_sentinel_sec = False
            depth_check = 0
            for l in out:
                if re.search(r'#\s*' + re.escape(begin_tag), l):
                    in_sentinel_sec = True
                if re.search(r'#\s*' + re.escape(end_tag), l):
                    in_sentinel_sec = False
            if in_sentinel_sec:
                out.append(line)

        if var_depth == 0:
            break

print(''.join(out), end='')
PYEOF
)

        if grep -qE "^${var_name}[[:space:]]*=[[:space:]]*\[" "$tfvars_file"; then
            # Block exists — inject sentinel content before the closing ]
            python3 - "$tfvars_file" "$var_name" "$sentinel_content" <<'PYEOF'
import sys, re

tfvars_file      = sys.argv[1]
var_name         = sys.argv[2]
sentinel_content = sys.argv[3]

with open(tfvars_file) as f:
    lines = f.readlines()

out       = []
in_var    = False
var_depth = 0
injected  = False

for line in lines:
    if not in_var and re.match(r'^' + re.escape(var_name) + r'\s*=\s*\[', line):
        in_var    = True
        var_depth = 0

    if in_var:
        # Count depth before deciding
        closes = False
        new_depth = var_depth
        for ch in line:
            if ch == '[': new_depth += 1
            if ch == ']': new_depth -= 1
        if new_depth == 0 and not injected:
            # About to close — inject content first
            if sentinel_content.strip():
                out.append(sentinel_content if sentinel_content.endswith('\n')
                           else sentinel_content + '\n')
            injected = True
            in_var   = False
        var_depth = new_depth

    out.append(line)

with open(tfvars_file, 'w') as f:
    f.writelines(out)
PYEOF
        else
            # Block absent — append the full variable block from config
            echo "" >> "$tfvars_file"
            python3 - "$config_src" "${var_name}" >> "$tfvars_file" <<'PYEOF'
import sys, re

config_file = sys.argv[1]
var_name    = sys.argv[2]

with open(config_file) as f:
    content = f.read()

pattern = r'^(' + re.escape(var_name) + r'\s*=\s*\[.*?\n\])'
m = re.search(pattern, content, re.MULTILINE | re.DOTALL)
if m:
    print(m.group(1))
PYEOF
        fi
    }

    # Inject new sentinel sections for the three list variables
    _inject_into_list_block "${var_prefix}_slack_channel" \
        "__BEGIN_CHANNEL__" "__END_CHANNEL__" "$custom_secrets_config_file"

    _inject_into_list_block "${var_prefix}_slack_member_ids" \
        "__BEGIN_SLACK__" "__END_SLACK__" "$custom_secrets_config_file"

    _inject_into_list_block "${var_prefix}_custom_secrets" \
        "__BEGIN_SERVICE__" "__END_SERVICE__" "$custom_secrets_config_file"

    # ── Step 5: Append flat psirt_id (team-level) ─────────────────────────────
    local psirt_id_line
    psirt_id_line=$(grep -E "^${var_prefix}_psirt_id[[:space:]]*=" \
        "$custom_secrets_config_file" 2>/dev/null || true)
    if [ -n "$psirt_id_line" ]; then
        echo "" >> "$tfvars_file"
        echo "$psirt_id_line" >> "$tfvars_file"
    fi

    # ── Step 6: Collapse accumulated blank lines ───────────────────────────────
    awk 'NF > 0 { blank=0; print; next } blank == 0 { blank=1; print }' \
        "$tfvars_file" > "${tfvars_file}.tmp"
    awk '/^[[:space:]]*$/ { blanks=blanks"\n"; next } { printf "%s", blanks; blanks=""; print }' \
        "${tfvars_file}.tmp" > "$tfvars_file"
    rm -f "${tfvars_file}.tmp"

    # ── Step 7: Cross-PR automatic deduplication ──────────────────────────────
    # extract_custom_secrets.py deduplicates within a single run, but the same
    # secret can land in two different sentinel sections across separate PRs.
    # Strategy: for each changed service's sentinel section (the ones just
    # injected), remove any secret whose name already exists in ANY OTHER
    # sentinel section. The existing section keeps ownership; the new section
    # gets a comment explaining the omission. No manual intervention needed.
    for onboarding_file in "${changed_onboarding_files[@]}"; do
        local canonical_path
        canonical_path=$(python3 -c "import os,sys; print(os.path.realpath(sys.argv[1]))" \
            "$onboarding_file" 2>/dev/null || echo "$onboarding_file")

        # Collect secret names that exist in OTHER sentinel sections
        local names_in_other_sections
        names_in_other_sections=$(
            awk -v mine="$canonical_path" '
                /^[[:space:]]*# __BEGIN_SERVICE__ / {
                    svc = substr($0, index($0, "__BEGIN_SERVICE__ ") + 18)
                    in_section = (svc != mine) ? 1 : 0
                    next
                }
                /^[[:space:]]*# __END_SERVICE__ / { in_section=0; next }
                in_section {
                    pos = match($0, /name[[:space:]]*=[[:space:]]*"[^"]+"/)
                    if (pos) {
                        val = substr($0, pos)
                        sub(/^name[[:space:]]*=[[:space:]]*"/, "", val)
                        sub(/".*/, "", val)
                        print val
                    }
                }
            ' "$tfvars_file"
        )

        [ -z "$names_in_other_sections" ] && continue

        # Build a lookup of names owned by other sections
        declare -A other_names=()
        while IFS= read -r n; do
            other_names["$n"]=1
        done <<< "$names_in_other_sections"

        # Rewrite the file: inside this service's section, remove duplicate
        # secret blocks and replace with a comment noting the owning section.
        python3 - "$tfvars_file" "$canonical_path" "${!other_names[@]}" <<'PYEOF'
import sys, re

tfvars_file  = sys.argv[1]
my_sentinel  = sys.argv[2]
skip_names   = set(sys.argv[3:])

with open(tfvars_file) as f:
    lines = f.readlines()

out          = []
in_my_sec    = False
in_obj_block = False
obj_buf      = []
removed      = []

for line in lines:
    begin = re.match(r'\s*# __BEGIN_SERVICE__ (.+)', line)
    end   = re.match(r'\s*# __END_SERVICE__ (.+)', line)

    if begin:
        in_my_sec = begin.group(1).strip() == my_sentinel
        out.append(line)
        continue

    if end:
        in_my_sec = False
        # flush any pending object block
        if in_obj_block:
            out.extend(obj_buf)
            obj_buf = []
            in_obj_block = False
        out.append(line)
        continue

    if not in_my_sec:
        out.append(line)
        continue

    # Inside our sentinel section — buffer each { ... }, block
    if re.match(r'\s*\{', line):
        in_obj_block = True
        obj_buf = [line]
        continue

    if in_obj_block:
        obj_buf.append(line)
        # Check if this line contains the name field
        m = re.search(r'name\s*=\s*"([^"]+)"', line)
        if m:
            obj_name = m.group(1)
        # Closing brace — decide whether to keep or drop
        if re.match(r'\s*\},?', line) and len(obj_buf) > 1:
            if 'obj_name' in dir() and obj_name in skip_names:
                # Find which section owns this name
                removed.append(obj_name)
                out.append(
                    f'  # [DEDUP] "{obj_name}" already defined in another service section'
                    f' — omitted here to avoid duplicate. Owner: see __BEGIN_SERVICE__ above.\n'
                )
            else:
                out.extend(obj_buf)
            obj_buf = []
            in_obj_block = False
            if 'obj_name' in dir():
                del obj_name
        continue

    out.append(line)

with open(tfvars_file, 'w') as f:
    f.writelines(out)

if removed:
    print(f"[DEDUP] Auto-removed cross-PR duplicates from {my_sentinel}: {removed}",
          file=sys.stderr)
PYEOF

        unset other_names
    done

    # ── Step 7b: Dedup slack_member_ids and slack_channel across sentinel sections
    # Two onboarding files for the same team often share identical Slack IDs /
    # channel names.  Each gets its own __BEGIN_SLACK__ / __BEGIN_CHANNEL__ block
    # so the sentinel strategy keeps per-service attribution, but duplicate string
    # values must be removed from all sections after the first occurrence.
    # Strategy: single-pass Python scan — first sentinel section to declare a
    # value owns it; every later section that repeats the same value has that line
    # silently dropped (the sentinel markers themselves are always kept).
    for _str_tag in "SLACK" "CHANNEL"; do
        python3 - "$tfvars_file" "$_str_tag" <<'PYEOF'
import sys, re

tfvars_file = sys.argv[1]
tag         = sys.argv[2]   # "SLACK" or "CHANNEL"
begin_pat   = re.compile(r'^\s*# __BEGIN_' + tag + r'__ ')
end_pat     = re.compile(r'^\s*# __END_'   + tag + r'__ ')

with open(tfvars_file) as f:
    lines = f.readlines()

seen        = set()   # string values already emitted in a previous sentinel section
out         = []
in_section  = False
first_owner = {}      # value -> sentinel path of the first owner

for line in lines:
    if begin_pat.match(line):
        in_section = True
        out.append(line)
        continue

    if end_pat.match(line):
        in_section = False
        out.append(line)
        continue

    if not in_section:
        out.append(line)
        continue

    # Inside a sentinel section — check each quoted string value on the line
    m = re.match(r'^(\s*)"([^"]+)"(,?\s*)$', line)
    if m:
        value = m.group(2)
        if value in seen:
            # Duplicate — drop silently (sentinel markers already provide context)
            pass
        else:
            seen.add(value)
            out.append(line)
    else:
        # Non-value line inside sentinel (e.g. blank, comment) — always keep
        out.append(line)

with open(tfvars_file, 'w') as f:
    f.writelines(out)

removed_count = 0
# Count how many lines were dropped (len diff)
# (already applied — just report via exit code 0, no stderr noise needed)
PYEOF
    done

    # Collapse blank lines one final time after dedup rewrites
    awk 'NF > 0 { blank=0; print; next } blank == 0 { blank=1; print }' \
        "$tfvars_file" > "${tfvars_file}.tmp"
    awk '/^[[:space:]]*$/ { blanks=blanks"\n"; next } { printf "%s", blanks; blanks=""; print }' \
        "${tfvars_file}.tmp" > "$tfvars_file"
    rm -f "${tfvars_file}.tmp"

    echo -e "${GREEN}[SUCCESS]${NC} Updated ${team_slug}.auto.tfvars (sentinel-based, cross-PR dedup applied)"
    return 0
}

# ---------------------------------------------------------------------------
# Function to scaffold main.tf for a new team branch.
# References shared modules from main via git source URL.
# ---------------------------------------------------------------------------
scaffold_team_main_tf() {
    local team_name="$1"
    local team_slug="$2"
    local use_existing_bucket="$3"
    local var_prefix="${team_slug//-/_}"
    local resource_group_name="UUC_${team_name// /_}"

    cat > "${INFRA_CLONE_DIR}/main.tf" <<EOF
##############################################################################
# UUC Infrastructure — ${team_name} Team
#
# This root configuration manages ONLY ${team_name} team resources.
# The following are owned by main (common) branch and must NOT be managed here:
#   - UUC_CICD_Admin access group
#   - sg-uuc-devops secret group
#   - uuc-ci-storage shared COS bucket
#   - custom_roles.tf (SecretsModifier IAM role)
#   - modules/ directory
##############################################################################

data "ibm_resource_instance" "secrets_manager" {
  name    = var.secrets_manager_instance_name
  service = "secrets-manager"
}

locals {
  secrets_manager_config = {
    instance_name = var.secrets_manager_instance_name
    instance_guid = data.ibm_resource_instance.secrets_manager.guid
    region        = data.ibm_resource_instance.secrets_manager.location
    endpoint_type = var.secrets_manager_endpoint_type
  }

  common_config = {
    cd_region = "eu-gb"
    cd_plan   = "standard"
    tags      = var.tags
  }
}

module "resource_group_lookup" {
  source = "git::ssh://git@github.ibm.com/genctl-cicd/uuc-infrastructure-tf-module.git//modules/resource-group-lookup?ref=main"

  resource_group_names = var.lookup_resource_groups
}

module "${team_slug}" {
  source = "git::ssh://git@github.ibm.com/genctl-cicd/uuc-infrastructure-tf-module.git//modules/team-infrastructure?ref=main"

  team_name = "${team_name}"
  team_slug = "${team_slug}"

  resource_group_name = "${resource_group_name}"

  secret_group_name        = "sg-uuc-${team_slug}"
  secret_group_description = "Secret group to store ${team_name} team's secrets"

  cd_instance_name   = "Continuous Delivery-${team_name}"
  cd_instance_region = local.common_config.cd_region
  cd_instance_plan   = local.common_config.cd_plan

  secrets_manager_instance_name = local.secrets_manager_config.instance_name
  secrets_manager_instance_guid = local.secrets_manager_config.instance_guid
  secrets_manager_region        = local.secrets_manager_config.region
  secrets_manager_endpoint_type = local.secrets_manager_config.endpoint_type

  resource_group_ids = module.resource_group_lookup.resource_group_ids

  access_groups = var.${var_prefix}_access_groups

EOF

    if [ "$use_existing_bucket" = "False" ] || [ "$use_existing_bucket" = "false" ]; then
        cat >> "${INFRA_CLONE_DIR}/main.tf" <<EOF
  cos_bucket = {
    name            = "uuc-${team_slug}-ci-storage"
    storage_class   = "onerate_active"
    region_location = local.common_config.cd_region
    force_delete    = false
  }
  cos_instance_name     = var.cos_instance_name
  cos_resource_group_id = var.cos_resource_group_id

EOF
    else
        cat >> "${INFRA_CLONE_DIR}/main.tf" <<EOF
  # Using existing COS bucket (configured in onboarding.yaml)
  cos_bucket            = null
  cos_instance_name     = null
  cos_resource_group_id = null

EOF
    fi

    cat >> "${INFRA_CLONE_DIR}/main.tf" <<EOF
  psirt_id          = var.${var_prefix}_psirt_id
  custom_secrets    = var.${var_prefix}_custom_secrets
  slack_member_ids  = var.${var_prefix}_slack_member_ids
  slack_channel     = var.${var_prefix}_slack_channel  # list — one entry per service
  provision_secrets = false

  tags = local.common_config.tags
}
EOF

    echo -e "${GREEN}[SUCCESS]${NC} Scaffolded main.tf for ${team_name}"
}

# ---------------------------------------------------------------------------
# Function to scaffold variables.tf for a new team branch.
# ---------------------------------------------------------------------------
scaffold_team_variables_tf() {
    local team_name="$1"
    local team_slug="$2"
    local var_prefix="${team_slug//-/_}"

    cat > "${INFRA_CLONE_DIR}/variables.tf" <<EOF
##############################################################################
# Provider Variables
##############################################################################

variable "ibmcloud_api_key" {
  sensitive   = true
  type        = string
  description = "IBM Cloud API Key"
}

variable "region" {
  type        = string
  default     = "us-south"
  description = "IBM Cloud region"
}

variable "tags" {
  type        = list(string)
  default     = ["uuc", "non-prod", "terraform"]
  description = "Tags to apply to all resources"
}

variable "lookup_resource_groups" {
  type        = list(string)
  default     = []
  description = "Existing resource groups to look up (e.g. Tekton_Workers, One_Pipeline_Services)"
}

variable "secrets_manager_instance_name" {
  type        = string
  description = "Secrets Manager instance name"
}

variable "secrets_manager_endpoint_type" {
  type        = string
  default     = "public"
  description = "Secrets Manager endpoint type (public or private)"
}

variable "cos_instance_name" {
  type        = string
  description = "Shared COS instance name (owned by common/main branch)"
}

variable "cos_resource_group_id" {
  type        = string
  default     = null
  description = "Resource group ID of the shared COS instance"
}

##############################################################################
# ${team_name} Team Variables
##############################################################################

variable "${var_prefix}_access_groups" {
  description = "Access groups configuration for ${team_name} team"
  type = list(object({
    name        = string
    description = string
    policies = list(object({
      name  = string
      roles = list(string)
      resources = object({
        resource_group_id    = optional(string)
        resource_instance_id = optional(string)
        service              = optional(string)
        resource_type        = optional(string)
        resource             = optional(string)
      })
    }))
    members = object({
      users           = list(string)
      service_ids     = list(string)
      iam_service_ids = list(string)
    })
  }))
  default = []
}

variable "${var_prefix}_psirt_id" {
  description = "PSIRT ID for ${team_name} team (team-level — identical across all services)"
  type        = string
  default     = ""
}

variable "${var_prefix}_custom_secrets" {
  description = "Custom secrets configuration for ${team_name} team"
  type = list(object({
    name        = string
    description = string
    group       = string
    mandatory   = bool
    type        = optional(string)
  }))
  default = []
}

variable "${var_prefix}_slack_member_ids" {
  description = "Slack member IDs for ${team_name} team (for secret notifications)"
  type        = list(string)
  default     = []
}

variable "${var_prefix}_slack_channel" {
  description = "Slack channel per service for ${team_name} team secret notifications"
  type        = list(string)
  default     = []
}
EOF

    echo -e "${GREEN}[SUCCESS]${NC} Scaffolded variables.tf for ${team_name}"
}

# ---------------------------------------------------------------------------
# Function to scaffold outputs.tf for a new team branch.
# Mirrors the pattern used on all existing team branches.
# ---------------------------------------------------------------------------
scaffold_team_outputs_tf() {
    local team_name="$1"
    local team_slug="$2"

    cat > "${INFRA_CLONE_DIR}/outputs.tf" <<EOF
##############################################################################
# Outputs — ${team_name} Team
##############################################################################

output "resource_group_id" {
  value       = module.${team_slug}.resource_group_id
  description = "${team_name} team resource group ID"
}

output "secret_group_id" {
  value       = module.${team_slug}.secret_group_id
  description = "${team_name} team secret group ID"
}

output "cd_instance_guid" {
  value       = module.${team_slug}.cd_instance_guid
  description = "${team_name} Continuous Delivery instance GUID"
}

output "cd_instance_crn" {
  value       = module.${team_slug}.cd_instance_crn
  description = "${team_name} Continuous Delivery instance CRN"
}

output "cos_bucket_id" {
  value       = module.${team_slug}.cos_bucket_id
  description = "${team_name} COS bucket ID (uuc-${team_slug}-ci-storage)"
}
EOF

    echo -e "${GREEN}[SUCCESS]${NC} Scaffolded outputs.tf for ${team_name}"
}

# ---------------------------------------------------------------------------
# Function to scaffold provider.tf for a new team branch.
# ---------------------------------------------------------------------------
scaffold_team_provider_tf() {
    cat > "${INFRA_CLONE_DIR}/provider.tf" <<EOF
provider "ibm" {
  ibmcloud_api_key = var.ibmcloud_api_key
  region           = var.region
}
EOF

    echo -e "${GREEN}[SUCCESS]${NC} Scaffolded provider.tf"
}

# ---------------------------------------------------------------------------
# Function to scaffold versions.tf for a new team branch.
# Pins to the same Terraform and IBM provider versions as existing branches.
# ---------------------------------------------------------------------------
scaffold_team_versions_tf() {
    cat > "${INFRA_CLONE_DIR}/versions.tf" <<EOF
terraform {
  required_version = "= 1.10.2"

  required_providers {
    ibm = {
      source  = "IBM-Cloud/ibm"
      version = "1.81.1"
    }
  }
}
EOF

    echo -e "${GREEN}[SUCCESS]${NC} Scaffolded versions.tf"
}

# ---------------------------------------------------------------------------
# Function to scaffold backend.tf for a new team branch.
# Uses the same remote backend (Artifactory) as all existing team branches,
# with workspace prefix tf-uuc- so each team gets its own workspace.
# ---------------------------------------------------------------------------
scaffold_team_backend_tf() {
    cat > "${INFRA_CLONE_DIR}/backend.tf" <<EOF
terraform {

  backend "remote" {
    hostname     = "na.artifactory.swg-devops.com"
    organization = "sys-wcp-genctl-team-1pl-tf-na-uuc-terraformbackend-local"
    workspaces {
      prefix = "tf-uuc-"
    }
  }
}
EOF

    echo -e "${GREEN}[SUCCESS]${NC} Scaffolded backend.tf"
}

# ---------------------------------------------------------------------------
# Function to fetch common.auto.tfvars from main branch for a new team branch.
# All shared variable values (region, tags, lookup_resource_groups, etc.) live
# in common.auto.tfvars on main — no terraform.tfvars duplication needed.
# ---------------------------------------------------------------------------
scaffold_team_terraform_tfvars() {
    echo -e "${BLUE}[INFO]${NC} Fetching common.auto.tfvars from main branch"
    git show "origin/${INFRASTRUCTURE_BRANCH}:common.auto.tfvars" \
        > "${INFRA_CLONE_DIR}/common.auto.tfvars" || {
        echo -e "${RED}[ERROR]${NC} Failed to fetch common.auto.tfvars from main"
        return 1
    }
    echo -e "${GREEN}[SUCCESS]${NC} Fetched common.auto.tfvars from main"
}

# ---------------------------------------------------------------------------
# Function to create a PR in the infrastructure repo.
#
# For a new team  : forks team branch from main, scaffolds main.tf +
#                   variables.tf, creates <team-slug>.auto.tfvars.
# For existing team: checks out team branch, updates .auto.tfvars only.
# The PR always targets the team branch (not main).
# ---------------------------------------------------------------------------
create_infrastructure_pr() {
    local team_name="$1"
    local team_slug="$2"
    local is_new_team="$3"
    local use_existing_bucket="$4"
    local secrets_config_file="$5"
    shift 5
    local changed_onboarding_files=("$@")   # passed through to update_team_autotfvars_with_secrets

    # The PR base is the team's own branch
    local team_branch="${team_slug}"

    local action="Onboard"
    if [ "$is_new_team" = "false" ]; then
        action="Update"
    fi

    local pr_title="feat: ${action} ${team_name} team infrastructure"
    local pr_body="## Automated Team Infrastructure ${action}

This PR was automatically generated by the UUC onboarding merge pipeline.

### Team Information
- **Team Name**: ${team_name}
- **Team Slug**: ${team_slug}
- **Branch**: \`${team_branch}\`
- **Action**: ${action}

### Changes
"

    if [ "$is_new_team" = "true" ]; then
        pr_body+="
- ✅ Created team branch \`${team_branch}\` from \`main\`
- ✅ Scaffolded \`main.tf\` (module source references \`?ref=main\` — no local modules copy)
- ✅ Scaffolded \`variables.tf\` with team-specific variable declarations
- ✅ Created \`${team_slug}.auto.tfvars\` with access groups configuration (Admin, User, Reader)
- ✅ Populated secrets configuration in \`${team_slug}.auto.tfvars\`

### Resources to be Provisioned
- **Resource Group**: UUC_${team_name// /_}
- **Secret Group**: sg-uuc-${team_slug}
- **Continuous Delivery Instance**: Continuous Delivery-${team_name}
- **COS Bucket**: uuc-${team_slug}-ci-storage (if not using existing)
- **Access Groups**: Admin / User / Reader (pre-populated in ${team_slug}.auto.tfvars)
- **Mandatory Secrets**: Automatically provisioned by Terraform module (GARA, Mend SAST, ServiceNow, FID)
- **Custom Secrets**: Team-managed secrets extracted from onboarding.yaml (mandatory: false)
"
    else
        pr_body+="
- ✅ Updated \`${team_slug}.auto.tfvars\` with latest secrets configuration

### Resources to be Updated
- Custom secrets configuration (add/modify/delete)
- PSIRT IDs for Mend SAST token generation
- Slack notification settings
"
    fi

    pr_body+="
### Secrets Configuration
- **Scripts source**: \`scripts/secrets/\` fetched from \`main\` branch (not present on team branches)
- **Custom Secrets**: Extracted from onboarding.yaml files (mandatory: false)
- **Mandatory Secrets**: Automatically provisioned by Terraform module (GARA, Mend SAST, ServiceNow, FID)
- **Template**: \`scripts/secrets/mandatory_secrets_template.yaml\` on \`main\`
- **Deduplication**: Multiple services with same secret = single entry

### Next Steps
1. Review \`${team_slug}.auto.tfvars\` — adjust access group members and policies as needed
2. Merge this PR into branch \`${team_branch}\`
3. Run \`terraform init && terraform plan\` on branch \`${team_branch}\` to verify
4. Run \`terraform apply\` to provision resources

### Notes
⚠️ **Module source**: \`main.tf\` references modules via \`?ref=main\`. If you need a specific module version pin it here.
⚠️ **Auto-tfvars**: \`${team_slug}.auto.tfvars\` is auto-loaded by Terraform — do not rename it.
⚠️ **Secrets scripts**: \`scripts/secrets/\` only exists on \`main\`. Run them from \`main\` or use the pipeline.

### Related
- Source: uuc-service-cicd-onboarding repository
- Pipeline: UUC Ops Merge Pipeline
- Generated by: provision_team_infrastructure.sh

---
*This PR was automatically created. Please review carefully before merging.*"

    cd "${INFRA_CLONE_DIR}"

    # ---- Set up team branch ------------------------------------------------
    if team_branch_exists "$team_slug"; then
        echo -e "${BLUE}[INFO]${NC} Fetching existing team branch: ${team_branch}"
        git fetch origin "$team_branch"
        git checkout "$team_branch"
        git reset --hard "origin/${team_branch}"
    else
        echo -e "${BLUE}[INFO]${NC} Creating new team branch from ${INFRASTRUCTURE_BRANCH}: ${team_branch}"
        git fetch origin "$INFRASTRUCTURE_BRANCH"
        git checkout -b "$team_branch" "origin/${INFRASTRUCTURE_BRANCH}"
    fi

    # ---- Scaffold Terraform files for new teams ----------------------------
    if [ "$is_new_team" = "true" ]; then
        echo -e "${BLUE}[INFO]${NC} Scaffolding Terraform configuration for ${team_name}..."
        scaffold_team_main_tf "$team_name" "$team_slug" "$use_existing_bucket"
        scaffold_team_variables_tf "$team_name" "$team_slug"
        scaffold_team_outputs_tf "$team_name" "$team_slug"
        scaffold_team_provider_tf
        scaffold_team_versions_tf
        scaffold_team_backend_tf
        scaffold_team_terraform_tfvars
    else
        # ---- Patch existing Terraform files for missing slack arguments ----
        # Team branches created before slack support was added will not have
        # slack_member_ids / slack_channel in main.tf or variables.tf.
        # Patch them in-place so Terraform does not fail with unknown variables.
        local var_prefix="${team_slug//-/_}"
        local main_tf="${INFRA_CLONE_DIR}/main.tf"
        local variables_tf="${INFRA_CLONE_DIR}/variables.tf"

        # main.tf — add slack arguments before the closing } of the module block
        if [ -f "$main_tf" ]; then
            if ! grep -q "slack_member_ids" "$main_tf"; then
                echo -e "${BLUE}[INFO]${NC} Patching main.tf: adding slack_member_ids and slack_channel arguments"
                # Insert the two slack lines before the closing "}" of the module block
                python3 - "$main_tf" "$var_prefix" <<'PYEOF'
import sys, re

main_tf    = sys.argv[1]
var_prefix = sys.argv[2]

with open(main_tf) as f:
    content = f.read()

slack_block = (
    f"\n"
    f"  slack_member_ids  = var.{var_prefix}_slack_member_ids\n"
    f"  slack_channel     = var.{var_prefix}_slack_channel  # list — one entry per service\n"
)

# Insert before the last closing } that follows "provision_secrets"
# (that is the team module block closing brace).
content = re.sub(
    r'(  provision_secrets\s*=\s*\S+\s*\n)',
    r'\1' + slack_block,
    content,
    count=1
)

with open(main_tf, 'w') as f:
    f.write(content)

print(f"Patched {main_tf}")
PYEOF
            fi
        fi

        # variables.tf — append slack variable declarations if missing
        if [ -f "$variables_tf" ]; then
            if ! grep -q "slack_member_ids" "$variables_tf"; then
                echo -e "${BLUE}[INFO]${NC} Patching variables.tf: adding slack variable declarations"
                cat >> "$variables_tf" <<EOF

variable "${var_prefix}_slack_member_ids" {
  description = "Slack member IDs for ${team_name} team (for secret notifications)"
  type        = list(string)
  default     = []
}

variable "${var_prefix}_slack_channel" {
  description = "Slack channel per service for ${team_name} team secret notifications"
  type        = list(string)
  default     = []
}
EOF
            fi
        fi
    fi

    # ---- Create / update .auto.tfvars --------------------------------------
    if ! create_or_update_team_autotfvars "$team_slug" "$is_new_team"; then
        echo -e "${RED}[ERROR]${NC} Failed to create/update ${team_slug}.auto.tfvars"
        return 1
    fi

    # ---- Merge secrets into .auto.tfvars -----------------------------------
    if [ -n "$secrets_config_file" ] && [ -f "$secrets_config_file" ]; then
        if ! update_team_autotfvars_with_secrets "$team_slug" "$secrets_config_file" "${changed_onboarding_files[@]}"; then
            echo -e "${YELLOW}[WARNING]${NC} Failed to update ${team_slug}.auto.tfvars with custom secrets"
        fi
    fi

    # ---- Create PR branch off the team branch ------------------------------
    local pr_branch="auto-infra-${team_slug}-$(date +%Y%m%d-%H%M%S)"
    echo -e "${BLUE}[INFO]${NC} Creating PR branch: ${pr_branch}"
    git checkout -b "$pr_branch"

    # ---- terraform fmt (best-effort) ---------------------------------------
    if command -v terraform &> /dev/null; then
        echo -e "${BLUE}[INFO]${NC} Running terraform fmt"
        local _fmt_cmd="terraform fmt -recursive"
        # `timeout` is a GNU coreutils command; fall back gracefully on macOS
        if command -v timeout &> /dev/null; then
            _fmt_cmd="timeout 30 ${_fmt_cmd}"
        fi
        if eval "$_fmt_cmd"; then
            echo -e "${GREEN}[SUCCESS]${NC} Terraform formatting completed"
            git add -u
        else
            echo -e "${YELLOW}[WARNING]${NC} terraform fmt failed (will be validated in PR)"
        fi
    else
        echo -e "${YELLOW}[WARNING]${NC} terraform not found, skipping format check"
    fi

    # ---- Stage changes -----------------------------------------------------
    if [ "$is_new_team" = "true" ]; then
        git add main.tf variables.tf outputs.tf provider.tf versions.tf backend.tf common.auto.tfvars
    else
        # Stage main.tf and variables.tf only if the slack patch modified them
        git add main.tf variables.tf 2>/dev/null || true
    fi
    git add "${team_slug}.auto.tfvars"

    if git diff --cached --quiet; then
        echo -e "${YELLOW}[WARNING]${NC} No changes detected — infrastructure already up to date"
        git checkout "$team_branch"
        return 2
    fi

    # ---- Commit & push -----------------------------------------------------
    git config user.name "clconc"
    git config user.email "clconc@us.ibm.com"
    git commit -m "$pr_title"

    echo -e "${BLUE}[INFO]${NC} Pushing branch to remote"
    git push origin "$pr_branch"

    # ---- Open PR via GitHub API (head → team branch, NOT main) -------------
    echo -e "${BLUE}[INFO]${NC} Creating pull request: ${pr_branch} → ${team_branch}"

    local pr_payload
    pr_payload=$(cat <<EOF
{
  "title": "$pr_title",
  "body": $(echo "$pr_body" | jq -Rs .),
  "head": "$pr_branch",
  "base": "$team_branch"
}
EOF
)

    local pr_response
    pr_response=$(curl -s -X POST \
        -H "Authorization: token ${AUTO_PR_GITHUB_TOKEN:-${GITHUB_TOKEN}}" \
        -H "Accept: application/vnd.github.v3+json" \
        "https://github.ibm.com/api/v3/repos/genctl-cicd/uuc-infrastructure-tf-module/pulls" \
        -d "$pr_payload")

    local pr_url pr_number
    pr_url=$(echo "$pr_response" | jq -r '.html_url // empty')
    pr_number=$(echo "$pr_response" | jq -r '.number // empty')

    if [ -n "$pr_url" ] && [ "$pr_url" != "null" ]; then
        echo -e "${GREEN}[SUCCESS]${NC} Pull request created successfully!"
        echo -e "${CYAN}PR #${pr_number}: ${pr_url}${NC}"
        # Expose the newly created PR URL/number to the caller via script-level vars
        CREATED_INFRA_PR_URL="$pr_url"
        CREATED_INFRA_PR_NUMBER="$pr_number"
        git checkout "$team_branch"
        return 0
    else
        echo -e "${RED}[ERROR]${NC} Failed to create pull request"
        echo "Response: $pr_response"
        git checkout "$team_branch" 2>/dev/null || true
        return 1
    fi
}

# ---------------------------------------------------------------------------
# Function to handle a deleted onboarding file:
#   1. Remove the file's __BEGIN_SERVICE__, __BEGIN_SLACK__, __BEGIN_PSIRT__
#      sentinel blocks from <team-slug>.auto.tfvars on the team branch
#   2. For every custom-secret name that was owned by the removed SERVICE section,
#      scan the rest of the file for a matching [DEDUP] comment and promote it
#      to a real secret object block
#   3. If no [DEDUP] comment exists for a removed secret, emit a warning
#
# Args:
#   $1  team_slug           — branch / tfvars file prefix
#   $2  deleted_file_path   — repo-relative path of the deleted onboarding file
#                             (used both for git show and as the sentinel key)
# ---------------------------------------------------------------------------
remove_sentinel_and_promote_dedups() {
    local team_slug="$1"
    local deleted_file_path="$2"   # repo-relative path, e.g. teams/cos/cos-onboarding.yaml

    local tfvars_file="${INFRA_CLONE_DIR}/${team_slug}.auto.tfvars"

    if [ ! -f "$tfvars_file" ]; then
        echo -e "${YELLOW}[WARNING]${NC} ${team_slug}.auto.tfvars not found — nothing to remove" >&2
        return 0
    fi

    # Derive the canonical absolute path that was used as the sentinel key.
    # The sentinel was written using os.path.realpath() against PATH_TO_WORKSPACE_REPO,
    # so we reconstruct it the same way.
    local canonical_path
    if [ -n "$PATH_TO_WORKSPACE_REPO" ]; then
        canonical_path="${PATH_TO_WORKSPACE_REPO}/${deleted_file_path}"
    else
        canonical_path="$(pwd)/${deleted_file_path}"
    fi
    # Normalise (remove double-slashes etc.)
    canonical_path=$(python3 -c "import os,sys; print(os.path.normpath(sys.argv[1]))" \
        "$canonical_path" 2>/dev/null || echo "$canonical_path")

    # Check that at least one sentinel type exists — if none do, nothing to clean up.
    local has_any_sentinel=false
    for tag in "__BEGIN_SERVICE__" "__BEGIN_SLACK__" "__BEGIN_CHANNEL__"; do
        if grep -qF "# ${tag} ${canonical_path}" "$tfvars_file"; then
            has_any_sentinel=true
            break
        fi
    done

    if [ "$has_any_sentinel" = false ]; then
        echo -e "${BLUE}[INFO]${NC} No sentinel sections found for deleted file: ${deleted_file_path}" >&2
        return 0
    fi

    echo -e "${BLUE}[INFO]${NC} Removing sentinel sections for deleted file: ${deleted_file_path}"

    # ── Step 1: Collect custom-secret names owned by the SERVICE section ──────
    # Read from the existing tfvars — source of truth for what was actually written.
    local owned_names
    owned_names=$(
        awk -v sentinel="$canonical_path" '
            /^[[:space:]]*# __BEGIN_SERVICE__ / {
                path = substr($0, index($0, "__BEGIN_SERVICE__ ") + 18)
                gsub(/^[[:space:]]+|[[:space:]]+$/, "", path)
                in_sec = (path == sentinel)
                next
            }
            /^[[:space:]]*# __END_SERVICE__ / { in_sec=0; next }
            in_sec {
                pos = match($0, /name[[:space:]]*=[[:space:]]*"[^"]+"/)
                if (pos) {
                    val = substr($0, pos)
                    sub(/^name[[:space:]]*=[[:space:]]*"/, "", val)
                    sub(/".*/, "", val)
                    print val
                }
            }
        ' "$tfvars_file"
    )

    # ── Step 2: Remove sentinel sections (SERVICE + SLACK + CHANNEL) ─────────
    # psirt_id is a flat team-level variable — no sentinel to remove.
    for tag_pair in "__BEGIN_SERVICE__ __END_SERVICE__" \
                    "__BEGIN_SLACK__ __END_SLACK__" \
                    "__BEGIN_CHANNEL__ __END_CHANNEL__"; do
        local begin_tag end_tag
        begin_tag="${tag_pair%% *}"
        end_tag="${tag_pair##* }"
        if grep -qF "# ${begin_tag} ${canonical_path}" "$tfvars_file"; then
            awk -v b="  # ${begin_tag} ${canonical_path}" \
                -v e="  # ${end_tag} ${canonical_path}" '
                $0 == b { skip=1; next }
                skip && $0 == e { skip=0; next }
                skip { next }
                { print }
            ' "$tfvars_file" > "${tfvars_file}.tmp"
            mv "${tfvars_file}.tmp" "$tfvars_file"
            echo -e "${GREEN}[SUCCESS]${NC} Removed ${begin_tag} section for: ${deleted_file_path}"
        fi
    done

    # ── Step 3 & 4: Promote [DEDUP] comments → real secret blocks ────────────
    if [ -z "$owned_names" ]; then
        echo -e "${BLUE}[INFO]${NC} No secrets were owned by the removed section — nothing to promote"
    else
        echo -e "${BLUE}[INFO]${NC} Attempting to promote orphaned [DEDUP] entries..."

        # For each secret name, read the deleted file from git history to get
        # the full object definition, then replace the [DEDUP] comment with it.
        # git show HEAD~1 works for merge commits; for a standard commit we use
        # HEAD~1 as well since the deletion was in the commit just merged.
        local git_show_ref="HEAD~1"
        if [ -n "$PR_BASEBRANCH" ]; then
            # In PR context, the deleted file is accessible at origin/PR_BASEBRANCH
            git_show_ref="origin/${PR_BASEBRANCH}"
        fi

        # Retrieve the deleted file content from git history into a temp file
        local deleted_yaml_tmp="${WORK_DIR}/deleted-$(basename "${deleted_file_path}").yaml"
        if ! git -C "${INFRA_CLONE_DIR}" show "${git_show_ref}:${deleted_file_path}" \
                > "$deleted_yaml_tmp" 2>/dev/null; then
            # Try the onboarding repo instead (the file lived there, not in infra)
            if [ -n "$PATH_TO_WORKSPACE_REPO" ]; then
                git -C "$PATH_TO_WORKSPACE_REPO" show "${git_show_ref}:${deleted_file_path}" \
                    > "$deleted_yaml_tmp" 2>/dev/null || true
            fi
        fi

        while IFS= read -r secret_name; do
            [ -z "$secret_name" ] && continue

            local dedup_pattern="# \[DEDUP\] \"${secret_name}\" already defined"
            if ! grep -qF "# [DEDUP] \"${secret_name}\"" "$tfvars_file"; then
                echo -e "${YELLOW}[WARN]${NC} No [DEDUP] comment found for orphaned secret '${secret_name}'" \
                    "— secret will be permanently absent until manually re-added" >&2
                continue
            fi

            echo -e "${BLUE}[INFO]${NC} Promoting [DEDUP] → real block for secret: ${secret_name}"

            # Extract the secret object block from the deleted yaml via Python
            local secret_block
            secret_block=$(python3 - "$deleted_yaml_tmp" "$secret_name" <<'PYEOF'
import sys, yaml

yaml_file   = sys.argv[1]
target_name = sys.argv[2]

try:
    with open(yaml_file) as f:
        config = yaml.safe_load(f) or {}
except Exception:
    sys.exit(0)

# Collect all custom_secrets entries from all services
secrets = []
for svc in config.get('services', []):
    secrets.extend(svc.get('custom_secrets', []))
# Also check top-level custom_secrets
secrets.extend(config.get('custom_secrets', []))

for s in secrets:
    if s.get('name') == target_name:
        grp   = s.get('group', '')
        desc  = s.get('description', '')
        mand  = str(s.get('mandatory', False)).lower()
        stype = s.get('type', 'arbitrary')
        print(f'  {{')
        print(f'    name        = "{s["name"]}"')
        print(f'    description = "{desc}"')
        print(f'    group       = "{grp}"')
        print(f'    mandatory   = {mand}')
        print(f'    type        = "{stype}"')
        print(f'  }},')
        sys.exit(0)

# Secret not found in yaml — emit minimal placeholder
print(f'  {{')
print(f'    name        = "{target_name}"')
print(f'    description = "Promoted from deleted onboarding file"')
print(f'    group       = ""')
print(f'    mandatory   = false')
print(f'    type        = "arbitrary"')
print(f'  }},')
PYEOF
)

            if [ -z "$secret_block" ]; then
                echo -e "${YELLOW}[WARN]${NC} Could not generate block for '${secret_name}'" \
                    "— [DEDUP] comment left in place" >&2
                continue
            fi

            # Replace the first matching [DEDUP] comment with the real block.
            # We use Python for the replacement to handle multi-line insertion
            # cleanly and avoid sed escaping pitfalls.
            python3 - "$tfvars_file" "$secret_name" "$secret_block" <<'PYEOF'
import sys, re

tfvars_file  = sys.argv[1]
secret_name  = sys.argv[2]
secret_block = sys.argv[3]

with open(tfvars_file) as f:
    content = f.read()

pattern = (
    r'[^\n]*# \[DEDUP\] "' + re.escape(secret_name) +
    r'" already defined[^\n]*\n'
)
replacement = secret_block + '\n'
new_content, n = re.subn(pattern, replacement, content, count=1)
if n:
    with open(tfvars_file, 'w') as f:
        f.write(new_content)
    print(f"[PROMOTE] Replaced [DEDUP] comment with real block for: {secret_name}",
          file=sys.stderr)
PYEOF

        done <<< "$owned_names"
    fi

    # ── Collapse blank lines ──────────────────────────────────────────────────
    awk 'NF > 0 { blank=0; print; next } blank == 0 { blank=1; print }' \
        "$tfvars_file" > "${tfvars_file}.tmp"
    awk '/^[[:space:]]*$/ { blanks=blanks"\n"; next } { printf "%s", blanks; blanks=""; print }' \
        "${tfvars_file}.tmp" > "$tfvars_file"
    rm -f "${tfvars_file}.tmp"

    echo -e "${GREEN}[SUCCESS]${NC} Deletion handling complete for: ${deleted_file_path}"
}

# ---------------------------------------------------------------------------
# Helper: read team_name from a deleted onboarding file via git history.
# Tries HEAD~1 first (merge context), then origin/PR_BASEBRANCH.
# Prints "team_name|team_slug" on stdout; returns 1 on failure.
# ---------------------------------------------------------------------------
extract_team_info_from_git_history() {
    local deleted_file_path="$1"   # repo-relative path

    local git_show_ref="HEAD~1"
    if [ -n "$PR_BASEBRANCH" ]; then
        git_show_ref="origin/${PR_BASEBRANCH}"
    fi

    # Write the deleted file to a temp file — avoids ARG_MAX issues with large YAMLs
    local yaml_tmp="${WORK_DIR}/history-$(basename "${deleted_file_path}").yaml"
    if [ -n "$PATH_TO_WORKSPACE_REPO" ]; then
        git -C "$PATH_TO_WORKSPACE_REPO" show "${git_show_ref}:${deleted_file_path}" \
            > "$yaml_tmp" 2>/dev/null || true
    else
        git show "${git_show_ref}:${deleted_file_path}" > "$yaml_tmp" 2>/dev/null || true
    fi

    if [ ! -s "$yaml_tmp" ]; then
        echo -e "${RED}[ERROR]${NC} Could not retrieve deleted file from git history: ${deleted_file_path}" >&2
        return 1
    fi

    python3 - "$yaml_tmp" <<'PYEOF'
import sys, yaml

yaml_file = sys.argv[1]
try:
    with open(yaml_file) as f:
        config = yaml.safe_load(f) or {}
except Exception as e:
    print(f"YAML parse error: {e}", file=sys.stderr)
    sys.exit(1)

team_name = config.get('team_name', '')
if not team_name:
    print("ERROR: team_name missing in deleted file", file=sys.stderr)
    sys.exit(1)

team_slug = team_name.lower().replace(' ', '-')
print(f"{team_name}|{team_slug}")
PYEOF
}

# ---------------------------------------------------------------------------
# Function: generate_zonal_regional_secrets_for_team
#
# Reads every secret from the team's onboarding file(s) that has
# type=zonal or type=regional.  For each such secret it fetches the
# latest vpcPhysicalZoneList.md from GitHub (via zone_region_map_utils.py)
# and expands the secret into N named entries — one per zone (zonal) or
# one per region (regional) — applying the deployment_targets.CD.<env>
# rules (targets, exclude, override_size).
#
# Account boundary:
#   DEV  account (ACCOUNT_TYPE=dev  or unset) → integration env only.
#   PROD account (ACCOUNT_TYPE=prod)           → staging + production.
#
# Output is a JSON file written to WORK_DIR used later by the tfvars
# update functions.  The file path is echoed to stdout on success.
#
# Args:
#   $1  team_slug
#   $2+ onboarding_files (absolute paths)
# ---------------------------------------------------------------------------
generate_zonal_regional_secrets_for_team() {
    local team_slug="$1"
    shift
    local onboarding_files=("$@")

    local output_file="${WORK_DIR}/${team_slug}-zonal-regional-secrets.json"
    local error_file="${WORK_DIR}/${team_slug}-zonal-regional-secrets.error"

    echo -e "${BLUE}[INFO]${NC} Generating zonal/regional secrets for team: ${GREEN}${team_slug}${NC}"

    # Verify zone_region_map_utils.py is reachable
    if [ ! -f "${ZONE_MAP_UTILS}" ]; then
        echo -e "${RED}[ERROR]${NC} zone_region_map_utils.py not found at: ${ZONE_MAP_UTILS}" >&2
        return 1
    fi

    # Determine which environments to process based on account type.
    # ACCOUNT_TYPE env var: "prod" → staging + production, anything else → integration.
    local envs=()
    if [ "${ACCOUNT_TYPE:-dev}" = "prod" ]; then
        envs=("staging" "production")
        echo -e "${BLUE}[INFO]${NC} Account type: PROD — processing staging + production"
    else
        envs=("integration")
        echo -e "${BLUE}[INFO]${NC} Account type: DEV — processing integration only"
    fi

    python3 - "${team_slug}" "${output_file}" "${ZONE_MAP_UTILS}" \
        "${GITHUB_TOKEN:-${GHE_TOKEN:-}}" \
        "${ACCOUNT_TYPE:-dev}" \
        "${onboarding_files[@]}" <<'PYEOF' 2>"$error_file"
import sys
import json
import os
import importlib.util
import yaml

# ── Args ─────────────────────────────────────────────────────────────────────
team_slug        = sys.argv[1]
output_file      = sys.argv[2]
utils_path       = sys.argv[3]
github_token     = sys.argv[4] or None
account_type     = sys.argv[5]               # "dev" or "prod"
onboarding_files = sys.argv[6:]

# ── Load zone_region_map_utils as a module ───────────────────────────────────
spec   = importlib.util.spec_from_file_location("zone_region_map_utils", utils_path)
zrm    = importlib.util.module_from_spec(spec)
spec.loader.exec_module(zrm)

# ── Determine target environments ────────────────────────────────────────────
target_envs = ["staging", "production"] if account_type == "prod" else ["integration"]

# ── Secrets that must ONLY be provisioned in the production account ───────────
# These secrets are skipped entirely when account_type == "dev".
# Rule: any secret whose name contains "-prod-" is prod-only.
# Explicit list kept here as an extra safety net for edge cases.
PROD_ONLY_SECRET_NAMES = {
    "service-functional-id-prod-cloud-apikey",
    "service-functional-id-prod-ghe-pat",
    "service-now-prod-iam-token",
}

def is_prod_only_secret(secret_name: str) -> bool:
    """Return True if this secret must not be provisioned on the dev account."""
    if secret_name in PROD_ONLY_SECRET_NAMES:
        return True
    # Pattern guard: any name containing "-prod-" is treated as prod-only
    if "-prod-" in secret_name:
        return True
    return False

# ── Fetch zone map once (always latest from GitHub) ──────────────────────────
try:
    zone_map = zrm.get_zone_map(github_token)
except RuntimeError as exc:
    print(f"ERROR: Could not fetch zone map: {exc}", file=sys.stderr)
    sys.exit(1)

# ── Process each onboarding file ─────────────────────────────────────────────
# Result structure: list of secret entry dicts ready for JSON output.
all_entries = []

for onboarding_file in onboarding_files:
    try:
        with open(onboarding_file) as f:
            config = yaml.safe_load(f) or {}
    except Exception as exc:
        print(f"WARNING: Could not parse {onboarding_file}: {exc}", file=sys.stderr)
        continue

    service_name  = config.get("service_name", os.path.basename(onboarding_file))
    team_name     = config.get("team_name", team_slug)
    secret_group  = f"sg-uuc-{team_slug}"
    deployment_cd = (config.get("deployment_targets") or {}).get("CD") or {}

    # Collect secrets from all sections (CI, CD, common).
    # Skip prod-only secrets when running on dev account.
    secrets_sections = config.get("secrets") or []
    zonal_regional_secrets = []
    for section in secrets_sections:
        for item in (section.get("items") or []):
            stype = (item.get("type") or "global").lower()
            if stype not in ("zonal", "regional"):
                continue
            secret_name = item["name"]
            if account_type != "prod" and is_prod_only_secret(secret_name):
                print(
                    f"INFO: Skipping prod-only secret '{secret_name}' on dev account",
                    file=sys.stderr,
                )
                continue
            zonal_regional_secrets.append({
                "name":        secret_name,
                "description": item.get("description", ""),
                "mandatory":   item.get("mandatory", False),
                "type":        stype,
                "section":     section.get("name", "unknown"),
            })

    if not zonal_regional_secrets:
        print(
            f"INFO: No zonal/regional secrets in {onboarding_file} — skipping",
            file=sys.stderr,
        )
        continue

    print(
        f"INFO: Found {len(zonal_regional_secrets)} zonal/regional secret(s) "
        f"in {os.path.basename(onboarding_file)}",
        file=sys.stderr,
    )

    # ── Per-environment expansion ─────────────────────────────────────────────
    for env in target_envs:
        dt_env_config = deployment_cd.get(env) or {}

        # Resolve provisioning targets (zones or regions) for this env
        targets = zrm.get_secret_targets(env, dt_env_config, zone_map)

        if not targets:
            print(
                f"WARNING: No targets resolved for env={env} in {onboarding_file}",
                file=sys.stderr,
            )
            continue

        for secret in zonal_regional_secrets:
            for target in targets:
                region = target["region"]
                zone   = target["zone"]   # None for regional type
                size   = target["size"]

                # Build the canonical secret label name
                label = zrm.build_secret_name(
                    secret_group=secret_group,
                    secret_name=secret["name"],
                    secret_type=secret["type"],
                    region=region,
                    zone=zone,
                )

                all_entries.append({
                    "label":        label,
                    "name":         secret["name"],
                    "description":  secret["description"],
                    "mandatory":    secret["mandatory"],
                    "type":         secret["type"],
                    "secret_group": secret_group,
                    "section":      secret["section"],
                    "env":          env,
                    "region":       region,
                    "zone":         zone,
                    "size":         size,
                    "service":      service_name,
                    "onboarding_file": onboarding_file,
                })

# ── Write output JSON ─────────────────────────────────────────────────────────
with open(output_file, "w") as f:
    json.dump(all_entries, f, indent=2)

print(
    f"INFO: Written {len(all_entries)} expanded secret entries to {output_file}",
    file=sys.stderr,
)
PYEOF

    local py_exit=$?

    if [ -s "$error_file" ]; then
        # Print all stderr lines, colouring ERROR lines red, WARNING yellow, INFO blue
        while IFS= read -r line; do
            if [[ "$line" == ERROR:* ]]; then
                echo -e "${RED}[ERROR]${NC} ${line#ERROR: }"
            elif [[ "$line" == WARNING:* ]]; then
                echo -e "${YELLOW}[WARNING]${NC} ${line#WARNING: }"
            else
                echo -e "${BLUE}[INFO]${NC} ${line#INFO: }"
            fi
        done < "$error_file"
    fi

    if [ $py_exit -ne 0 ]; then
        echo -e "${RED}[ERROR]${NC} Failed to generate zonal/regional secrets for ${team_slug}"
        return 1
    fi

    if [ ! -s "$output_file" ]; then
        echo -e "${YELLOW}[WARNING]${NC} No zonal/regional secrets generated for ${team_slug} — nothing to provision"
        return 0
    fi

    echo -e "${GREEN}[SUCCESS]${NC} Zonal/regional secrets generated for ${team_slug}: ${output_file}"
    echo "$output_file"
    return 0
}

# ---------------------------------------------------------------------------
# Function: append_zonal_regional_secrets_to_tfvars
#
# Reads the JSON produced by generate_zonal_regional_secrets_for_team() and
# appends new custom-secret entries into the team's .auto.tfvars using the
# same sentinel strategy as update_team_autotfvars_with_secrets().
#
# Each expanded zonal/regional secret is injected as a sentinel-wrapped
# object block inside the ${var_prefix}_custom_secrets list:
#
#   # __BEGIN_ZONAL_REGIONAL__ <onboarding_file>
#   {
#     name        = "sg-uuc-myteam-us-south-7x1-a-my-secret"
#     description = "..."
#     group       = "sg-uuc-myteam"
#     mandatory   = false
#     type        = "zonal"
#   },
#   ...
#   # __END_ZONAL_REGIONAL__ <onboarding_file>
#
# Entries already present (by label) are skipped to avoid duplicates.
#
# Args:
#   $1  team_slug
#   $2  json_file  (output of generate_zonal_regional_secrets_for_team)
#   $3+ changed_onboarding_files
# ---------------------------------------------------------------------------
append_zonal_regional_secrets_to_tfvars() {
    local team_slug="$1"
    local json_file="$2"
    shift 2
    local changed_onboarding_files=("$@")

    local tfvars_file="${INFRA_CLONE_DIR}/${team_slug}.auto.tfvars"
    local var_prefix="${team_slug//-/_}"

    if [ ! -f "$json_file" ] || [ ! -s "$json_file" ]; then
        echo -e "${BLUE}[INFO]${NC} No zonal/regional secrets JSON — skipping tfvars update"
        return 0
    fi

    echo -e "${BLUE}[INFO]${NC} Injecting zonal/regional secrets into ${team_slug}.auto.tfvars"

    python3 - "$tfvars_file" "$var_prefix" "$json_file" "${changed_onboarding_files[@]}" <<'PYEOF'
import sys
import json
import re
import os

tfvars_file            = sys.argv[1]
var_prefix             = sys.argv[2]
json_file              = sys.argv[3]
changed_onboarding_files = [
    os.path.realpath(p) for p in sys.argv[4:]
]

BEGIN_TAG = "__BEGIN_ZONAL_REGIONAL__"
END_TAG   = "__END_ZONAL_REGIONAL__"

# ── Load expanded entries ─────────────────────────────────────────────────────
with open(json_file) as f:
    entries = json.load(f)

if not entries:
    sys.exit(0)

# ── Read current tfvars ───────────────────────────────────────────────────────
if not os.path.exists(tfvars_file):
    print(f"WARNING: {tfvars_file} not found — cannot inject secrets", file=sys.stderr)
    sys.exit(0)

with open(tfvars_file) as f:
    content = f.read()

# ── Collect label names already present anywhere in the file ─────────────────
existing_labels = set(re.findall(r'name\s*=\s*"([^"]+)"', content))

# ── Remove stale sentinel sections for changed onboarding files ───────────────
for onboarding_file in changed_onboarding_files:
    begin_marker = f"  # {BEGIN_TAG} {onboarding_file}"
    end_marker   = f"  # {END_TAG} {onboarding_file}"
    if begin_marker in content:
        lines   = content.splitlines(keepends=True)
        out     = []
        skipping = False
        for line in lines:
            stripped = line.rstrip("\n").rstrip("\r")
            if stripped == begin_marker:
                skipping = True
                continue
            if skipping and stripped == end_marker:
                skipping = False
                continue
            if not skipping:
                out.append(line)
        content = "".join(out)

# ── Group entries by onboarding file ─────────────────────────────────────────
from collections import defaultdict
by_file: dict = defaultdict(list)
for entry in entries:
    canon = os.path.realpath(entry["onboarding_file"])
    by_file[canon].append(entry)

# ── Build sentinel blocks to inject per onboarding file ──────────────────────
custom_secrets_var = f"{var_prefix}_custom_secrets"
injection_lines: list[str] = []

for onboarding_file, file_entries in by_file.items():
    block_lines = [f"  # {BEGIN_TAG} {onboarding_file}\n"]
    injected_any = False

    for entry in file_entries:
        label = entry["label"]
        if label in existing_labels:
            block_lines.append(
                f"  # [ZONAL_REGIONAL_SKIP] \"{label}\" already present — skipped\n"
            )
            continue

        block_lines.append("  {\n")
        block_lines.append(f'    name        = "{label}"\n')
        block_lines.append(f'    description = "{entry["description"]}"\n')
        block_lines.append(f'    group       = "{entry["secret_group"]}"\n')
        block_lines.append(f'    mandatory   = {str(entry["mandatory"]).lower()}\n')
        block_lines.append(f'    type        = "{entry["type"]}"\n')
        block_lines.append("  },\n")
        existing_labels.add(label)   # prevent self-duplicates within this run
        injected_any = True

    block_lines.append(f"  # {END_TAG} {onboarding_file}\n")

    if injected_any:
        injection_lines.extend(block_lines)

if not injection_lines:
    print("INFO: All zonal/regional secrets already present — nothing to inject", file=sys.stderr)
    sys.exit(0)

# ── Find the closing ] of ${var_prefix}_custom_secrets and inject before it ───
lines   = content.splitlines(keepends=True)
out     = []
in_var  = False
depth   = 0
done    = False

for line in lines:
    if not in_var and not done and re.match(
        r"^" + re.escape(custom_secrets_var) + r"\s*=\s*\[", line
    ):
        in_var = True
        depth  = 0

    if in_var:
        new_depth = depth
        for ch in line:
            if ch == "[": new_depth += 1
            if ch == "]": new_depth -= 1

        if new_depth == 0 and not done:
            # Inject our block just before the closing ]
            out.extend(injection_lines)
            done   = True
            in_var = False
        depth = new_depth

    out.append(line)

if not done:
    # Variable block not found — append the whole thing
    out.append("\n")
    out.append(f"{custom_secrets_var} = [\n")
    out.extend(injection_lines)
    out.append("]\n")

with open(tfvars_file, "w") as f:
    f.writelines(out)

print(
    f"INFO: Injected zonal/regional secret blocks into {tfvars_file}",
    file=sys.stderr,
)
PYEOF

    local py_exit=$?
    if [ $py_exit -ne 0 ]; then
        echo -e "${RED}[ERROR]${NC} Failed to inject zonal/regional secrets into ${team_slug}.auto.tfvars"
        return 1
    fi

    echo -e "${GREEN}[SUCCESS]${NC} Zonal/regional secrets injected into ${team_slug}.auto.tfvars"
    return 0
}

# ---------------------------------------------------------------------------
# Main execution
# ---------------------------------------------------------------------------
main() {
    local exit_code=0
    local changed_files=()
    local processed_teams=()

    # ── Parse arguments ───────────────────────────────────────────────────────
    # --files <file1> [<file2> ...] — explicitly supply individual onboarding
    #   files instead of auto-detecting them via git diff.  Useful for
    #   re-running the provisioning script against already-merged onboarding
    #   files without needing to fake a PR context.
    #   Env-var equivalent: FORCE_ONBOARDING_FILES (space-separated paths).
    #
    # --dir <directory> — collect every *-onboarding.yaml|yml found under the
    #   given directory and add them to the file list (uses find_onboarding_files
    #   from onboarding_validation_utils.sh).
    #   Env-var equivalent: FORCE_ONBOARDING_DIR (single directory path).
    #
    # Both flags may be combined; --dir results are appended to --files.
    # When either is supplied, git-diff detection is skipped entirely.
    local force_files=()
    local force_dir=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --files)
                shift
                while [[ $# -gt 0 && "$1" != --* ]]; do
                    force_files+=("$1")
                    shift
                done
                ;;
            --dir)
                shift
                force_dir="$1"
                shift
                ;;
            *)
                shift
                ;;
        esac
    done

    # PROCESS_ALL_FILES=true — cron / manual full-branch run.
    # Checks out ONBOARDING_BRANCH and pre-populates force_files with every
    # *-onboarding.yaml on it, bypassing git-diff entirely.
    # Evaluated before all other env-var fallbacks so it takes highest priority.
    if [[ "${PROCESS_ALL_FILES:-false}" == "true" ]] && [ ${#force_files[@]} -eq 0 ]; then
        mapfile -t force_files < <(get_all_files_from_branch)
    fi

    # Env-var fallbacks
    if [ ${#force_files[@]} -eq 0 ] && [ -n "$FORCE_ONBOARDING_FILES" ]; then
        IFS=' ' read -ra force_files <<< "$FORCE_ONBOARDING_FILES"
    fi
    if [ -z "$force_dir" ] && [ -n "$FORCE_ONBOARDING_DIR" ]; then
        force_dir="$FORCE_ONBOARDING_DIR"
    fi

    # Expand --dir into individual files and append to force_files
    if [ -n "$force_dir" ]; then
        if [ ! -d "$force_dir" ]; then
            echo -e "${RED}[ERROR]${NC} --dir path is not a directory: ${force_dir}" >&2
            exit 1
        fi
        echo -e "${BLUE}[INFO]${NC} Scanning directory for onboarding files: ${force_dir}"
        local dir_files=()
        mapfile -t dir_files < <(find_onboarding_files "$force_dir")
        if [ ${#dir_files[@]} -eq 0 ]; then
            echo -e "${YELLOW}[WARNING]${NC} No onboarding files found in directory: ${force_dir}"
        else
            echo -e "${GREEN}[INFO]${NC} Found ${#dir_files[@]} onboarding file(s) in directory"
            force_files+=("${dir_files[@]}")
        fi
    fi

    mkdir -p "$WORK_DIR"

    # ── Handle deleted onboarding files FIRST ─────────────────────────────────
    # Deletions must be processed before the changed-files loop so that any
    # [DEDUP] promotions are in place before new secrets are injected.
    # (Skipped when --files / FORCE_ONBOARDING_FILES is used — caller controls
    # exactly which files to process; deletion cleanup is a separate concern.)
    if [ ${#force_files[@]} -eq 0 ]; then
        echo -e "${BLUE}[INFO]${NC} Detecting deleted onboarding files..."
    fi
    local deleted_files=()
    if [ ${#force_files[@]} -eq 0 ]; then
        mapfile -t deleted_files < <(get_deleted_onboarding_files 2>/dev/null || true)
    fi

    if [ ${#deleted_files[@]} -gt 0 ]; then
        echo -e "${GREEN}[INFO]${NC} Found ${#deleted_files[@]} deleted onboarding file(s) — processing..."

        # Clone / verify infrastructure repo early so we can checkout team branches
        if [ "$USE_EXISTING_CLONE" = "false" ]; then
            echo -e "${BLUE}[INFO]${NC} Cloning infrastructure repository (main) for deletion handling..."
            if ! git clone --branch "$INFRASTRUCTURE_BRANCH" "$INFRASTRUCTURE_REPO_URL" \
                    "$INFRA_CLONE_DIR" 2>&1 | grep -v "warning: "; then
                echo -e "${RED}[ERROR]${NC} Failed to clone infrastructure repository"
                exit 1
            fi
        fi

        for deleted_file in "${deleted_files[@]}"; do
            # Get the repo-relative path (strip PATH_TO_WORKSPACE_REPO prefix if present)
            local rel_path="$deleted_file"
            if [ -n "$PATH_TO_WORKSPACE_REPO" ]; then
                rel_path="${deleted_file#${PATH_TO_WORKSPACE_REPO}/}"
            fi

            echo -e "${BLUE}[INFO]${NC} Processing deletion: ${rel_path}"

            local del_team_info
            del_team_info=$(extract_team_info_from_git_history "$rel_path") || {
                echo -e "${RED}[ERROR]${NC} Cannot determine team for deleted file: ${rel_path}" >&2
                exit_code=1
                continue
            }

            local del_team_name del_team_slug
            IFS='|' read -r del_team_name del_team_slug <<< "$del_team_info"

            echo -e "${BLUE}[INFO]${NC} Deleted file belongs to team: ${GREEN}${del_team_name}${NC} (${del_team_slug})"

            # Check out the team branch
            if ! team_branch_exists "$del_team_slug"; then
                echo -e "${YELLOW}[WARN]${NC} Team branch '${del_team_slug}' does not exist — skipping deletion cleanup"
                continue
            fi

            cd "${INFRA_CLONE_DIR}"
            git fetch origin "$del_team_slug"
            git checkout "$del_team_slug"
            git reset --hard "origin/${del_team_slug}"

            remove_sentinel_and_promote_dedups "$del_team_slug" "$rel_path"

            # Commit the cleanup if anything changed
            if ! git diff --quiet "${del_team_slug}.auto.tfvars" 2>/dev/null; then
                git add "${del_team_slug}.auto.tfvars"
                git config user.name  "clconc"
                git config user.email "clconc@us.ibm.com"
                git commit -m "chore: remove sentinel for deleted ${del_team_slug} onboarding file"
                git push origin "$del_team_slug"
                echo -e "${GREEN}[SUCCESS]${NC} Pushed deletion cleanup commit for ${del_team_slug}"
            else
                echo -e "${BLUE}[INFO]${NC} No changes to commit for deletion of: ${rel_path}"
            fi

            cd - > /dev/null
        done
        echo ""
    else
        echo -e "${BLUE}[INFO]${NC} No deleted onboarding files detected"
    fi

    if [ ${#force_files[@]} -gt 0 ]; then
        # ── Explicit file list supplied — skip git-diff detection ─────────────
        echo -e "${GREEN}[INFO]${NC} Using explicitly supplied onboarding file(s) (--files / --dir / FORCE_ONBOARDING_FILES / FORCE_ONBOARDING_DIR)"
        changed_files=("${force_files[@]}")
    else
        echo -e "${BLUE}[INFO]${NC} Detecting changed onboarding files..."
        mapfile -t changed_files < <(get_changed_files_from_git)
    fi

    if [ ${#changed_files[@]} -eq 0 ]; then
        echo -e "${YELLOW}[WARNING]${NC} No onboarding files changed in this merge"
        echo -e "${BLUE}[INFO]${NC} Skipping infrastructure provisioning"
        exit 0
    fi

    echo -e "${GREEN}[INFO]${NC} Found ${#changed_files[@]} changed onboarding file(s)"
    for file in "${changed_files[@]}"; do
        echo -e "  - ${file}"
    done
    echo ""

    # ---- Clone / verify infrastructure repo --------------------------------
    if [ "$USE_EXISTING_CLONE" = "true" ]; then
        echo -e "${BLUE}[INFO]${NC} Using pre-cloned infrastructure repository: ${INFRA_CLONE_DIR}"
        echo -e "${GREEN}[SUCCESS]${NC} Infrastructure repository ready"
    else
        echo -e "${BLUE}[INFO]${NC} Cloning infrastructure repository (main)..."
        if ! git clone --branch "$INFRASTRUCTURE_BRANCH" "$INFRASTRUCTURE_REPO_URL" "$INFRA_CLONE_DIR" 2>&1 | grep -v "warning: "; then
            echo -e "${RED}[ERROR]${NC} Failed to clone infrastructure repository"
            exit 1
        fi
        echo -e "${GREEN}[SUCCESS]${NC} Infrastructure repository cloned"
    fi
    echo ""

    # ---- Group changed files by team ---------------------------------------
    declare -A team_info_map
    declare -A team_files_map

    for onboarding_file in "${changed_files[@]}"; do
        if [[ "$onboarding_file" != /* ]]; then
            if [ -n "$PATH_TO_WORKSPACE_REPO" ]; then
                onboarding_file="${PATH_TO_WORKSPACE_REPO}/${onboarding_file}"
            else
                onboarding_file="$(pwd)/${onboarding_file}"
            fi
        fi

        local team_info
        team_info=$(extract_team_info "$onboarding_file")
        if [ $? -ne 0 ]; then
            echo -e "${RED}[ERROR]${NC} Failed to extract team info from: $onboarding_file"
            exit_code=1
            continue
        fi

        IFS='|' read -r team_name team_slug use_existing_bucket <<< "$team_info"
        team_info_map["$team_slug"]="${team_name}|${use_existing_bucket}"

        if [ -z "${team_files_map[$team_slug]}" ]; then
            team_files_map["$team_slug"]="$onboarding_file"
        else
            team_files_map["$team_slug"]="${team_files_map[$team_slug]}|$onboarding_file"
        fi
    done

    # ---- Process each unique team ------------------------------------------
    for team_slug in "${!team_info_map[@]}"; do
        echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

        IFS='|' read -r team_name use_existing_bucket <<< "${team_info_map[$team_slug]}"
        echo -e "${BLUE}[INFO]${NC} Processing team: ${GREEN}${team_name}${NC} (${team_slug})"

        local is_new_team="false"
        if team_branch_exists "$team_slug"; then
            echo -e "${YELLOW}[INFO]${NC} Team branch '${team_slug}' already exists"
            echo -e "${BLUE}[INFO]${NC} Updating existing team configuration"
        else
            echo -e "${GREEN}[INFO]${NC} New team detected — provisioning infrastructure"
            is_new_team="true"
        fi

        # ---- Generate custom secrets (using scripts from main) -------------
        # Only the onboarding files changed in this PR are passed to
        # extract_custom_secrets.py. The sentinel-based update function
        # replaces only those services' sections in the tfvars — secrets from
        # unchanged services are left untouched.
        echo -e "${BLUE}[INFO]${NC} Processing custom secrets for ${team_slug}"
        IFS='|' read -ra team_onboarding_files <<< "${team_files_map[$team_slug]}"

        generate_custom_secrets_for_team "$team_slug" "${team_onboarding_files[@]}"
        local secrets_exit_code=$?
        local secrets_config_file="${WORK_DIR}/${team_slug}-custom-secrets.tfvars"

        if [ $secrets_exit_code -ne 0 ] || [ ! -f "$secrets_config_file" ]; then
            echo -e "${YELLOW}[WARNING]${NC} Failed to generate custom secrets configuration"
            secrets_config_file=""
        fi

        # ---- Generate zonal/regional secrets (zone-map expansion) ----------
        # Fetches vpcPhysicalZoneList.md live from GitHub so any new zone is
        # automatically picked up.  Only secrets with type=zonal or
        # type=regional in the onboarding file are expanded; global secrets
        # are handled by generate_custom_secrets_for_team above.
        # Account boundary: ACCOUNT_TYPE=prod → staging+production,
        #                   ACCOUNT_TYPE=dev (default) → integration only.
        echo -e "${BLUE}[INFO]${NC} Processing zonal/regional secrets for ${team_slug}"
        local zonal_regional_json_file
        zonal_regional_json_file=$(
            generate_zonal_regional_secrets_for_team "$team_slug" "${team_onboarding_files[@]}"
        )
        local zr_exit_code=$?

        if [ $zr_exit_code -ne 0 ]; then
            echo -e "${YELLOW}[WARNING]${NC} Failed to generate zonal/regional secrets — continuing without them"
            zonal_regional_json_file=""
        fi

        # ---- Create PR -----------------------------------------------------
        # Reset the script-level PR URL/number vars before each team so we
        # never pick up a stale value from a previous iteration.
        CREATED_INFRA_PR_URL=""
        CREATED_INFRA_PR_NUMBER=""

        local pr_exit_code=0
        if ! create_infrastructure_pr "$team_name" "$team_slug" "$is_new_team" "$use_existing_bucket" "$secrets_config_file" "${team_onboarding_files[@]}"; then
            pr_exit_code=$?
        fi

        if [ $pr_exit_code -eq 0 ]; then
            processed_teams+=("$team_slug")
            if [ "$is_new_team" = "true" ]; then
                echo -e "${GREEN}[SUCCESS]${NC} Infrastructure provisioning PR created for ${team_name}"
            else
                echo -e "${GREEN}[SUCCESS]${NC} Infrastructure update PR created for ${team_name}"
            fi

            # ---- Inject zonal/regional secrets into the PR branch ----------
            # The PR branch is still checked out in INFRA_CLONE_DIR at this
            # point. Appending here means the expanded secrets land in the
            # same auto.tfvars that was committed by create_infrastructure_pr,
            # giving reviewers a single diff to approve.
            if [ -n "$zonal_regional_json_file" ] && [ -f "$zonal_regional_json_file" ]; then
                if append_zonal_regional_secrets_to_tfvars \
                        "$team_slug" "$zonal_regional_json_file" "${team_onboarding_files[@]}"; then
                    echo -e "${GREEN}[SUCCESS]${NC} Zonal/regional secrets appended for ${team_name}"
                    # Amend the last commit so the zonal/regional expansion is
                    # part of the same commit rather than a separate one.
                    cd "${INFRA_CLONE_DIR}"
                    git add "${team_slug}.auto.tfvars"
                    if ! git diff --cached --quiet; then
                        git commit --amend --no-edit
                        git push --force-with-lease origin "$(git rev-parse --abbrev-ref HEAD)"
                        echo -e "${GREEN}[SUCCESS]${NC} Amended PR commit with zonal/regional secrets"
                    fi
                    cd - > /dev/null
                else
                    echo -e "${YELLOW}[WARNING]${NC} Could not append zonal/regional secrets for ${team_name}"
                fi
            fi

            # ---- Monitor PR until merged, then wait for merge pipeline -----
            # Step 1: wait_for_pr_merge polls detect_pr_phase every
            #         PR_POLL_INTERVAL_SECS seconds (default: 120) for up to
            #         PR_MONITOR_TIMEOUT_MINS minutes (default: 120).
            # Step 2: wait_for_merge_pipeline reads the pipeline_url from the
            #         PR comment posted by setup.sh and polls the Tekton API
            #         until the run reaches a terminal state.
            # Both timeout variables are configurable via pipeline params.
            if [ -n "$CREATED_INFRA_PR_URL" ]; then
                if ! wait_for_pr_merge "$CREATED_INFRA_PR_URL" "$team_slug"; then
                    echo -e "${RED}[ERROR]${NC} PR for ${team_name} was not merged within the monitoring window."
                    exit_code=1
                else
                    # PR was merged — now wait for the triggered merge pipeline
                    if ! wait_for_merge_pipeline "$CREATED_INFRA_PR_URL" "$CREATED_INFRA_PR_NUMBER" "$team_slug"; then
                        echo -e "${RED}[ERROR]${NC} Merge pipeline for ${team_name} did not succeed."
                        exit_code=1
                    fi
                fi
            else
                echo -e "${YELLOW}[WARNING]${NC} No PR URL captured for ${team_name} — skipping merge monitoring"
            fi
        elif [ $pr_exit_code -eq 2 ]; then
            echo -e "${BLUE}[INFO]${NC} No PR created for ${team_name} — already up to date"
        else
            echo -e "${RED}[ERROR]${NC} Failed to create PR for ${team_name}"
            exit_code=1
        fi

        echo ""
    done

    # ---- Summary -----------------------------------------------------------
    if [ ${#processed_teams[@]} -gt 0 ]; then
        echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        echo -e "${GREEN}[SUCCESS]${NC} Infrastructure provisioning completed for ${#processed_teams[@]} team(s)"
        echo -e "${BLUE}Teams processed:${NC}"
        for team in "${processed_teams[@]}"; do
            echo -e "  - ${team}"
        done
    else
        echo -e "${YELLOW}[INFO]${NC} No teams were provisioned"
    fi

    if [ "$USE_EXISTING_CLONE" = "false" ]; then
        echo ""
        echo -e "${BLUE}[INFO]${NC} Cleaning up temporary files..."
        rm -rf "$WORK_DIR"
    fi

    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

    exit $exit_code
}

# Run main function
main "$@"

# Made with Bob
