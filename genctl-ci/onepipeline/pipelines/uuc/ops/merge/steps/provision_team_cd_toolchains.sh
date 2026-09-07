#!/usr/bin/env bash
# =============================================================================================
# IBM Confidential
# (C) Copyright IBM Corp. 2026
# The source code for this program is not published or otherwise divested of its trade secrets,
# irrespective of what has been deposited with the U.S. Copyright Office.
# =============================================================================================

# Team CD Toolchains Provisioning Script
# This script runs in the merge pipeline of uuc-service-cicd-onboarding repo.
# It detects new/changed onboarding YAML files, then creates (or updates) a PR
# in the uuc-toolchains-tf-module repository targeting the team's dedicated
# <team-slug>-cd branch to add new CD toolchain entries.
#
# Branch strategy
# ---------------
# Each team owns a dedicated branch named <team-slug>-cd in the toolchains repo.
# For a brand-new team the branch is scaffolded by calling create-team-branch.sh
# with deployment-type "cd" (identical to the CI flow but targeting templates/cd/).
# For an existing team the branch is checked out directly.
#
# Toolchain file location
# -----------------------
# The per-team toolchain definitions live in:
#   <team-slug>-cd-toolchains.tf   (at the repo root of the team branch)
#
# CD vs CI differences
# --------------------
# The CD toolchain module uses template_type = "uuc_common_cd" and carries two
# extra module-level arguments: secrets_manager_data and
# global_toolchain_compliance_tag_v11.  Toolchain entries do NOT include
# repo_branch or repo_org (CD toolchains reference the inventory repo, not the
# app repo directly).
#
# Idempotency / duplicate detection
# ----------------------------------
# Before appending a new toolchain block the script checks whether the
# inventory_repo_url and incident_repo_url pair already appears in the .tf file.
# If both are already present the entry is skipped with an inline comment.
#
# Multiple onboarding files → single PR
# --------------------------------------
# All onboarding files belonging to the same team are batched into a single PR.

set -e  # Exit on error

# Source common utilities
source "${PATH_TO_GENCTL_CI}/onepipeline/utils/onboarding_validation_utils.sh"
source "${PATH_TO_GENCTL_CI}/onepipeline/utils/one_pipeline_utils.sh"

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
TOOLCHAINS_REPO="github.ibm.com/genctl-cicd/uuc-toolchains-tf-module"
TOOLCHAINS_REPO_URL="https://${GITHUB_TOKEN}@${TOOLCHAINS_REPO}.git"
TOOLCHAINS_MAIN_BRANCH="main"

# Temporary working directory
WORK_DIR="/tmp/uuc-cd-toolchains-provision-$$"

# Use pre-cloned toolchains repo if available, otherwise clone it fresh
if [ -n "$PATH_TO_UUC_TOOLCHAINS_REPO" ] && [ -d "$PATH_TO_UUC_TOOLCHAINS_REPO/.git" ]; then
    TOOLCHAINS_CLONE_DIR="$PATH_TO_UUC_TOOLCHAINS_REPO"
    USE_EXISTING_CLONE=true
else
    TOOLCHAINS_CLONE_DIR="${WORK_DIR}/toolchains"
    USE_EXISTING_CLONE=false
fi

# Script-level vars for the PR created by create_cd_toolchains_pr() — reset
# before each team so the caller's wait loop never picks up a stale value.
CREATED_TOOLCHAINS_PR_URL=""
CREATED_TOOLCHAINS_PR_NUMBER=""

# ---------------------------------------------------------------------------
# Banner
# ---------------------------------------------------------------------------
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${GREEN}🚀  UUC Team CD Toolchains Provisioning${NC}"
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""

# ---------------------------------------------------------------------------
# Prerequisites
# ---------------------------------------------------------------------------
check_python_available
check_python_dependencies
check_github_token

