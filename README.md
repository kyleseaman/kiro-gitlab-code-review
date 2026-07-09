# 🔍 GitLab Kiro Code Review

Automated merge request code reviews powered by [Kiro CLI](https://kiro.dev/cli/) in headless mode, running as a GitLab CI pipeline. A coordinator agent spawns specialized review agents in parallel, filters findings by confidence score, and posts inline discussion comments directly on the MR.

Adapted from the GitHub Actions version of this tool. Two things are different here beyond the platform port:

- A dedicated **Kiro Steering adherence agent** checks changes against `.kiro/steering/*.md` rules — honoring each rule's `inclusion` front-matter — rather than lumping steering in with flat `AGENTS.md` checks.
- **No third-party MCP dependencies.** The Augment Code semantic-search integration from the original has been removed; the review runs entirely on Kiro CLI.

## How It Works

1. A merge request is opened or updated (non-draft).
2. Kiro CLI is installed and the MR diff (`git diff` against the target branch merge base) is annotated with absolute line numbers.
3. Repo guidelines are gathered into two buckets:
   - `AGENTS.md` / `CLAUDE.md` → flat guidelines
   - `.kiro/steering/*.md` → Kiro steering rules (front-matter preserved)
4. Linked issue context is fetched from the MR description (parses `Closes #N`, `Fixes #N`, `Resolves #N`).
5. The coordinator agent (Opus 4.6) spawns **4 subagents in parallel** (Sonnet 5):
   - **Guidelines** — compliance against `AGENTS.md` / `CLAUDE.md`
   - **Steering** — adherence to `.kiro/steering/*.md`, respecting `inclusion: always | fileMatch | manual`
   - **Bug Detection** — scans for bugs, error handling issues, and test coverage gaps
   - **Git History** — analyzes blame/log for context (fragile code, reverted fixes, churn)
6. The coordinator performs its own **design review** — completeness, abstraction layer, approach.
7. All findings are filtered by confidence (threshold: 80), deduplicated, and assigned severity.
8. Results are posted as inline **discussions** on specific diff lines, plus a summary note with a verdict.

## Agent Architecture

| Agent | Model | Role |
|---|---|---|
| `code-reviewer` | Opus 4.6 | Coordinator — spawns subagents, filters, design review, merges |
| `code-guidelines` | Sonnet 5 | `AGENTS.md` / `CLAUDE.md` compliance |
| `code-steering` | Sonnet 5 | `.kiro/steering/*.md` adherence (inclusion-aware) |
| `code-bugs` | Sonnet 5 | Bug detection in changed lines |
| `code-history` | Sonnet 5 | Git blame/log context analysis |

### The steering agent and `inclusion` front-matter

Kiro steering files carry metadata controlling *when* a rule applies. The steering agent honors it:

| `inclusion` | Behavior |
|---|---|
| `always` (or no front-matter) | Applied to every changed file |
| `fileMatch` + `fileMatchPattern` | Applied only to changed files matching the glob |
| `manual` | Skipped — these are only pulled in when a human references them |

This means a steering rule scoped to `src/components/**/*.tsx` won't be flagged against a backend file, and manual-only rules never generate review noise.

## Quick Setup

### 1. Copy the files into your repo

```
your-repo/
├── .gitlab-ci.yml
├── .gitlab/
│   └── scripts/
│       ├── annotate-diff.sh          # Adds line numbers to diff
│       └── post-review.sh            # Posts review via GitLab MR API
└── .kiro/
    └── agents/
        ├── code-reviewer.json          # Coordinator (Opus 4.6)
        ├── code-guidelines.json        # AGENTS.md/CLAUDE.md compliance (Sonnet 5)
        ├── code-steering.json          # Kiro steering adherence (Sonnet 5)
        ├── code-bugs.json              # Bug detection (Sonnet 5)
        ├── code-history.json           # Git history analysis (Sonnet 5)
        └── prompts/
            ├── code-reviewer.md
            ├── code-guidelines.md
            ├── code-steering.md
            ├── code-bugs.md
            └── code-history.md
```

If your project already has a `.gitlab-ci.yml`, merge the `kiro-code-review` job and `review` stage into it instead of overwriting.

### 2. Add CI/CD variables

Go to **Settings → CI/CD → Variables** in your GitLab project and add:

| Variable | Value | Notes |
|---|---|---|
| `KIRO_API_KEY` | Your Kiro API key ([generate one](https://kiro.dev/docs/cli/authentication#authenticate-with-an-api-key-headless-mode)) | Mark as **Masked**. Requires a Kiro Pro, Pro+, or Power subscription. |
| `GITLAB_TOKEN` | A token with `api` scope | Used to read the MR/issues and post discussions. See below. |

**`GITLAB_TOKEN`** should be a [Project Access Token](https://docs.gitlab.com/ee/user/project/settings/project_access_tokens.html) (role: **Developer** or higher, scope: **api**) or a Group/Personal Access Token with `api` scope. Mark it **Masked**. The built-in `CI_JOB_TOKEN` is intentionally not used because it cannot reliably create positioned MR discussions.

### 3. Open a merge request

That's it. The pipeline triggers on MR events and posts a review. Draft MRs are skipped automatically.

## Example Output

**Summary note** (summary + strengths + verdict):

> 🤖 **Kiro Code Review**
>
> This MR adds user authentication. The implementation is solid with good test coverage, but there's a null pointer issue and a missing input validation check.
>
> ### Strengths
> - Clean separation of auth logic into a dedicated handler (src/auth/handler.ts)
> - Comprehensive test coverage for the happy path
>
> **Verdict: Merge with fixes** — Fix the null check and input validation before merge.
>
> *Found 2 finding(s). Powered by Kiro CLI.*

**Inline discussions** (on specific diff lines):

> **[high]** `user.email` can be `null` when the OAuth provider doesn't return an email. Calling `.toLowerCase()` will throw a TypeError at runtime. *(confidence: 92)*

> **[medium]** [design] The linked issue asks for auth across all routes, but this MR only adds it to `/api/users`. The `/api/admin` routes are unprotected. *(confidence: 88)*

## Customization

### Changing what the agents review

Each agent has its own prompt file under `.kiro/agents/prompts/`:
- `code-bugs.md` — bug detection rules and focus areas
- `code-guidelines.md` — AGENTS.md/CLAUDE.md compliance rules
- `code-steering.md` — Kiro steering adherence + inclusion semantics
- `code-history.md` — git history analysis rules
- `code-reviewer.md` — coordinator prompt (spawning, filtering, design review)

### Adjusting the confidence threshold

The default threshold is 80. To change it, edit `code-reviewer.md`:

```
The threshold is **80**. Drop everything below it.
```

### Changing the models

Edit the `model` field in any agent's `.json` config:

```json
{ "model": "claude-sonnet-5" }
```

The coordinator uses `claude-opus-4.6`; subagents use `claude-sonnet-5`.

### When the review runs

By default the review runs on **every non-draft MR event** (open and update). To restrict it to only when the MR opens, or to skip doc-only changes, adjust the `rules:` block in `.gitlab-ci.yml`. Draft MRs (title starting with `Draft:`) are always skipped.

### Re-running a review

Trigger a new pipeline on the MR: **Pipelines → Run pipeline**, or push a new commit to the source branch.

## Architecture

```
┌──────────────────────────────────────────────────────┐
│  GitLab CI Pipeline (merge_request_event)             │
│                                                       │
│  1. Install CLI → 2. Annotate diff                    │
│  3. Gather AGENTS.md/CLAUDE.md + .kiro/steering       │
│  4. Fetch linked issue context (GitLab issues API)    │
│                                                       │
│  5. kiro-cli (coordinator — Opus 4.6)                 │
│     ├── spawns code-guidelines (Sonnet 5)          │
│     ├── spawns code-steering   (Sonnet 5)          │
│     ├── spawns code-bugs       (Sonnet 5)          │
│     ├── spawns code-history    (Sonnet 5)          │
│     ├── filters by confidence (≥ 80)                  │
│     ├── performs design review                        │
│     └── merges → /tmp/kiro-review.json                │
│                                                       │
│  6. post-review.sh → GitLab MR discussions API        │
└──────────────────────────────────────────────────────┘
```

## Troubleshooting

| Problem | Solution |
|---|---|
| Pipeline doesn't trigger | Ensure `.gitlab-ci.yml` is on the target branch and merge request pipelines are enabled (**Settings → Merge requests**) |
| `GITLAB_TOKEN is required` | Add a `GITLAB_TOKEN` CI/CD variable with `api` scope |
| Inline comments fail (HTTP 400) | The line may not be part of the diff; those findings fall back to a body note automatically |
| No review posted | Check the job logs — the agent may not have found issues above the confidence threshold |
| No issue context | Ensure the MR description contains `Closes #N`, `Fixes #N`, or `Resolves #N` |
| No steering findings | Add `.kiro/steering/*.md` files; confirm their `inclusion` front-matter matches the changed files |

## Requirements

- Kiro CLI (installed automatically by the pipeline)
- Kiro Pro, Pro+, or Power subscription (for API key access)
- GitLab project with merge request pipelines enabled
- A `GITLAB_TOKEN` with `api` scope

## License

[MIT](LICENSE)
