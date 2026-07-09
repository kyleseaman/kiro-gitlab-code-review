#!/usr/bin/env bash
# ABOUTME: Posts AI-generated code review findings as inline discussions via the GitLab MR API.
# ABOUTME: Handles summary formatting, verdict labeling, positioned comments, and fallbacks.
set -euo pipefail

REVIEW_FILE="/tmp/kiro-review.json"

: "${CI_API_V4_URL:?CI_API_V4_URL is required}"
: "${CI_PROJECT_ID:?CI_PROJECT_ID is required}"
: "${CI_MERGE_REQUEST_IID:?CI_MERGE_REQUEST_IID is required}"
: "${GITLAB_TOKEN:?GITLAB_TOKEN is required (a token with 'api' scope)}"

MR_API="${CI_API_V4_URL}/projects/${CI_PROJECT_ID}/merge_requests/${CI_MERGE_REQUEST_IID}"
AUTH_HEADER="PRIVATE-TOKEN: ${GITLAB_TOKEN}"

# Post a plain note (summary or fallback text) to the MR.
post_note() {
  local body="$1"
  jq -n --arg body "$body" '{body: $body}' \
    | curl -sS -X POST "${MR_API}/notes" \
        -H "${AUTH_HEADER}" \
        -H "Content-Type: application/json" \
        --data @- > /dev/null
}

# --- No findings file: post a clean review -------------------------------------
if [[ ! -f "$REVIEW_FILE" ]]; then
  echo "No review file found — posting clean summary"
  post_note "✅ **Kiro Code Review** — No issues found."
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

# --- Post the summary note -----------------------------------------------------
post_note "$BODY"
echo "Summary note posted."

if [[ "$FINDING_COUNT" -eq 0 ]]; then
  echo "No inline findings to post."
  exit 0
fi

# --- Fetch diff refs needed for positioned discussions -------------------------
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
  exit 0
fi

# --- Post each finding as a positioned inline discussion -----------------------
POSTED=0
FAILED_FINDINGS="[]"

COUNT=$(jq '.comments | length' "$REVIEW_FILE")
for i in $(seq 0 $((COUNT - 1))); do
  FINDING=$(jq ".comments[$i]" "$REVIEW_FILE")
  PATH_VAL=$(echo "$FINDING" | jq -r '.path')
  LINE_VAL=$(echo "$FINDING" | jq -r '.line')
  SEVERITY=$(echo "$FINDING" | jq -r '.severity // "low"')
  CONFIDENCE=$(echo "$FINDING" | jq -r '.confidence // 0')
  RAW_BODY=$(echo "$FINDING" | jq -r '.body')
  COMMENT_BODY="**[${SEVERITY}]** ${RAW_BODY} _(confidence: ${CONFIDENCE})_"

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

# --- Any findings that could not be anchored → post as a single body note ------
FAILED_COUNT=$(echo "$FAILED_FINDINGS" | jq 'length')
if [[ "$FAILED_COUNT" -gt 0 ]]; then
  FALLBACK=$(echo "$FAILED_FINDINGS" | jq -r '
    "### Additional findings (could not anchor to a diff line)\n" + (. | join("\n"))')
  post_note "$FALLBACK"
  echo "Posted ${FAILED_COUNT} unanchored finding(s) as a body note."
fi