# ---------------------------------------------------------------------------
# Function: extract_toolchain_info_from_onboarding
#
# Parses an onboarding YAML file and emits a pipe-separated summary line:
#   team_name|team_slug|service_name|inventory_repo_url|incident_repo_url
#   |service_fid_dev|service_fid_prod
#
# account_type is NOT read from the YAML — it is sourced from the ACCOUNT_TYPE
# environment variable (default: "dev").
#
# CD toolchain field mapping (from onboarding.yaml):
#   repo               = inventory_repo.repo   ← inventory repo IS the app repo for CD
#   inventory_repo_url = inventory_repo.repo   ← same URL used for both repo and inventory_repo_url
#   incident_repo_url  = incident_repo.repo    ← actual incident repo from onboarding.yaml
# ---------------------------------------------------------------------------
extract_toolchain_info_from_onboarding() {
    local onboarding_file="$1"

    if [ ! -f "$onboarding_file" ]; then
        echo -e "${RED}[ERROR]${NC} Onboarding file not found: $onboarding_file" >&2
        return 1
    fi

    python3 - <<EOF
import yaml
import sys

try:
    with open('$onboarding_file', 'r') as f:
        config = yaml.safe_load(f)

    if not isinstance(config, dict):
        print("ERROR: YAML is not a valid dict", file=sys.stderr)
        sys.exit(1)

    team_name = config.get('team_name', '').strip()
    if not team_name:
        print("ERROR: 'team_name' is missing or empty", file=sys.stderr)
        sys.exit(1)

    service_name = config.get('service_name', '').strip()
    if not service_name:
        print("ERROR: 'service_name' is missing or empty", file=sys.stderr)
        sys.exit(1)

    team_slug = team_name.lower().replace(' ', '-')

    # Inventory repo — used as BOTH repo and inventory_repo_url in the CD toolchain entry.
    # In CD, the inventory repo is the application repo that the CD pipeline deploys from.
    inv_cfg  = config.get('inventory_repo', {}) or {}
    inv_repo = inv_cfg.get('repo', '').rstrip('/')
    if inv_repo and not inv_repo.endswith('.git'):
        inv_repo += '.git'

    # Incident repo — the actual incident/issue tracking repo from onboarding.yaml.
    # Mapped directly to incident_repo_url in the CD toolchain entry.
    inc_cfg  = config.get('incident_repo', {}) or {}
    inc_repo = inc_cfg.get('repo', '').rstrip('/')
    if inc_repo and not inc_repo.endswith('.git'):
        inc_repo += '.git'

    if not inv_repo:
        print("ERROR: 'inventory_repo.repo' is missing or empty", file=sys.stderr)
        sys.exit(1)

    if not inc_repo:
        print("ERROR: 'incident_repo.repo' is missing or empty", file=sys.stderr)
        sys.exit(1)

    # Service Functional IDs — must be consistent across all onboarding files for a team
    service_fid_dev  = config.get('service_fid_dev',  '').strip()
    service_fid_prod = config.get('service_fid_prod', '').strip()

    print(f"{team_name}|{team_slug}|{service_name}|{inv_repo}|{inc_repo}|{service_fid_dev}|{service_fid_prod}")

except yaml.YAMLError as e:
    print(f"ERROR: YAML parse error: {e}", file=sys.stderr)
    sys.exit(1)
except Exception as e:
    print(f"ERROR: {e}", file=sys.stderr)
    sys.exit(1)
EOF
}

# ---------------------------------------------------------------------------
# Function: patch_cd_pipeline_vars_fid
#
# Patches two values in the team's <team-slug>-cd-pipeline_vars.tf file:
#   1. "service-functional-id-email" value under common_tc_env_props
#   2. "assignee" value under common_cd_promotion_pipeline_env_props
#
# The FID email is selected based on the ACCOUNT_TYPE environment variable:
#   ACCOUNT_TYPE=dev  (default) → uses service_fid_dev
#   ACCOUNT_TYPE=prod           → uses service_fid_prod
#
# If the pipeline_vars file is not found this is treated as a warning (not an
# error) so that existing branches that pre-date the FID fields are not broken.
#
# Args:
#   $1  team_slug
#   $2  service_fid_dev
#   $3  service_fid_prod
# ---------------------------------------------------------------------------
patch_cd_pipeline_vars_fid() {
    local team_slug="$1"
    local service_fid_dev="$2"
    local service_fid_prod="$3"

    # ACCOUNT_TYPE env var — default "dev"
    local account_type="${ACCOUNT_TYPE:-dev}"
    account_type="${account_type,,}"  # lowercase
    [[ "$account_type" == "prod" ]] || account_type="dev"

    local pv_file="${TOOLCHAINS_CLONE_DIR}/${team_slug}-cd-pipeline_vars.tf"

    if [ ! -f "$pv_file" ]; then
        echo -e "${YELLOW}[WARNING]${NC} CD pipeline_vars file not found — skipping FID patch: ${pv_file}" >&2
        return 0
    fi

    # Select the FID email based on account type
    local fid_email
    if [ "$account_type" = "prod" ]; then
        fid_email="$service_fid_prod"
    else
        fid_email="$service_fid_dev"
    fi

    if [ -z "$fid_email" ]; then
        echo -e "${RED}[ERROR]${NC} service_fid_${account_type} is missing in onboarding YAML — cannot patch CD pipeline_vars for ${team_slug}" >&2
        return 1
    fi

    echo -e "${BLUE}[INFO]${NC} Patching CD pipeline_vars FID (ACCOUNT_TYPE=${account_type}): ${fid_email}"

    python3 - "$pv_file" "$fid_email" <<'PYEOF'
import sys, re

pv_file   = sys.argv[1]
fid_email = sys.argv[2]

# Placeholder strings as written in the templates — only replace when still at these values.
PLACEHOLDER_FID      = "service-functional-id-email"
PLACEHOLDER_ASSIGNEE = "assignee"

with open(pv_file) as f:
    content = f.read()

patched = False

# 1. Patch "service-functional-id-email" under common_tc_env_props
#    Only replaces when value is still the template placeholder, not a real email.
new_content = re.sub(
    r'("service-functional-id-email"\s*=\s*\{[^}]*?value\s*=\s*)"' + re.escape(PLACEHOLDER_FID) + r'"',
    lambda m: m.group(1) + f'"{fid_email}"',
    content,
    count=1,
    flags=re.DOTALL
)
if new_content != content:
    patched = True
    content = new_content
    print(f"INFO: Patched service-functional-id-email → {fid_email}", file=sys.stderr)
else:
    print(f"INFO: 'service-functional-id-email' already set or placeholder not found — skipping", file=sys.stderr)

# 2. Patch "assignee" under common_cd_promotion_pipeline_env_props
#    Only replaces when value is still the template placeholder, not a real email.
new_content = re.sub(
    r'("assignee"\s*=\s*\{[^}]*?value\s*=\s*)"' + re.escape(PLACEHOLDER_ASSIGNEE) + r'"',
    lambda m: m.group(1) + f'"{fid_email}"',
    content,
    count=1,
    flags=re.DOTALL
)
if new_content != content:
    patched = True
    content = new_content
    print(f"INFO: Patched assignee → {fid_email}", file=sys.stderr)
else:
    print(f"INFO: 'assignee' already set or placeholder not found — skipping", file=sys.stderr)

if patched:
    with open(pv_file, 'w') as f:
        f.write(content)
PYEOF
}

