# Keeping the two companions in sync

This tool ships as two sibling repos that share ~90% of their content:

| Repo | Platform | Diff | Terminology |
|---|---|---|---|
| `kyleseaman/kiro-gitlab-code-review` (this repo) | GitLab CI + MR API | `/tmp/mr.diff` | MR |
| `kyleseaman/kiro-code-reviews` | GitHub Actions + `gh` | `/tmp/pr.diff` | PR |

They do not auto-sync. **Every fix is a two-repo change by default** — a fix
applied to one and not the other is a bug, not a difference. (This has already
happened once: three review fixes landed on the GitHub repo and missed this one
for a full cycle.)

## Checklist for any change

1. Does the change touch shared content (agent JSONs, prompts, annotate-diff,
   post-review logic, README concepts)? If yes → apply to BOTH repos in the
   same working session.
2. Adapt only terminology and platform APIs (MR/PR, `mr.diff`/`pr.diff`,
   GitLab discussions vs `gh api` reviews, CI/CD variables vs Actions vars).
3. Re-run each repo's checks: `jq empty` on agent JSONs, `bash -n` on scripts,
   YAML parse on the pipeline/workflow file.

## Intentional differences (do NOT sync these)

- **Augment Code (`auggie`) MCP** — deliberately absent here, present on the
  GitHub repo (reviewer + bugs agents).
- **Posting mechanics** — GitLab posts per-finding positioned discussions with
  per-finding fallback; GitHub uses a single reviews-API call with a comments
  array (non-integer-line findings partitioned into the body up front).
- **Gate plumbing** — `KIRO_REVIEW_BLOCK` CI/CD variable here;
  `vars.KIRO_REVIEW_BLOCK` (Actions variable) on GitHub.
- **Re-run affordance** — new pipeline run here; `workflow_dispatch` on GitHub.
