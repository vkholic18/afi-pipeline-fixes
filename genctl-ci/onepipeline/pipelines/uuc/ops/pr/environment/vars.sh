#!/usr/bin/env bash
# =============================================================================================
# IBM Confidential
# (C) Copyright IBM Corp. 2026
# The source code for this program is not published or otherwise divested of its trade secrets,
# irrespective of what has been deposited with the U.S. Copyright Office.
# =============================================================================================

### Used in auto-merge ###
export APPROVE_BEFORE_MERGE="true"
export PR_NUMBER=$(get_env "PR_URL" | grep -o '[^/]*$')

export MERGE_METHOD="squash"