# ---------------------------------------------------------------------------
# Function: team_cd_branch_exists
#
# Returns 0 if <team-slug>-cd already exists on the remote, 1 otherwise.
# ---------------------------------------------------------------------------
team_cd_branch_exists() {
    local branch_name="$1"
    cd "${TOOLCHAINS_CLONE_DIR}"
    git fetch origin "$branch_name" &>/dev/null || true
    git show-ref --verify --quiet "refs/remotes/origin/${branch_name}"
}

# ---------------------------------------------------------------------------
# Function: scaffold_team_cd_branch
#
# Creates a brand-new <team-slug>-cd branch in the toolchains repo by
# delegating directly to create-team-branch.sh with deployment-type "cd".
#
# create-team-branch.sh is the canonical way to initialise a team branch;
# calling it here keeps the two code paths in sync automatically — any
# future template changes in templates/cd/ are picked up for free.
#
# Args:
#   $1  team_name      — human-readable (e.g. "Core Services")
#   $2  team_slug      — hyphenated lowercase (e.g. "core-services")
#   $3  secret_group   — e.g. "sg-uuc-core-services"
#   $4  resource_group — e.g. "UUC_Core_Services"
# ---------------------------------------------------------------------------
scaffold_team_cd_branch() {
    local team_name="$1"
    local team_slug="$2"
    local secret_group="$3"
    local resource_group="$4"
    local branch_name="${team_slug}-cd"

    echo -e "${BLUE}[INFO]${NC} Scaffolding new CD branch '${branch_name}' via create-team-branch.sh (local only, no push)..."

    # create-team-branch.sh lives on main of the toolchains repo.
    # TOOLCHAINS_CLONE_DIR is currently on main (cloned above), so the
    # scripts/ and templates/ directories are present and accessible.
    local create_branch_script="${TOOLCHAINS_CLONE_DIR}/scripts/create-team-branch.sh"

    if [ ! -f "$create_branch_script" ]; then
        echo -e "${RED}[ERROR]${NC} create-team-branch.sh not found at: ${create_branch_script}" >&2
        echo -e "${RED}[ERROR]${NC} Ensure TOOLCHAINS_CLONE_DIR is on the main branch." >&2
        return 1
    fi

    # Run from within the cloned repo so all relative paths work.
    # Pass 'yes' via stdin to bypass the interactive confirmation prompt.
    # NO_PUSH=true suppresses the final 'git push' inside create-team-branch.sh
    # so the scaffolded branch only exists locally.  The toolchain block and
    # terraform fmt are applied on top before create_cd_toolchains_pr() pushes
    # the single PR branch — keeping the remote clean until then.
    # Args: <team-name> <deployment-type> <secret-group> <resource-group>
    (
        cd "${TOOLCHAINS_CLONE_DIR}"
        git config user.name "clconc"
        git config user.email "clconc@us.ibm.com"
        echo "yes" | NO_PUSH=true bash "$create_branch_script" \
            "$team_name" \
            "cd" \
            "$secret_group" \
            "$resource_group"
    ) || {
        echo -e "${RED}[ERROR]${NC} create-team-branch.sh failed for team '${team_name}'" >&2
        return 1
    }

    # The branch now exists locally only.  Switch to it so subsequent git
    # commands in create_cd_toolchains_pr() operate on the correct branch.
    cd "${TOOLCHAINS_CLONE_DIR}"
    git checkout "$branch_name"

    echo -e "${GREEN}[SUCCESS]${NC} Scaffolded CD branch '${branch_name}' locally for ${team_name} (not yet pushed)"
}

# ---------------------------------------------------------------------------
# Function: toolchain_entry_exists_in_tf
#
# Returns 0 (true) if a toolchain block that references both
# inventory_repo_url and incident_repo_url is already present in the .tf
# file, 1 otherwise.
#
# For CD toolchains, repo = inventory_repo_url (same URL), so checking
# inventory_repo_url alone covers the repo field too.  The incident_repo_url
# is the actual incident repo from onboarding.yaml.
#
# Args:
#   $1  tf_file           — absolute path to the toolchains .tf file
#   $2  inventory_repo_url — also used as the repo field
#   $3  incident_repo_url  — incident_repo from onboarding.yaml
# ---------------------------------------------------------------------------
toolchain_entry_exists_in_tf() {
    local tf_file="$1"
    local inv_repo="$2"
    local inc_repo="$3"

    [ -f "$tf_file" ] || return 1

    # Strip trailing .git for a loose match — some entries may omit it
    local inv_bare="${inv_repo%.git}"
    local inc_bare="${inc_repo%.git}"

    python3 - <<EOF
import sys, re

tf_file  = '$tf_file'
inv_bare = '$inv_bare'
inc_bare = '$inc_bare'

with open(tf_file) as f:
    content = f.read()

def url_present(content, bare_url):
    # Match with or without trailing .git and surrounding quotes
    pattern = re.escape(bare_url) + r'(?:\.git)?["\']'
    return bool(re.search(pattern, content))

if url_present(content, inv_bare) and url_present(content, inc_bare):
    sys.exit(0)   # already present
sys.exit(1)       # not present
EOF
}

