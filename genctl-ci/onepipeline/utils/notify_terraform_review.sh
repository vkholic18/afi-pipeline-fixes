#!/usr/bin/env bash
# =============================================================================
# IBM Confidential
# (C) Copyright IBM Corp. 2026
# The source code for this program is not published or otherwise divested of
# its trade secrets, irrespective of what has been deposited with the U.S.
# Copyright Office.
# =============================================================================
#
# notify_terraform_review.sh
# Posts a Terraform BOB review verdict notification to a Slack channel.
# Uses Slack Incoming Webhook — no go-notify, no SLACK_DIR state required.
# Works with any channel in the same Slack workspace as the webhook URL.
# Also supports a dedicated follow-up PR summary notification mode.
#
# Usage:
#   ./notify_terraform_review.sh [OPTIONS]
#
# Required inputs (flag OR environment variable):
#   --webhook-url  URL    Slack incoming webhook URL  (or SLACK_WEBHOOK_URL)
#   --channel      NAME   Slack channel name, e.g. #my-channel  (or SLACK_CHANNEL)
#   --verdict      VALUE  APPROVE | NEEDS_REVIEW | BLOCK         (or BOB_VERDICT)
#   --pr-url       URL    Pull request URL                        (or PR_URL)
#   --pipeline-url URL    Tekton pipeline run URL                 (or PIPELINE_RUN_URL)
#
# Optional inputs:
#   --tag-group    ID     Slack group/team ID to tag, e.g. S012345  (or SLACK_TAG_GROUP)
#   --workspace    NAME   Terraform workspace name                   (or workspace_name)
#   --pipeline-type VALUE  PR | Merge                               (or PIPELINE_TYPE)
#   --mode         VALUE  infrastructure | toolchain                 (or REVIEW_MODE)
#   --repo         NAME   IaC repo name                             (or WORKSPACE_REPO)
#   --plan-summary TEXT   Plan summary line, e.g. "Plan: 2 to add" (or PLAN_SUMMARY)
#   --review-body  TEXT   BOB review text to include in the message  (or BOB_REVIEW_BODY)
#   --notification-kind VALUE terraform_review | follow_up_prs       (or SLACK_NOTIFICATION_KIND)
#   --tokens       NUM    Total tokens consumed by BOB               (or BOB_TOKENS)
#   --coins-this   NUM    BOB coins spent on this run only           (or BOB_COINS_THIS_RUN)
#   --coins-total  NUM    BOB cumulative coins spent (budget_spend)  (or BOB_COINS_SPENT)
#   --coins-budget NUM    BOB total coin budget                      (or BOB_COINS_BUDGET)
# =============================================================================

set -euo pipefail

# ── Defaults from environment ─────────────────────────────────────────────────
WEBHOOK_URL="${SLACK_WEBHOOK_URL:-}"
CHANNEL="${SLACK_CHANNEL:-}"
VERDICT="${BOB_VERDICT:-N/A}"
PR_URL="${PR_URL:-N/A}"
PIPELINE_URL="${PIPELINE_RUN_URL:-N/A}"
TAG_GROUP="${SLACK_TAG_GROUP:-}"
WORKSPACE_LABEL="${workspace_name:-N/A}"
MODE="${REVIEW_MODE:-N/A}"
REPO="${WORKSPACE_REPO:-N/A}"
PLAN_SUMMARY="${PLAN_SUMMARY:-N/A}"
REVIEW_BODY="${BOB_REVIEW_BODY:-}"
TOKENS="${BOB_TOKENS:-}"
COINS_THIS_RUN="${BOB_COINS_THIS_RUN:-}"
COINS_SPENT="${BOB_COINS_SPENT:-}"
COINS_BUDGET="${BOB_COINS_BUDGET:-}"
PIPELINE_TYPE="${PIPELINE_TYPE:-}"
NOTIFICATION_KIND="${SLACK_NOTIFICATION_KIND:-terraform_review}"

