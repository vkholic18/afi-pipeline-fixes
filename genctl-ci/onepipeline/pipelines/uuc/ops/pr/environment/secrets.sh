#!/usr/bin/env bash
# =============================================================================================
# IBM Confidential
# (C) Copyright IBM Corp. 2026
# The source code for this program is not published or otherwise divested of its trade secrets,
# irrespective of what has been deposited with the U.S. Copyright Office.
# =============================================================================================

export IBM_CLOUD_COS_API_KEY=$(get_env "cos-api-key")
export GIT_TOKEN_PATH="${WORKSPACE}/git-token"
export GITHUB_API_KEY=$(cat ${GIT_TOKEN_PATH})
