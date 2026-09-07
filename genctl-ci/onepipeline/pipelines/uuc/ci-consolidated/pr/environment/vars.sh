#!/usr/bin/env bash
# =============================================================================================
# IBM Confidential
# (C) Copyright IBM Corp. 2026
# The source code for this program is not published or otherwise divested of its trade secrets,
# irrespective of what has been deposited with the U.S. Copyright Office.
# =============================================================================================

### Used in check pr title and commits ###
export WORKSPACE_ROOT="NO_NEED_LOCAL_PARSING" 

# The save artifacts in PR to master of razee deals only with the first image
export SAVE_ARTIFACTS_ONLY_FIRST_IMAGE_MODE="true"
export SAVE_ARTIFACTS_SKIP_PACKAGES="true"

# Extract the endpoint, this gives us stuff like eu-gb, us-south, etc
ENDPOINT=$(echo ${PIPELINE_RUN_URL##*ibm:} | cut -d ':' -f 2)

export ICR_MIGRATION_MODE="true"

# Gets used for all common utilities for CI/CD
export PATH_TO_CICD_UTILS="${WORKSPACE}/${CI_CD_UTILS_REPO_NAME}"