# ── Argument parsing ──────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    --webhook-url)  WEBHOOK_URL="$2";    shift 2 ;;
    --channel)      CHANNEL="$2";        shift 2 ;;
    --verdict)      VERDICT="$2";        shift 2 ;;
    --pr-url)       PR_URL="$2";         shift 2 ;;
    --pipeline-url) PIPELINE_URL="$2";   shift 2 ;;
    --tag-group)    TAG_GROUP="$2";      shift 2 ;;
    --workspace)    WORKSPACE_LABEL="$2"; shift 2 ;;
    --mode)         MODE="$2";           shift 2 ;;
    --repo)         REPO="$2";           shift 2 ;;
    --plan-summary) PLAN_SUMMARY="$2";   shift 2 ;;
    --review-body)  REVIEW_BODY="$2";    shift 2 ;;
    --tokens)       TOKENS="$2";         shift 2 ;;
    --coins-this)   COINS_THIS_RUN="$2"; shift 2 ;;
    --coins-spent)  COINS_SPENT="$2";    shift 2 ;;
    --coins-budget)   COINS_BUDGET="$2";    shift 2 ;;
    --pipeline-type)  PIPELINE_TYPE="$2";   shift 2 ;;
    --notification-kind) NOTIFICATION_KIND="$2"; shift 2 ;;
    *) echo "[ERROR] Unknown argument: $1"; exit 1 ;;
  esac
done

# ── Validate truly required inputs (webhook + channel only) ──────────────────
MISSING=()
[[ -z "$WEBHOOK_URL" ]] && MISSING+=("--webhook-url / SLACK_WEBHOOK_URL")
[[ -z "$CHANNEL"     ]] && MISSING+=("--channel / SLACK_CHANNEL")

if [[ ${#MISSING[@]} -gt 0 ]]; then
    echo "[ERROR] Missing required inputs:"
    for m in "${MISSING[@]}"; do echo "  - $m"; done
    exit 1
fi

# Apply N/A defaults for optional display fields after flag parsing
[[ -z "$VERDICT"      ]] && VERDICT="N/A"
[[ -z "$PR_URL"       ]] && PR_URL="N/A"
[[ -z "$PIPELINE_URL" ]] && PIPELINE_URL="N/A"
[[ -z "$WORKSPACE_LABEL" ]] && WORKSPACE_LABEL="N/A"
[[ -z "$MODE"         ]] && MODE="N/A"
[[ -z "$REPO"         ]] && REPO="N/A"
[[ -z "$PLAN_SUMMARY" ]] && PLAN_SUMMARY="N/A"

# Normalise channel: ensure it starts with # for display, strip it for the API
CHANNEL_DISPLAY="#${CHANNEL##\#}"
CHANNEL_API="${CHANNEL##\#}"

# ── Verdict → colour, icon, label ────────────────────────────────────────────
case "$VERDICT" in
    APPROVE)
        COLOR="#2eb886"          # Slack green
        ICON=":white_check_mark:"
        VERDICT_LABEL="APPROVED"
        ;;
    NEEDS_REVIEW)
        COLOR="#f0a500"          # Slack amber
        ICON=":warning:"
        VERDICT_LABEL="NEEDS REVIEW"
        ;;
    BLOCK)
        COLOR="#e01e5a"          # Slack red
        ICON=":no_entry:"
        VERDICT_LABEL="BLOCKED"
        ;;
    SUCCESS)
        COLOR="#2eb886"          # Slack green
        ICON=":white_check_mark:"
        VERDICT_LABEL="SUCCESS"
        ;;
    FAILURE)
        COLOR="#e01e5a"          # Slack red
        ICON=":no_entry:"
        VERDICT_LABEL="FAILURE"
        ;;
    N/A)
        COLOR="#cccccc"
        ICON=":information_source:"
        VERDICT_LABEL="N/A"
        ;;
    *)
        COLOR="#cccccc"
        ICON=":question:"
        VERDICT_LABEL="UNKNOWN (${VERDICT})"
        ;;
esac

# ── Tag line: supports multiple IDs/groups, space or comma separated ─────────
# User ID    (U...) → <@U...>           individual mention
# Subteam ID (S...) → <!subteam^S...>   group/team mention
# e.g. SLACK_TAG_GROUP="U0408DJ8K7D S012345,U999999"
TAG_LINE=""
if [[ -n "$TAG_GROUP" ]]; then
    # Normalise: replace commas with spaces, then split into an array
    IFS=' ,' read -ra _TAG_IDS <<< "${TAG_GROUP//,/ }"
    _MENTIONS=""
    for _id in "${_TAG_IDS[@]}"; do
        [[ -z "$_id" ]] && continue
        if [[ "$_id" == U* ]]; then
            _MENTIONS="${_MENTIONS} <@${_id}>"
        else
            _MENTIONS="${_MENTIONS} <!subteam^${_id}>"
        fi
    done
    _MENTIONS="${_MENTIONS# }"   # strip leading space
    [[ -n "$_MENTIONS" ]] && TAG_LINE="${_MENTIONS} — please review"
