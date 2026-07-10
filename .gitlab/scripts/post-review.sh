#!/usr/bin/env bash
# ABOUTME: Posts AI-generated code review findings as inline discussions via the GitLab MR API.
# ABOUTME: Handles summary formatting, verdict labeling, positioned comments, fallbacks, and the merge gate.
set -euo pipefail

REVIEW_FILE="/tmp/kiro-review.json"

: "${CI_API_V4_URL:?CI_API_V4_URL is required}"
: "${CI_PROJECT_ID:?CI_PROJECT_ID is required}"
: "${CI_MERGE_REQUEST_IID:?CI_MERGE_REQUEST_IID is required}"
: "${GITLAB_TOKEN:?GITLAB_TOKEN is required (a token with 'api' scope)}"

MR_API="${CI_API_V4_URL}/projects/${CI_PROJECT_ID}/merge_requests/${CI_MERGE_REQUEST_IID}"
AUTH_HEADER="PRIVATE-TOKEN: ${GITLAB_TOKEN}"

# Merge-gate controls.
#   KIRO_REVIEW_BLOCK  — when truthy, a "needs rework" verdict (or a missing review
#                        file — fail-closed) fails this job so the MR is blocked
#                        (requires "Pipelines must succeed" in project settings).
#                        Default false → advisory only.
#   Per-MR override     — add the `skip-kiro-review` label to bypass the gate on one MR.
# Gate status is folded into the single summary note, not posted as a separate
# comment, so re-runs don't clutter the MR conversation.
KIRO_REVIEW_BLOCK="${KIRO_REVIEW_BLOCK:-false}"
BYPASS_LABEL="skip-kiro-review"

is_truthy() {
  case "$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]')" in
    true|1|yes|on) return 0 ;;
    *) return 1 ;;
  esac
}

# Post a plain note (summary or fallback text) to the MR.
post_note() {
  local body="$1"
  jq -n --arg body "$body" '{body: $body}' \
    | curl -sS -X POST "${MR_API}/notes" \
        -H "${AUTH_HEADER}" \
        -H "Content-Type: application/json" \
        --data @- > /dev/null
}

has_bypass_label() {
  local labels
  labels=$(curl -sS -H "${AUTH_HEADER}" "${MR_API}" | jq -r '.labels[]?' 2>/dev/null || true)
  printf '%s\n' "$labels" | grep -qx "$BYPASS_LABEL"
}

# --- No review file: the coordinator always writes one on a compliant run, so a
# --- missing file means the review malfunctioned. Never claim "no issues found".
# --- Advisory mode: report honestly, pass. Blocking mode: fail closed.
if [[ ! -f "$REVIEW_FILE" ]]; then
  echo "No review file found — review did not complete."
  if is_truthy "$KIRO_REVIEW_BLOCK"; then
    if has_bypass_label; then
      post_note "⚠️ **Kiro Code Review did not complete** — no review output was produced (check the pipeline logs). The \`${BYPASS_LABEL}\` label is set, so this check will not fail."
      exit 0
    fi
    post_note "🚫 **Kiro Code Review did not complete** — no review output was produced, so this check is failing closed (blocking mode). Check the pipeline logs and re-run, or add the \`${BYPASS_LABEL}\` label to override."
    echo "Merge gate: missing review output with blocking enabled → failing job (fail-closed)." >&2
    exit 1
  fi
  post_note "⚠️ **Kiro Code Review did not complete** — no review output was produced. Check the pipeline logs and re-run."
  exit 0
fi

# --- Validate JSON -------------------------------------------------------------
if ! jq empty "$REVIEW_FILE" 2>/dev/null; then
  echo "Invalid JSON in $REVIEW_FILE" >&2
  echo "--- File contents ---"
  cat "$REVIEW_FILE"
  echo "--- End of file ---"
  exit 1
fi

FINDING_COUNT=$(jq '.comments // [] | length' "$REVIEW_FILE")
VERDICT=$(jq -r '.verdict // "" | ascii_downcase' "$REVIEW_FILE")

# --- Merge gate: decide state up front. BLOCKING drives the exit code at the end;
# --- GATE_SUFFIX is appended to the single summary note.
BLOCKING=false
GATE_SUFFIX=""
if is_truthy "$KIRO_REVIEW_BLOCK" && [[ "$VERDICT" == "needs rework" ]]; then
  if has_bypass_label; then
    GATE_SUFFIX=$'\n\n> ⚠️ **Merge gate bypassed** — verdict is `needs rework`, but the `'"$BYPASS_LABEL"$'` label is set, so this check will not fail.'
    echo "Verdict 'needs rework' bypassed by '${BYPASS_LABEL}' label. Not blocking."
  else
    BLOCKING=true
    GATE_SUFFIX=$'\n\n> 🚫 **Merge gate** — verdict is `needs rework`, so this pipeline is failing to block the merge. Address the findings above and re-run, or add the `'"$BYPASS_LABEL"$'` label to override.'
  fi
fi