# ---------------------------------------------------------------------------
# Function: generate_toolchain_block
#
# Emits a single CD toolchain entry { ... } ready to be appended inside the
# toolchains = [ ... ] list in the <team-slug>-cd-toolchains.tf file.
#
# CD field mapping (source → toolchain .tf):
#   onboarding.yaml inventory_repo.repo → repo               (inventory repo IS the app repo for CD)
#   onboarding.yaml inventory_repo.repo → inventory_repo_url (same URL, both fields point here)
#   onboarding.yaml incident_repo.repo  → incident_repo_url  (actual incident repo)
#
# Args:
#   $1  team_slug
#   $2  service_name
#   $3  inventory_repo_url — from onboarding.yaml inventory_repo.repo; used as repo AND inventory_repo_url
#   $4  incident_repo_url  — from onboarding.yaml incident_repo.repo
# ---------------------------------------------------------------------------
generate_toolchain_block() {
    local team_slug="$1"
    local service_name="$2"
    local inv_repo="$3"   # inventory repo = app repo for CD
    local inc_repo="$4"   # actual incident repo from onboarding.yaml

    # service_slug: lowercase hyphenated form of service_name
    local service_slug team_underscore
    service_slug=$(echo "$service_name" | tr '[:upper:]' '[:lower:]' | tr '_' '-' | tr ' ' '-')
    team_underscore="${team_slug//-/_}"

    # GUID prefix = service slug  (e.g. "ns3-ntpsec-<uuid>")
    local guid
    guid=$(python3 -c "import uuid; print('${service_slug}-' + str(uuid.uuid4()))")

    # Ensure all repo URLs carry a .git suffix
    local inv_repo_git inc_repo_git
    inv_repo_git="${inv_repo%.git}.git"
    inc_repo_git="${inc_repo%.git}.git"

    cat <<EOF
    {
      guid               = "${guid}" # Generate unique GUID using 'uuidgen' locally or online tool
      name               = "${service_slug}-cd-toolchain"
      repo               = "${inv_repo_git}"          # inventory repo acts as the app repo for CD
      inventory_repo_url = "${inv_repo_git}"
      incident_repo_url  = "${inc_repo_git}"
      pipeline_name      = "${service_slug}"
      tags               = ["team:${team_slug}", "type:cd", "template:uuc_common_cd"]
      resource_grp       = var.resource_group
      # ---------------------------------------------------------------------------------
      # - ENV PROPS (toolchain) THAT WILL BE COPIED TO EACH PIPELINE OF A GIVEN TOOLCHAIN
      # ---------------------------------------------------------------------------------
      tc_env_props                = local.${team_underscore}_cd_tc_env_props
      pipeline_types_trigger_data = local.${team_underscore}_cd_pipeline_types_trigger_data
      # ---------------------------------------------------------------------------------
      # - PIPELINE SPECIFIC METADATA (pipeline) ie ENV PROPERTIES FOR A GIVEN PIPELINE
      # ---------------------------------------------------------------------------------
      pipeline_meta = local.${team_underscore}_cd_pipeline_meta_default
    }
EOF
}

# ---------------------------------------------------------------------------
# Function: append_toolchain_to_tf
#
# Inserts a new toolchain block into the toolchains = [ ... ] list inside the
# team's <team-slug>-cd-toolchains.tf file, just before the closing ].
# Uses Python for reliable bracket-depth tracking.
#
# Args:
#   $1  tf_file         — absolute path to the toolchains .tf file
#   $2  toolchain_block — multi-line HCL string to inject
# ---------------------------------------------------------------------------
append_toolchain_to_tf() {
    local tf_file="$1"
    local toolchain_block="$2"

    python3 - "$tf_file" "$toolchain_block" <<'PYEOF'
import sys, re

tf_file         = sys.argv[1]
toolchain_block = sys.argv[2]

with open(tf_file) as f:
    lines = f.readlines()

content = ''.join(lines)
start_match = re.search(r'toolchains\s*=\s*\[', content)
if not start_match:
    print("ERROR: could not locate 'toolchains = [' block in file", file=sys.stderr)
    sys.exit(1)

list_start = start_match.end()
depth = 1
list_end = None
for idx in range(list_start, len(content)):
    ch = content[idx]
    if ch == '[':
        depth += 1
    elif ch == ']':
        depth -= 1
        if depth == 0:
            list_end = idx
            break

if list_end is None:
    print("ERROR: could not locate closing ']' for toolchains list", file=sys.stderr)
    sys.exit(1)

prefix = content[:list_start]
body = content[list_start:list_end]
suffix = content[list_end:]

body = body.rstrip()
if body.endswith('}'):
    body += ','

new_content = prefix + body + '\n' + toolchain_block.rstrip('\n') + suffix

with open(tf_file, 'w') as f:
    f.write(new_content)

print(f"INFO: Appended CD toolchain block to {tf_file}", file=sys.stderr)
sys.exit(0)

PYEOF
}