fi

# ── Parse BOB review output into named sections → individual Slack blocks ─────
# BOB always emits these sections in order. Each gets its own block with an
# emoji heading. Tables are wrapped in ``` for monospace rendering. Severity
# tags ([CRITICAL]/[HIGH]/[MEDIUM]/[LOW]) get inline emoji. Any section still
# longer than 2900 chars is sub-chunked to stay within Slack's block text limit.
CHUNK_SIZE=2900
REVIEW_CHUNKS_JSON="[]"

_slack_section() {
    # Append one section block to REVIEW_CHUNKS_JSON.
    # $1 = heading (may be empty), $2 = body text (real newlines, not \n literals)
    local heading="$1" content="$2" text="" remaining=""
    if [[ -n "$heading" ]]; then
        text="${heading}"$'\n'
    fi
    text="${text}${content}"
    # Sub-chunk if over limit
    remaining="$text"
    local first_sub=true
    while [[ -n "$remaining" ]]; do
        local piece="${remaining:0:${CHUNK_SIZE}}"
        remaining="${remaining:${CHUNK_SIZE}}"
        if [[ "$first_sub" == "true" ]]; then
            first_sub=false
        else
            piece="_(continued)_"$'\n'"${piece}"
        fi
        REVIEW_CHUNKS_JSON=$(printf '%s' "$REVIEW_CHUNKS_JSON" \
            | jq --arg t "$piece" \
                '. + [{"type":"section","text":{"type":"mrkdwn","text":$t}}]')
    done
}

_fmt_severity() {
    # Replace severity bracket tags (with any surrounding * stars) with emoji + bold.
    # Handles **[TAG]**, *[TAG]*, [TAG] — all map to :emoji: *LABEL*
    # Uses python3 for reliable regex on both macOS and Linux (avoids BSD sed \| issue).
    printf '%s' "$1" | python3 -c "
import sys, re
text = sys.stdin.read()
rules = [
    (r'\*{0,3}\[CRITICAL\]\*{0,3}', ':rotating_light: *CRITICAL*'),
    (r'\*{0,3}\[HIGH\]\*{0,3}',     ':warning: *HIGH*'),
    (r'\*{0,3}\[MEDIUM\]\*{0,3}',   ':large_yellow_circle: *MEDIUM*'),
    (r'\*{0,3}\[LOW\]\*{0,3}',      ':large_blue_circle: *LOW*'),
    (r'\*{0,3}\[NONE\]\*{0,3}',     ':white_check_mark: *NONE*'),
]
for pattern, repl in rules:
    text = re.sub(pattern, repl, text)
print(text, end='')
"
}

_md_to_mrkdwn() {
    # Convert markdown bold/italic to Slack mrkdwn:
    #   ***text***  →  *text*   (bold+italic → bold)
    #   **text**    →  *text*   (bold → bold)
    # Uses python3 for reliable regex on both macOS and Linux.
    # Backtick inline code and bullet lists are already compatible — no change needed.
    printf '%s' "$1" | python3 -c "
import sys, re
text = sys.stdin.read()
# triple before double to avoid partial matches
text = re.sub(r'\*{3}([^*]+)\*{3}', r'*\1*', text)
text = re.sub(r'\*{2}([^*]+)\*{2}', r'*\1*', text)
print(text, end='')
"
}

if [[ -n "$REVIEW_BODY" ]]; then
    # Strip the machine-readable verdict block — not useful in Slack
    # (remove ##VERDICT_...## lines and bare ``` fences left around them)
    body=$(printf '%s' "$REVIEW_BODY" \
        | sed '/^##VERDICT_START##$/,/^##VERDICT_END##$/d' \
        | sed '/^```$/d')

    # Extract each section by splitting on known headings.
    # Use a temp file + fd redirect (not <<<) so the while loop runs in the
    # current shell and the declare -A SECTIONS associative array persists.
    declare -A SECTIONS
    current_section="REASON"
    current_content=""
    _body_tmp=$(mktemp)
    printf '%s' "$body" > "$_body_tmp"
    while IFS= read -r line; do
        case "$line" in
            "RISK TABLE"|"CHANGE CLASSIFICATION"|"FINDINGS"|"COMPLIANCE IMPACT"|"JUSTIFY BEFORE APPLY"|"SAFE")
                SECTIONS["$current_section"]="$current_content"
                current_section="$line"; current_content="" ;;
            "RAISED PRS"|"SKIPPED BRANCHES")
                if [[ "$NOTIFICATION_KIND" == "follow_up_prs" ]]; then
                    SECTIONS["$current_section"]="$current_content"
                    current_section="$line"; current_content=""
                else
                    current_content="${current_content}${line}"$'\n'
                fi ;;
            *)
                current_content="${current_content}${line}"$'\n' ;;
        esac
    done < "$_body_tmp"
    rm -f "$_body_tmp"
    SECTIONS["$current_section"]="$current_content"

    # Emit a divider then each section as its own Slack block
    REVIEW_CHUNKS_JSON=$(printf '%s' "$REVIEW_CHUNKS_JSON" \
        | jq '. + [{"type":"divider"}]')

    # Helper: strip leading/trailing blank lines from a section variable
    # (awk approach — works on both GNU and BSD/macOS)
    _trim() { printf '%s' "$1" | awk 'NF{found=1} found{print}' | awk '{lines[NR]=$0} NF{last=NR} END{for(i=1;i<=last;i++) print lines[i]}'; }
