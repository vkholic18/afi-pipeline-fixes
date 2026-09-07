#!/usr/bin/env bash
# =============================================================================================
# IBM Confidential
# (C) Copyright IBM Corp. 2026
# The source code for this program is not published or otherwise divested of its trade secrets,
# irrespective of what has been deposited with the U.S. Copyright Office.
# =============================================================================================
#
# run_manual_onboarding.sh
#
# Manual pipeline step for UUC onboarding provisioning.
# Runs as a manual-trigger pipeline task using the same provisioning scripts
# as the merge pipeline — no code duplication.
#
# Every input is read from env properties set in the toolchain UI.
# Optionally, PIPELINE_MODE and ONBOARDING_FILE can also be passed as
# CLI arguments (useful for local debugging).
#
# ── Required env properties ───────────────────────────────────────────────
#
#   GITHUB_TOKEN               GHE personal access token
#   PIPELINE_MODE              ci | cd | infra | compliance
#
# ── Optional env properties ───────────────────────────────────────────────
#
#   PROCESS_ALL_FILES          true | false  (default: false)
#                              true  → full branch scan; checks out
#                                      ONBOARDING_BRANCH and processes every
#                                      *-onboarding.yaml on it
#                              false → explicit-file mode; ONBOARDING_FILES required
#   ONBOARDING_FILES           Space-separated list of one or more *-onboarding.yaml
#                              paths to process. Relative paths are resolved under
#                              PATH_TO_WORKSPACE_REPO.
#                              Required when PROCESS_ALL_FILES=false.
#                              Examples:
#                                Single : ONBOARDING_FILES=procurement_service-onboarding.yaml
#                                Multiple: ONBOARDING_FILES="auth-service-onboarding.yaml procurement_service-onboarding.yaml"
#   ONBOARDING_BRANCH          Branch to check out when PROCESS_ALL_FILES=true
#                              Default: current HEAD of PATH_TO_WORKSPACE_REPO
#   ACCOUNT_TYPE               dev | prod  (default: dev)
#
# ── Pipeline-injected env vars (set by one-pipeline framework) ────────────
#
#   PATH_TO_WORKSPACE_REPO             uuc-service-cicd-onboarding clone
#   PATH_TO_GENCTL_CI                  genctl-ci repo root
#   PATH_TO_UUC_TOOLCHAINS_REPO        uuc-toolchains-tf-module clone
#   PATH_TO_UUC_INFRASTRUCTURE_REPO    uuc-infrastructure-tf-module clone
#   WORKSPACE                          pipeline workspace root
#
# ── CLI usage (for local debugging) ──────────────────────────────────────
#
#   Single file:
#     ./run_manual_onboarding.sh ci procurement_service-onboarding.yaml
#
#   Multiple files:
#     ./run_manual_onboarding.sh ci auth-service-onboarding.yaml procurement_service-onboarding.yaml
#
#   Full branch scan:
#     ./run_manual_onboarding.sh ci --all
#     ./run_manual_onboarding.sh ci --all --branch dcms-onboarding
#
#   No args — all from env properties (pipeline trigger):
#     PIPELINE_MODE=ci PROCESS_ALL_FILES=true ./run_manual_onboarding.sh
#     PIPELINE_MODE=ci ONBOARDING_FILES="auth-service-onboarding.yaml procurement_service-onboarding.yaml" ./run_manual_onboarding.sh
# =============================================================================================
set -euo pipefail

# ─── Resolve PIPELINE_MODE: CLI arg $1 overrides env property ─────────────────
if [ $# -ge 1 ] && [[ "$1" != --* ]]; then
  PIPELINE_MODE="$1"
  shift
fi

if [ -z "${PIPELINE_MODE:-}" ]; then
  echo "[ERROR] PIPELINE_MODE is required."
  echo ""
  echo "Set it as an env property or pass as the first argument:"
  echo "  PIPELINE_MODE=ci PROCESS_ALL_FILES=true ./run_manual_onboarding.sh"
  echo "  ./run_manual_onboarding.sh <ci|cd|infra|compliance> [--all] [--branch <branch>]"
  exit 1
fi

# ─── Defaults from env properties ────────────────────────────────────────────
PROCESS_ALL_FILES="${PROCESS_ALL_FILES:-false}"
ONBOARDING_FILES="${ONBOARDING_FILES:-}"   # space-separated list; may also be set as positional args
ONBOARDING_BRANCH="${ONBOARDING_BRANCH:-}"
ACCOUNT_TYPE="${ACCOUNT_TYPE:-dev}"

# ─── CLI flags / positional args override env properties ──────────────────────
# Bare positional args are treated as onboarding file paths (single or multiple).
while [[ $# -gt 0 ]]; do
  case "$1" in
    --all)
      PROCESS_ALL_FILES="true"
      shift
      ;;
    --branch)
      ONBOARDING_BRANCH="$2"
      shift 2
      ;;
    --account-type)
      ACCOUNT_TYPE="$2"
      shift 2
      ;;
    -*)
      echo "[ERROR] Unknown flag: $1"
      exit 1
      ;;
    *)
      # Accumulate bare positional args as space-separated file list
      if [ "$PROCESS_ALL_FILES" = "false" ]; then
        ONBOARDING_FILES="${ONBOARDING_FILES:+$ONBOARDING_FILES }$1"
      fi
      shift
      ;;
  esac
done

# ─── Validate pipeline-injected paths are present ────────────────────────────
for var in PATH_TO_WORKSPACE_REPO PATH_TO_GENCTL_CI PATH_TO_UUC_TOOLCHAINS_REPO; do
  if [ -z "${!var:-}" ]; then
    echo "[ERROR] $var is not set. Ensure it is configured as a pipeline env property."
    exit 1
  fi
