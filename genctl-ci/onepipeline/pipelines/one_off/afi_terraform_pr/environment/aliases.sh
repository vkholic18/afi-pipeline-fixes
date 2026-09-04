#!/usr/bin/env bash
# =============================================================================================
# IBM Confidential
# (C) Copyright IBM Corp. 2023
# The source code for this program is not published or otherwise divested of its trade secrets,
# irrespective of what has been deposited with the U.S. Copyright Office.
# =============================================================================================

export TF_WORKSPACE=${workspace_name:-}
export WORKSPACE_REPO_NAME=${PIPELINE_REPO_NAME:-$(get_env "WORKSPACE_REPO_NAME" "")}
export PATH_TO_WORKSPACE_REPO="${WORKSPACE}/${WORKSPACE_REPO_NAME}"
export PATH_TO_WORKSPACE=${PATH_TO_WORKSPACE_REPO}

# Used in auto-merge
# Use PR_ID if set, otherwise keep PR_NUMBER from vars.sh (extracted from PR_URL)
export PR_NUMBER=${PR_ID:-${PR_NUMBER:-}}
export REPOSITORY_NAME=${ORG_AND_REPO:-}
export GHE_API_URL=${IBM_GITHUB_API_URI_BASE:-${GITHUB_API_URL:-https://github.ibm.com/api/v3}}
export GHE_API_TOKEN=${GH_TOKEN:-${GITHUB_API_KEY:-}}
export PR_SHA=${PR_HEADSHA:-}