# REASON — BOB writes it as "REASON: <text>" on one line; extract just the text
reason_text=$(_trim "${SECTIONS[REASON]:-}")
# Strip leading "REASON: " / "REASON:" prefix (inline format)
reason_text=$(printf '%s' "$reason_text" | sed 's/^REASON:[[:space:]]*//')
reason_text=$(_trim "$reason_text")
if [[ "$NOTIFICATION_KIND" != "follow_up_prs" ]] && [[ -n "${reason_text// }" ]]; then
    _slack_section ":memo: *Reason*" "$reason_text"
fi


    # RISK TABLE — wrap in ``` for monospace table rendering, trim blanks
    # Ensure newline before and after the fences so Slack renders the code block
    risk_text=$(_trim "${SECTIONS[RISK TABLE]:-}")
    if [[ -n "${risk_text// }" ]]; then
        _slack_section ":bar_chart: *Risk Table*" $'```\n'"${risk_text}"$'\n```'
    fi

    # CHANGE CLASSIFICATION — convert **bold** → *bold*
    cc_text=$(_trim "${SECTIONS[CHANGE CLASSIFICATION]:-}")
    cc_text=$(_md_to_mrkdwn "$cc_text")
    if [[ "$NOTIFICATION_KIND" != "follow_up_prs" ]] && [[ -n "${cc_text// }" ]]; then
        _slack_section ":label: *Change Classification*" "$cc_text"
    fi

    # FINDINGS — convert **bold** → *bold* first, then replace severity tags with emoji
    # Order matters: _md_to_mrkdwn before _fmt_severity avoids nested star collisions
    # e.g. **[CRITICAL]** → *[CRITICAL]* → :rotating_light: *CRITICAL*
    findings_text=$(_trim "${SECTIONS[FINDINGS]:-}")
    findings_text=$(_md_to_mrkdwn "$findings_text")
    findings_text=$(_fmt_severity "$findings_text")
    if [[ -n "${findings_text// }" ]]; then
        _slack_section ":mag: *Findings*" "$findings_text"
    fi

    if [[ "$NOTIFICATION_KIND" == "follow_up_prs" ]]; then
        raised_prs_text=$(printf '%s' "${SECTIONS[RAISED PRS]:-}" | sed '/^_END_OF_RAISED_PRS_$/d')
        raised_prs_text=$(_md_to_mrkdwn "$raised_prs_text")
        raised_prs_text+=$'\n'
        if [[ -n "${raised_prs_text// }" ]]; then
            _slack_section ":git: *Raised PRs*" "$raised_prs_text"
        fi

        skipped_branches_text=$(_trim "${SECTIONS[SKIPPED BRANCHES]:-}")
        skipped_branches_text=$(_md_to_mrkdwn "$skipped_branches_text")
        if [[ -n "${skipped_branches_text// }" ]]; then
            _slack_section ":fast_forward: *Skipped Branches*" "$skipped_branches_text"
        fi
    fi

    # COMPLIANCE IMPACT
    ci_text=$(_trim "${SECTIONS[COMPLIANCE IMPACT]:-}")
    ci_text=$(_md_to_mrkdwn "$ci_text")
    if [[ -n "${ci_text// }" ]]; then
        _slack_section ":shield: *Compliance Impact*" "$ci_text"
    fi

    # JUSTIFY BEFORE APPLY
    jba_text=$(_trim "${SECTIONS[JUSTIFY BEFORE APPLY]:-}")
    jba_text=$(_md_to_mrkdwn "$jba_text")
    if [[ -n "${jba_text// }" ]]; then
        _slack_section ":pencil: *Justify Before Apply*" "$jba_text"
    fi

    # SAFE
    safe_text=$(_trim "${SECTIONS[SAFE]:-}")
    safe_text=$(_md_to_mrkdwn "$safe_text")
    if [[ -n "${safe_text// }" ]]; then
        _slack_section ":white_check_mark: *Safe Changes*" "$safe_text"
    fi