done

# ─── Resolve script path from PIPELINE_MODE ───────────────────────────────────
MERGE_STEPS="${PATH_TO_GENCTL_CI}/onepipeline/pipelines/uuc/ops/merge/steps"

case "$PIPELINE_MODE" in
  ci)          SCRIPT_PATH="$MERGE_STEPS/provision_team_ci_toolchains.sh" ;;
  cd)          SCRIPT_PATH="$MERGE_STEPS/provision_team_cd_toolchains.sh" ;;
  infra)       SCRIPT_PATH="$MERGE_STEPS/provision_team_infrastructure.sh" ;;
  compliance)  SCRIPT_PATH="$MERGE_STEPS/create_compliance_repos.sh" ;;
  *)
    echo "[ERROR] Invalid PIPELINE_MODE: $PIPELINE_MODE"
    echo "Expected: ci | cd | infra | compliance"
    exit 1
    ;;
esac

# ─── Validate required values ─────────────────────────────────────────────────
if [ -z "${GITHUB_TOKEN:-}" ]; then
  echo "[ERROR] GITHUB_TOKEN is required"
  exit 1
fi

if [ "$PROCESS_ALL_FILES" = "false" ] && [ -z "$ONBOARDING_FILES" ]; then
  echo "[ERROR] ONBOARDING_FILES is required when PROCESS_ALL_FILES=false"
  echo ""
  echo "Options:"
  echo "  Single : ONBOARDING_FILES=procurement_service-onboarding.yaml"
  echo "  Multiple: ONBOARDING_FILES=\"auth-service-onboarding.yaml procurement_service-onboarding.yaml\""
  echo "  Or set PROCESS_ALL_FILES=true to process the entire branch"
  exit 1
fi

# ─── Resolve each file to absolute path ───────────────────────────────────────
# Split ONBOARDING_FILES on spaces into an array, resolve relative paths.
declare -a RESOLVED_FILES=()
if [ "$PROCESS_ALL_FILES" = "false" ]; then
  IFS=' ' read -ra _raw_files <<< "$ONBOARDING_FILES"
  for _f in "${_raw_files[@]}"; do
    if [[ "$_f" != /* ]]; then
      _f="${PATH_TO_WORKSPACE_REPO}/${_f}"
    fi
    RESOLVED_FILES+=("$_f")
  done
fi

# ─── Export env vars consumed by provisioning scripts ─────────────────────────
export PATH_TO_GENCTL_CI
export PATH_TO_WORKSPACE_REPO
# ONBOARDING_REPO_PATH: stable pointer read by get_all_files_from_branch()
# before one_pipeline_utils.sh can overwrite PATH_TO_WORKSPACE_REPO.
export ONBOARDING_REPO_PATH="${PATH_TO_WORKSPACE_REPO}"
export PATH_TO_UUC_TOOLCHAINS_REPO
export PATH_TO_UUC_INFRASTRUCTURE_REPO="${PATH_TO_UUC_INFRASTRUCTURE_REPO:-}"
export GH_TOKEN="${GH_TOKEN:-$GITHUB_TOKEN}"
export GITHUB_TOKEN
export ACCOUNT_TYPE
export PROCESS_ALL_FILES
[ -n "$ONBOARDING_BRANCH" ] && export ONBOARDING_BRANCH

# ─── Set up symlink workspace ─────────────────────────────────────────────────
WORKSPACE_APP_PATH="${WORKSPACE:-/tmp}/uuc-onboarding-cron-workspace"
mkdir -p "$WORKSPACE_APP_PATH"
ln -sfn "$PATH_TO_WORKSPACE_REPO"       "$WORKSPACE_APP_PATH/uuc-service-cicd-onboarding"
ln -sfn "$PATH_TO_UUC_TOOLCHAINS_REPO"  "$WORKSPACE_APP_PATH/uuc-toolchains-tf-module"

# ─── Print resolved config ────────────────────────────────────────────────────
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  UUC Onboarding — Manual Pipeline Run"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  PIPELINE_MODE              : $PIPELINE_MODE"
echo "  PROCESS_ALL_FILES          : $PROCESS_ALL_FILES"
echo "  ACCOUNT_TYPE               : $ACCOUNT_TYPE"
echo "  PATH_TO_WORKSPACE_REPO     : $PATH_TO_WORKSPACE_REPO"
echo "  PATH_TO_UUC_TOOLCHAINS_REPO: $PATH_TO_UUC_TOOLCHAINS_REPO"
echo "  PATH_TO_GENCTL_CI          : $PATH_TO_GENCTL_CI"
echo "  WORKSPACE_APP_PATH         : $WORKSPACE_APP_PATH"
echo "  Script                     : $SCRIPT_PATH"

if [ "$PROCESS_ALL_FILES" = "true" ]; then
  if [ -n "${ONBOARDING_BRANCH:-}" ]; then
    echo "  ONBOARDING_BRANCH          : $ONBOARDING_BRANCH (explicit)"
  else
    _cur=$(git -C "$PATH_TO_WORKSPACE_REPO" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "unknown")
    echo "  ONBOARDING_BRANCH          : ${_cur} (current HEAD of PATH_TO_WORKSPACE_REPO)"
  fi
else
  echo "  ONBOARDING_FILES (${#RESOLVED_FILES[@]}):"
  for _f in "${RESOLVED_FILES[@]}"; do
    echo "    - $_f"
  done
fi
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# ─── Run ──────────────────────────────────────────────────────────────────────
if [ "$PROCESS_ALL_FILES" = "true" ]; then
  bash "$SCRIPT_PATH"
else
  bash "$SCRIPT_PATH" --files "${RESOLVED_FILES[@]}"
fi

# Made with Bob