# ---------------------------------------------------------------------------
# Function: create_cd_toolchains_pr
#
# Orchestrates the full flow for one team:
#   1. Create/checkout the team CD branch.
#   2. Scaffold it from templates/cd/ if new (via create-team-branch.sh).
#   3. For each onboarding file: check existing entries, append new blocks.
#   4. Create a PR branch, commit, push, open PR via GH API.
#
# Args:
#   $1  team_name
#   $2  team_slug
#   $3  is_new_branch   — "true" | "false"
#   $4+ onboarding_files (absolute paths, one per service for this team)
#
# Sets CREATED_TOOLCHAINS_PR_URL and CREATED_TOOLCHAINS_PR_NUMBER on success.
# Returns:
#   0 — PR created
#   1 — error
#   2 — no changes (all toolchains already present)
# ---------------------------------------------------------------------------
create_cd_toolchains_pr() {
    local team_name="$1"
    local team_slug="$2"
    local is_new_branch="$3"
    shift 3
    local onboarding_files=("$@")

    local team_branch="${team_slug}-cd"
    local tf_filename="${team_slug}-cd-toolchains.tf"

    local action="Onboard"
    [ "$is_new_branch" = "false" ] && action="Update"

    local pr_title="feat: Add ${team_name} CD toolchains"

    cd "${TOOLCHAINS_CLONE_DIR}"

    # ── Set up team branch ────────────────────────────────────────────────────
    if [ "$is_new_branch" = "true" ]; then
        local secret_group="sg-uuc-${team_slug}"
        local resource_group
        resource_group="UUC_$(echo "${team_name}" | tr ' ' '_')"

        scaffold_team_cd_branch "$team_name" "$team_slug" "$secret_group" "$resource_group"
    else
        echo -e "${BLUE}[INFO]${NC} Checking out existing team branch: ${team_branch}"
        git fetch origin "$team_branch"
        git checkout "$team_branch"
        git reset --hard "origin/${team_branch}"
    fi

    # ── Patch pipeline_vars FID (service-functional-id-email + assignee) ─────
    # Extract FIDs from the first onboarding file; they must be consistent
    # across all files for a given team (documented in onboarding.yaml).
    local _first_tc_info _fid_dev _fid_prod
    _first_tc_info=$(extract_toolchain_info_from_onboarding "${onboarding_files[0]}") || true
    IFS='|' read -r _ _ _ _ _ _fid_dev _fid_prod <<< "$_first_tc_info"
    patch_cd_pipeline_vars_fid "$team_slug" "$_fid_dev" "$_fid_prod"

    # ── Locate the toolchains .tf file ───────────────────────────────────────
    local tf_file="${TOOLCHAINS_CLONE_DIR}/${tf_filename}"

    if [ ! -f "$tf_file" ]; then
        echo -e "${RED}[ERROR]${NC} Toolchains file not found: ${tf_filename}" >&2
        return 1
    fi

    # ── Process each onboarding file ─────────────────────────────────────────
    local appended_count=0
    local skipped_count=0
    local skip_reasons=()
    local appended_services=()
    local added_toolchain_details=()

    for onboarding_file in "${onboarding_files[@]}"; do
        echo -e "${BLUE}[INFO]${NC} Processing: $(basename "$onboarding_file")"

        # Skip services whose cicd_profile does not require a CD toolchain
        local _profile
        _profile=$(python3 -c "
import yaml, sys
try:
    c = yaml.safe_load(open('${onboarding_file}'))
    v = c.get('cicd_profile')
    if not v:
        print('MISSING', file=sys.stderr)
        sys.exit(1)
    print(v)
except Exception as e:
    sys.exit(1)
" 2>/dev/null)
        if [ $? -ne 0 ] || [ -z "$_profile" ]; then
            echo -e "${RED}[ERROR]${NC} cicd_profile is required but not set in $(basename "$onboarding_file"). Allowed values: minimal | ci_only | ci_cd"
            exit_code=1
            continue
        fi
        if [ "$_profile" = "minimal" ] || [ "$_profile" = "ci_only" ]; then
            echo -e "${BLUE}[INFO]${NC} cicd_profile is '${_profile}' for $(basename "$onboarding_file") — CD toolchain not required, skipping"
            skip_reasons+=("$(basename "$onboarding_file"): cicd_profile=${_profile}, no CD toolchain provisioned")
            skipped_count=$(( skipped_count + 1 ))
            continue
        fi

        local tc_info
        tc_info=$(extract_toolchain_info_from_onboarding "$onboarding_file") || {
            echo -e "${RED}[ERROR]${NC} Failed to extract toolchain info from: $onboarding_file" >&2
            return 1
        }

        local t_team_name t_team_slug service_name inv_repo inc_repo _fid_dev_unused _fid_prod_unused
        IFS='|' read -r t_team_name t_team_slug service_name inv_repo inc_repo _fid_dev_unused _fid_prod_unused <<< "$tc_info"

        # Validate required fields
        if [ -z "$inv_repo" ] || [ -z "$inc_repo" ]; then
            echo -e "${YELLOW}[WARNING]${NC} Missing inventory/incident URL in: $(basename "$onboarding_file") — skipping" >&2
            skip_reasons+=("$(basename "$onboarding_file"): missing inventory or incident repo URL")
            skipped_count=$(( skipped_count + 1 ))
            continue
        fi

        # Check idempotency: is this toolchain pair already in the file?
        if toolchain_entry_exists_in_tf "$tf_file" "$inv_repo" "$inc_repo"; then
            echo -e "${BLUE}[INFO]${NC} CD toolchain for '${service_name}' already exists in ${tf_filename} — skipping"
            skip_reasons+=("${service_name}: CD toolchain already existed (inventory/incident unchanged)")
            skipped_count=$(( skipped_count + 1 ))
            continue
        fi

        # Generate and append the new toolchain block
        echo -e "${BLUE}[INFO]${NC} Appending CD toolchain block for '${service_name}'"
        local block
        block=$(generate_toolchain_block "$team_slug" "$service_name" "$inv_repo" "$inc_repo")

        if ! append_toolchain_to_tf "$tf_file" "$block"; then
            echo -e "${RED}[ERROR]${NC} Failed to append toolchain block for: ${service_name}" >&2
            return 1
        fi

        appended_services+=("$service_name")
        added_toolchain_details+=("${service_name}|${inv_repo}|${inc_repo}")
        appended_count=$(( appended_count + 1 ))
        echo -e "${GREEN}[SUCCESS]${NC} Appended CD toolchain for '${service_name}'"
    done

    # ── Bail out if nothing changed ───────────────────────────────────────────
    if [ "$appended_count" -eq 0 ] && [ "$is_new_branch" = "false" ]; then
        echo -e "${YELLOW}[WARNING]${NC} All CD toolchains already exist for ${team_name} — no PR needed"
        for reason in "${skip_reasons[@]}"; do
            echo -e "  ↳ ${reason}"
        done
        git checkout "$team_branch" 2>/dev/null || true
        return 2
    fi

    if [ "$appended_count" -eq 1 ]; then
        pr_title="feat: Add ${team_name} CD toolchain for ${appended_services[0]}"
    fi

    git config user.name  "clconc"
    git config user.email "clconc@us.ibm.com"

    local pr_branch="auto-cd-toolchains-${team_slug}-$(date +%Y%m%d-%H%M%S)"
    echo -e "${BLUE}[INFO]${NC} Creating PR branch: ${pr_branch}"

    if [ "$is_new_branch" = "true" ]; then
        # ── New team ────────────────────────────────────────────────────────────
        # The team branch only exists locally at its scaffold commit (NO_PUSH=true
        # kept create-team-branch.sh from pushing it).  The base branch for the PR
        # must exist on the remote BEFORE the PR branch diverges from it — otherwise
        # both point to the same commit and GitHub rejects with HTTP 422.
        #
        # Correct order:
        #   1. Push the local team branch as-is (scaffold state) → this becomes the PR base
        #   2. git checkout -b <pr-branch>   — branches off that same scaffold commit
        #   3. terraform fmt + git add + commit — toolchain changes land only on pr branch
        #   4. git push origin <pr-branch>   — now 1 commit ahead of origin/<team-branch> ✓
        echo -e "${BLUE}[INFO]${NC} Pushing new team base branch (scaffold state): ${team_branch}"
        git push origin "${team_branch}"
        git checkout -b "$pr_branch"
        if command -v terraform &> /dev/null; then
            echo -e "${BLUE}[INFO]${NC} Running terraform fmt"
            terraform fmt "$tf_filename" \
                && echo -e "${GREEN}[SUCCESS]${NC} Terraform formatting completed" \
                || echo -e "${YELLOW}[WARNING]${NC} terraform fmt failed"
        else
            echo -e "${YELLOW}[WARNING]${NC} terraform not found, skipping fmt"
        fi
        git add .
        if git diff --cached --quiet; then
            echo -e "${YELLOW}[WARNING]${NC} No staged changes — CD toolchains are already up to date"
            git checkout "$team_branch" 2>/dev/null || true
            return 2
        fi
        git commit -m "$pr_title"
    else
        # ── Existing team ───────────────────────────────────────────────────────
        # The team branch already exists on the remote (checked out + reset --hard
        # to origin/<team-branch>).  We must NOT commit on the team branch — doing
        # so would put the local branch ahead of origin, making the PR branch
        # identical to origin/<team-branch> and causing the GitHub API to return
        # "No commits between <base> and <head>" (HTTP 422).
        #
        # Correct order:
        #   1. Create the PR branch off the clean team-branch HEAD (no changes yet)
        #   2. terraform fmt + git add + git commit — all happen on the PR branch
        #
        # This guarantees the PR branch has exactly one new commit ahead of
        # origin/<team-branch>, with no stash or index gymnastics required.
        git checkout -b "$pr_branch"
        if command -v terraform &> /dev/null; then
            echo -e "${BLUE}[INFO]${NC} Running terraform fmt"
            terraform fmt "$tf_filename" \
                && echo -e "${GREEN}[SUCCESS]${NC} Terraform formatting completed" \
                || echo -e "${YELLOW}[WARNING]${NC} terraform fmt failed"
        else
            echo -e "${YELLOW}[WARNING]${NC} terraform not found, skipping fmt"
        fi
        git add "$tf_filename"
        if git diff --cached --quiet; then
            echo -e "${YELLOW}[WARNING]${NC} No staged changes — CD toolchains are already up to date"
            git checkout "$team_branch" 2>/dev/null || true
            return 2
        fi
        git commit -m "$pr_title"
    fi

    echo -e "${BLUE}[INFO]${NC} Pushing PR branch: ${pr_branch}"
    git push origin "$pr_branch"

    # ── Build PR body ─────────────────────────────────────────────────────────
    local pr_body
    pr_body="## Automated CD Toolchains ${action}: ${team_name}

This PR was automatically generated by the UUC onboarding merge pipeline.

### Team Information
- **Team Name**: ${team_name}
- **Team Slug**: ${team_slug}
- **Branch**: \`${team_branch}\`
- **Action**: ${action}
"

    if [ "$is_new_branch" = "true" ]; then
        pr_body+="
### Branch Scaffold
- ✅ Created new team branch \`${team_branch}\` from \`main\` templates/cd/
- ✅ Scaffolded all CD template files (\`backend.tf\`, \`common.tf\`, \`variables.tf\`, \`versions.tf\`, \`pipeline_vars.tf\`, \`pipeline_meta.tf\`, \`toolchains.tf\`)
- ✅ Placeholder substitution applied (SECRET_GROUP, RESOURCE_GROUP, TEAM_NAME variants)
"
    fi

    pr_body+="
### New CD Toolchains Added (${appended_count})
"
    for svc in "${appended_services[@]}"; do
        pr_body+="- ✅ \`${svc}\`
"
    done

    if [ "$appended_count" -gt 0 ]; then
        pr_body+="
### Added Toolchain Details
"
        local detail service_name_detail inv_repo_detail inc_repo_detail
        for detail in "${added_toolchain_details[@]}"; do
            IFS='|' read -r service_name_detail inv_repo_detail inc_repo_detail <<< "$detail"
            pr_body+="- \`${service_name_detail}\`
  - repo: \`${inv_repo_detail}\`
  - inventory repo: \`${inv_repo_detail}\`
  - incident repo: \`${inc_repo_detail}\`
"
        done
    fi

    if [ "${#skip_reasons[@]}" -gt 0 ]; then
        pr_body+="
### Already Existing / Skipped (${skipped_count})
"
        for reason in "${skip_reasons[@]}"; do
            pr_body+="- ⏭️  ${reason}
"
        done
    fi

    pr_body+="
### Files Changed
- \`${tf_filename}\`

### Idempotency Check
Each toolchain entry was verified against the existing \`${tf_filename}\` by matching the pair:
- \`inventory_repo_url\`
- \`incident_repo_url\`

Entries where both already matched were skipped with an inline comment.

### Next Steps
1. Review the appended toolchain block(s) in \`${tf_filename}\`
2. Verify the generated GUIDs are unique (replace if needed)
3. Confirm \`inventory_repo_url\` and \`incident_repo_url\` are correct
4. Merge this PR into branch \`${team_branch}\`
5. The merge pipeline will apply the Terraform configuration

### Related
- Source: uuc-service-cicd-onboarding repository
- Pipeline: UUC Ops Merge Pipeline
- Generated by: provision_team_cd_toolchains.sh

---
*This PR was automatically created. Please review carefully before merging.*"

    # ── Open PR via GitHub API (head → team branch, NOT main) ─────────────────
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
        "https://github.ibm.com/api/v3/repos/genctl-cicd/uuc-toolchains-tf-module/pulls" \
        -d "$pr_payload")

    local pr_url pr_number
    pr_url=$(echo    "$pr_response" | jq -r '.html_url // empty')
    pr_number=$(echo "$pr_response" | jq -r '.number   // empty')

    if [ -n "$pr_url" ] && [ "$pr_url" != "null" ]; then
        echo -e "${GREEN}[SUCCESS]${NC} Pull request created successfully!"
        echo -e "${CYAN}PR #${pr_number}: ${pr_url}${NC}"
        CREATED_TOOLCHAINS_PR_URL="$pr_url"
        CREATED_TOOLCHAINS_PR_NUMBER="$pr_number"
        git checkout "$team_branch" 2>/dev/null || true
        return 0
    else
        echo -e "${RED}[ERROR]${NC} Failed to create pull request"
        echo "GitHub API response: $pr_response" >&2
        git checkout "$team_branch" 2>/dev/null || true
        return 1
    fi
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
    #   files instead of auto-detecting via git diff.
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

    # ── Detect changed files ──────────────────────────────────────────────────
    if [ ${#force_files[@]} -gt 0 ]; then
        echo -e "${GREEN}[INFO]${NC} Using explicitly supplied onboarding file(s) (--files / --dir / FORCE_ONBOARDING_FILES / FORCE_ONBOARDING_DIR)"
        changed_files=("${force_files[@]}")
    else
        echo -e "${BLUE}[INFO]${NC} Detecting changed onboarding files..."
        mapfile -t changed_files < <(get_changed_files_from_git)
    fi

    if [ ${#changed_files[@]} -eq 0 ]; then
        echo -e "${YELLOW}[WARNING]${NC} No onboarding files changed in this merge"
        echo -e "${BLUE}[INFO]${NC} Skipping CD toolchains provisioning"
        exit 0
    fi

    echo -e "${GREEN}[INFO]${NC} Found ${#changed_files[@]} changed onboarding file(s)"
    for file in "${changed_files[@]}"; do
        echo -e "  - ${file}"
    done
    echo ""

    # ── Clone / verify toolchains repo ───────────────────────────────────────
    if [ "$USE_EXISTING_CLONE" = "true" ]; then
        echo -e "${BLUE}[INFO]${NC} Using pre-cloned toolchains repository: ${TOOLCHAINS_CLONE_DIR}"
        cd "$TOOLCHAINS_CLONE_DIR"
        git fetch origin "$TOOLCHAINS_MAIN_BRANCH"
        git checkout "$TOOLCHAINS_MAIN_BRANCH"
        git reset --hard "origin/${TOOLCHAINS_MAIN_BRANCH}"
        echo -e "${GREEN}[SUCCESS]${NC} Toolchains repository ready"
    else
        echo -e "${BLUE}[INFO]${NC} Cloning toolchains repository (main)..."
        if ! git clone --branch "$TOOLCHAINS_MAIN_BRANCH" "$TOOLCHAINS_REPO_URL" \
                "$TOOLCHAINS_CLONE_DIR" 2>&1 | grep -v "warning: "; then
            echo -e "${RED}[ERROR]${NC} Failed to clone toolchains repository"
            exit 1
        fi
        echo -e "${GREEN}[SUCCESS]${NC} Toolchains repository cloned"
    fi
    echo ""

    # ── Group changed files by team ───────────────────────────────────────────
    declare -A team_info_map   # team_slug → "team_name"
    declare -A team_files_map  # team_slug → "|"-separated absolute file paths

    for onboarding_file in "${changed_files[@]}"; do
        # Ensure absolute path
        if [[ "$onboarding_file" != /* ]]; then
            if [ -n "$PATH_TO_WORKSPACE_REPO" ]; then
                onboarding_file="${PATH_TO_WORKSPACE_REPO}/${onboarding_file}"
            else
                onboarding_file="$(pwd)/${onboarding_file}"
            fi
        fi

        local tc_info
        tc_info=$(extract_toolchain_info_from_onboarding "$onboarding_file") || {
            echo -e "${RED}[ERROR]${NC} Failed to extract info from: $onboarding_file" >&2
            exit_code=1
            continue
        }

        local team_name team_slug
        IFS='|' read -r team_name team_slug _ _ _ _ _ <<< "$tc_info"

        team_info_map["$team_slug"]="$team_name"

        if [ -z "${team_files_map[$team_slug]+x}" ]; then
            team_files_map["$team_slug"]="$onboarding_file"
        else
            team_files_map["$team_slug"]="${team_files_map[$team_slug]}|$onboarding_file"
        fi
    done

    # ── Process each unique team ──────────────────────────────────────────────
    for team_slug in "${!team_info_map[@]}"; do
        echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

        local team_name="${team_info_map[$team_slug]}"
        local team_branch="${team_slug}-cd"
        echo -e "${BLUE}[INFO]${NC} Processing team: ${GREEN}${team_name}${NC} (branch: ${team_branch})"

        local is_new_branch="false"
        if team_cd_branch_exists "$team_branch"; then
            echo -e "${YELLOW}[INFO]${NC} Team branch '${team_branch}' already exists"
        else
            echo -e "${GREEN}[INFO]${NC} New team detected — will scaffold CD branch from templates"
            is_new_branch="true"
        fi

        IFS='|' read -ra team_onboarding_files <<< "${team_files_map[$team_slug]}"

        # Reset script-level PR vars before each team
        CREATED_TOOLCHAINS_PR_URL=""
        CREATED_TOOLCHAINS_PR_NUMBER=""

        local pr_exit_code=0
        if ! create_cd_toolchains_pr \
            "$team_name" "$team_slug" "$is_new_branch" "${team_onboarding_files[@]}"; then
            pr_exit_code=$?
        fi

        if [ $pr_exit_code -eq 0 ]; then
            processed_teams+=("$team_slug")
            echo -e "${GREEN}[SUCCESS]${NC} CD toolchains PR created for ${team_name}"

            # ── Wait for PR to be merged ──────────────────────────────────────
            if [ -n "$CREATED_TOOLCHAINS_PR_URL" ]; then
                if ! wait_for_pr_merge "$CREATED_TOOLCHAINS_PR_URL" "$team_slug"; then
                    echo -e "${RED}[ERROR]${NC} PR for ${team_name} was not merged within the monitoring window."
                    exit_code=1
                else
                    if ! wait_for_merge_pipeline \
                            "$CREATED_TOOLCHAINS_PR_URL" \
                            "$CREATED_TOOLCHAINS_PR_NUMBER" \
                            "$team_slug"; then
                        echo -e "${RED}[ERROR]${NC} Merge pipeline for ${team_name} CD toolchains did not succeed."
                        exit_code=1
                    fi
                fi
            else
                echo -e "${YELLOW}[WARNING]${NC} No PR URL captured for ${team_name} — skipping merge monitoring"
            fi

        elif [ $pr_exit_code -eq 2 ]; then
            echo -e "${BLUE}[INFO]${NC} No PR created for ${team_name} — CD toolchains already up to date"
        else
            echo -e "${RED}[ERROR]${NC} Failed to create CD toolchains PR for ${team_name}"
            exit_code=1
        fi

        echo ""
    done

    # ── Summary ───────────────────────────────────────────────────────────────
    if [ ${#processed_teams[@]} -gt 0 ]; then
        echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        echo -e "${GREEN}[SUCCESS]${NC} CD toolchains provisioning completed for ${#processed_teams[@]} team(s)"
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