# --- Build review body (summary + strengths + verdict) -------------------------
BODY=$(jq -r '
  def verdict_label:
    (.verdict // "no verdict") | ascii_downcase |
    if . == "merge" then "✅ Merge"
    elif . == "merge with fixes" then "Merge with fixes"
    elif . == "needs rework" then "Needs rework"
    else "No verdict" end;

  "🤖 **Kiro Code Review**\n\n" +
  (.summary // "No summary provided.") + "\n\n" +
  (if .strengths and (.strengths | length) > 0
    then "### Strengths\n" + (.strengths | map("- \(.)") | join("\n")) + "\n\n"
    else "" end) +
  "**Verdict: " + verdict_label + "**" +
  (if .verdict_reason and .verdict_reason != "" then " — " + .verdict_reason else "" end) +
  "\n\n---\n*Found \(.comments // [] | length) finding(s). Powered by [Kiro CLI](https://kiro.dev/docs/cli/headless/).* · To re-run, trigger a new pipeline on this MR (Pipelines → Run pipeline)."
' "$REVIEW_FILE")

# Fold the merge-gate status into the same summary note.
BODY="${BODY}${GATE_SUFFIX}"

# --- Post the summary note -----------------------------------------------------
post_note "$BODY"
echo "Summary note posted."

# --- Post inline discussions (only when there are findings) --------------------
if [[ "$FINDING_COUNT" -gt 0 ]]; then
  # Fetch diff refs needed for positioned discussions.
  DIFF_REFS=$(curl -sS -H "${AUTH_HEADER}" "${MR_API}" | jq '.diff_refs')
  BASE_SHA=$(echo "$DIFF_REFS" | jq -r '.base_sha // empty')
  START_SHA=$(echo "$DIFF_REFS" | jq -r '.start_sha // empty')
  HEAD_SHA=$(echo "$DIFF_REFS" | jq -r '.head_sha // empty')

  if [[ -z "$BASE_SHA" || -z "$HEAD_SHA" ]]; then
    echo "Could not resolve diff_refs — falling back to body-only findings." >&2
    FALLBACK=$(jq -r '
      "### Findings\n" +
      ([.comments // [] | .[] |
        "- **\(.path):\(.line)** **[" + (.severity // "low") + "]** " + .body +
        " _(confidence: " + ((.confidence // 0) | tostring) + ")_"] | join("\n"))
    ' "$REVIEW_FILE")
    post_note "$FALLBACK"
    echo "Findings posted as body-only fallback (${FINDING_COUNT} findings)."
  else
    # Post each finding as a positioned inline discussion.
    POSTED=0
    FAILED_FINDINGS="[]"

    for i in $(seq 0 $((FINDING_COUNT - 1))); do
      FINDING=$(jq ".comments[$i]" "$REVIEW_FILE")
      PATH_VAL=$(echo "$FINDING" | jq -r '.path')
      LINE_VAL=$(echo "$FINDING" | jq -r '.line')
      SEVERITY=$(echo "$FINDING" | jq -r '.severity // "low"')
      CONFIDENCE=$(echo "$FINDING" | jq -r '.confidence // 0')
      RAW_BODY=$(echo "$FINDING" | jq -r '.body')
      COMMENT_BODY="**[${SEVERITY}]** ${RAW_BODY} _(confidence: ${CONFIDENCE})_"

      # A positioned discussion needs an integer line. Findings without one
      # (e.g. file-level) can't anchor — route them to the body-note fallback
      # instead of letting jq --argjson abort the job under `set -e`.
      if ! [[ "$LINE_VAL" =~ ^[0-9]+$ ]]; then
        echo "::warning:: Non-numeric line for ${PATH_VAL} (line='${LINE_VAL}') — routing to body note"
        FAILED_FINDINGS=$(echo "$FAILED_FINDINGS" | jq \
          --arg line "- **${PATH_VAL}** ${COMMENT_BODY}" '. + [$line]')
        continue
      fi

      PAYLOAD=$(jq -n \
        --arg body "$COMMENT_BODY" \
        --arg base "$BASE_SHA" \
        --arg start "$START_SHA" \
        --arg head "$HEAD_SHA" \
        --arg newpath "$PATH_VAL" \
        --argjson newline "$LINE_VAL" \
        '{
          body: $body,
          position: {
            base_sha: $base,
            start_sha: $start,
            head_sha: $head,
            position_type: "text",
            new_path: $newpath,
            new_line: $newline
          }
        }')

      HTTP_CODE=$(echo "$PAYLOAD" | curl -sS -o /tmp/kiro-disc-resp.json -w "%{http_code}" \
        -X POST "${MR_API}/discussions" \
        -H "${AUTH_HEADER}" \
        -H "Content-Type: application/json" \
        --data @-)

      if [[ "$HTTP_CODE" == "201" ]]; then
        POSTED=$((POSTED + 1))
      else
        echo "::warning:: Inline discussion failed for ${PATH_VAL}:${LINE_VAL} (HTTP ${HTTP_CODE}): $(cat /tmp/kiro-disc-resp.json)"
        FAILED_FINDINGS=$(echo "$FAILED_FINDINGS" | jq \
          --arg line "- **${PATH_VAL}:${LINE_VAL}** ${COMMENT_BODY}" '. + [$line]')
      fi
    done

    echo "Posted ${POSTED}/${FINDING_COUNT} inline discussions."

    # Any findings that could not be anchored → post as a single body note.
    FAILED_COUNT=$(echo "$FAILED_FINDINGS" | jq 'length')
    if [[ "$FAILED_COUNT" -gt 0 ]]; then
      FALLBACK=$(echo "$FAILED_FINDINGS" | jq -r '
        "### Additional findings (could not anchor to a diff line)\n" + (. | join("\n"))')
      post_note "$FALLBACK"
      echo "Posted ${FAILED_COUNT} unanchored finding(s) as a body note."
    fi
  fi
else
  echo "No inline findings to post."
fi

# --- Merge gate: exit code only (status already in the summary note) -----------
if [[ "$BLOCKING" == "true" ]]; then
  echo "Merge gate: verdict 'needs rework' with blocking enabled → failing job." >&2
  exit 1
fi
exit 0