fi

# ── Build Slack Block Kit payload ─────────────────────────────────────────────
# Uses attachments (colour sidebar) + blocks (structured content).
# jq constructs the JSON safely — no manual string escaping needed.
if [[ "$NOTIFICATION_KIND" == "follow_up_prs" ]]; then
    PAYLOAD=$(jq -cn \
        --arg channel      "$CHANNEL_API" \
        --arg color        "$COLOR" \
        --arg icon         "$ICON" \
        --arg verdict      "$VERDICT_LABEL" \
        --arg tag_line     "$TAG_LINE" \
        --arg repo         "$REPO" \
        --arg workspace    "$WORKSPACE_LABEL" \
        --arg pipe_url     "$PIPELINE_URL" \
        --arg plan_summary "$PLAN_SUMMARY" \
        --argjson review_chunks "$REVIEW_CHUNKS_JSON" \
    '{
        "channel": $channel,
        "attachments": [
            {
                "color": $color,
                "blocks": (
                    [
                    {
                        "type": "header",
                        "text": {
                            "type": "plain_text",
                            "text": ("UUC Follow-up PRs  " + $icon + "  " + $verdict),
                            "emoji": true
                        }
                    },
                    {
                        "type": "section",
                        "fields": [
                            {
                                "type": "mrkdwn",
                                "text": ("*Repository*\n`" + $repo + "`")
                            },
                            {
                                "type": "mrkdwn",
                                "text": ("*Workspace*\n`" + $workspace + "`")
                            },
                            {
                                "type": "mrkdwn",
                                "text": ("*Status*\n" + $icon + " *" + $verdict + "*")
                            }
                        ]
                    },
                    (if $plan_summary != "" and $plan_summary != "N/A" then
                        {
                            "type": "section",
                            "text": {
                                "type": "mrkdwn",
                                "text": ("*Summary*\n" + $plan_summary)
                            }
                        }
                    else
                        null
                    end)
                    ] +
                    $review_chunks +
                    [
                    {
                        "type": "actions",
                        "elements": ([
                            (if $pipe_url != "N/A" and $pipe_url != "" then
                            {
                                "type": "button",
                                "text": {
                                    "type": "plain_text",
                                    "text": ":pipeline: View Pipeline Run",
                                    "emoji": true
                                },
                                "url": $pipe_url,
                                "action_id": "view_pipeline"
                            } else null end)
                        ] | map(select(. != null)))
                    },
                    (if $tag_line != "" then
                        {
                            "type": "section",
                            "text": {
                                "type": "mrkdwn",
                                "text": $tag_line
                            }
                        }
                    else
                        null
                    end),
                    {
                        "type": "divider"
                    }
                    ] | map(select(. != null))
                )
            }
        ]
    }')
else
    PAYLOAD=$(jq -cn \
        --arg channel       "$CHANNEL_API" \
        --arg color         "$COLOR" \
        --arg icon          "$ICON" \
        --arg verdict       "$VERDICT_LABEL" \
        --arg tag_line      "$TAG_LINE" \
        --arg repo          "$REPO" \
        --arg workspace     "$WORKSPACE_LABEL" \
        --arg mode          "$MODE" \
        --arg pipeline_type "$PIPELINE_TYPE" \
        --arg pr_url        "$PR_URL" \
        --arg pipe_url      "$PIPELINE_URL" \
        --arg plan_summary  "$PLAN_SUMMARY" \
        --arg tokens         "$TOKENS" \
        --arg coins_this_run "$COINS_THIS_RUN" \
        --arg coins_spent    "$COINS_SPENT" \
        --arg coins_budget   "$COINS_BUDGET" \
        --argjson review_chunks "$REVIEW_CHUNKS_JSON" \
    '{
        "channel": $channel,
        "attachments": [
            {
                "color": $color,
                "blocks": (
                    [
                    {
                        "type": "header",
                        "text": {
                            "type": "plain_text",
                            "text": (
                                (if $mode == "infrastructure" then "UUC Infrastructure"
                                 elif $mode == "toolchain"    then "UUC Toolchain"
                                 else "UUC Terraform" end)
                                + (if $pipeline_type == "PR"    then " \u00b7 PR Review"
                                   elif $pipeline_type == "Merge" then " \u00b7 Merge Apply"
                                   else "" end)
                                + "  " + $icon + "  " + $verdict
                            ),
                            "emoji": true
                        }
                    },
                    {
                        "type": "section",
                        "fields": [
                            {
                                "type": "mrkdwn",
                                "text": ("*Repository*\n`" + $repo + "`")
                            },
                            {
                                "type": "mrkdwn",
                                "text": ("*Workspace*\n`" + $workspace + "`")
                            },
                            {
                                "type": "mrkdwn",
                                "text": ("*Mode*\n`" + $mode + "`")
                            },
                            {
                                "type": "mrkdwn",
                                "text": ("*Verdict*\n" + $icon + " *" + $verdict + "*")
                            },
                            (if $pipeline_type != "" then
                                {
                                    "type": "mrkdwn",
                                    "text": ("*Pipeline*\n`" + $pipeline_type + "`")
                                }
                            else null end)
                        ] | map(select(. != null))
                    },
                    (if $plan_summary != "" and $plan_summary != "N/A" then
                        {
                            "type": "section",
                            "text": {
                                "type": "mrkdwn",
                                "text": ("*Plan Summary*\n`" + $plan_summary + "`")
                            }
                        }
                    else
                        null
                    end)
                    ] +
                    $review_chunks +
                    [
                    (if $tokens != "" or $coins_this_run != "" then
                        {
                            "type": "context",
                            "elements": [
                                {
                                    "type": "mrkdwn",
                                    "text": (
                                        "*Tokens:* " + (if $tokens != "" then $tokens else "—" end) +
                                        "  |  *This run:* " + (if $coins_this_run != "" then $coins_this_run + " coins" else "—" end) +
                                        "  |  *Total used:* " + (if $coins_spent != "" then $coins_spent else "—" end) +
                                        (if $coins_budget != "" and $coins_spent != "" then "  |  *Remaining:* " + (($coins_budget | tonumber) - ($coins_spent | tonumber) | tostring) else "" end)
                                    )
                                }
                            ]
                        }
                    else
                        null
                    end),
                    {
                        "type": "actions",
                        "elements": ([
                            (if $pr_url != "N/A" and $pr_url != "" then
                            {
                                "type": "button",
                                "text": {
                                    "type": "plain_text",
                                    "text": ":git: View Pull Request",
                                    "emoji": true
                                },
                                "url": $pr_url,
                                "action_id": "view_pr"
                            } else null end),
                            (if $pipe_url != "N/A" and $pipe_url != "" then
                            {
                                "type": "button",
                                "text": {
                                    "type": "plain_text",
                                    "text": ":pipeline: View Pipeline Run",
                                    "emoji": true
                                },
                                "url": $pipe_url,
                                "action_id": "view_pipeline"
                            } else null end)
                        ] | map(select(. != null)))
                    },
                    (if $tag_line != "" then
                        {
                            "type": "section",
                            "text": {
                                "type": "mrkdwn",
                                "text": $tag_line
                            }
                        }
                    else
                        null
                    end),
                    {
                        "type": "divider"
                    }
                    ] | map(select(. != null))
                )
            }
        ]
    }')
fi

# ── Send to Slack ─────────────────────────────────────────────────────────────
echo "[SLACK] Posting verdict ${VERDICT} to ${CHANNEL_DISPLAY}..."

HTTP_STATUS=$(curl -s -o /tmp/slack_response.json -w "%{http_code}" \
    -X POST \
    -H "Content-Type: application/json" \
    --data "$PAYLOAD" \
    "$WEBHOOK_URL")

SLACK_RESPONSE=$(cat /tmp/slack_response.json 2>/dev/null || echo "")

if [[ "$HTTP_STATUS" == "200" ]] && [[ "$SLACK_RESPONSE" == "ok" ]]; then
    echo "[SLACK] Notification sent successfully to ${CHANNEL_DISPLAY} — verdict: ${VERDICT}"
    rm -f /tmp/slack_response.json
    exit 0
else
    echo "[ERROR] Slack notification failed."
    echo "[ERROR] HTTP status: ${HTTP_STATUS}"
    echo "[ERROR] Slack response: ${SLACK_RESPONSE}"
    rm -f /tmp/slack_response.json
    # Non-fatal: don't fail the pipeline because Slack is down
    exit 0
fi
