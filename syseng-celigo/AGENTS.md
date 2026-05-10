# Workspace Instructions

## BigQuery Environments

| Environment | Project ID | Schema |
|---|---|---|
| Production | `digital-arbor-400` | `pg_public` |
| RunCache / Staging | `dulcet-yew-246109` | `staging_billing_public` |

When refactoring SQL for RunCache testing, replace all `digital-arbor-400`.`pg_public` references with `dulcet-yew-246109`.`staging_billing_public`.

## Agent Rules

Follow the AI Agent Root Rules defined in `.Codex/skills.md` (sourced from `fivetran/engineering` repo). Key principles:
- Incremental changes preferred — avoid large sweeping changes
- Match existing code patterns and conventions
- Security first, quality over speed
- Read mandatory Phase 1, 2, and 4 guidelines before any coding task

## Jira

For sprint summaries, daily briefings, or outstanding task reviews, use the `jira-sprint-briefer` agent (`@jira-sprint-briefer` or `Codex --agent jira-sprint-briefer`). It queries Jira via the `jira-agent` MCP tool and produces structured sprint briefings with risk flags and deliverable summaries.

## SQL Conventions

### Project-specific rules
- Tobiko (`Tobiko_Legacy_Pre_Migration`) exclusion is **sandbox only** — do not merge to production SQL until promoted
- `CENSUS_LEGACY` exclusion is production — ref: RD-1063527
- RunCache subscriptions must be routed through `run_cache_account_sync_v2.sql`, not the main subscription pipeline — ref: RD-1160536
- Always apply `not <alias>._fivetran_deleted` (not `= false` or `is false`) on all `_fivetran_deleted` filters, including `account_billing_info` JOINs (both `acct_payer` and `acct_customer`)
- NetSuite item names in SQL must not include year suffixes (e.g., use `'RunCache'` not `'RunCache_2026'`) — year-suffixed names embed pricing catalog versions and break across fiscal years

### BigQuery general best practices

**Style**
- Always alias tables; always qualify column references with the alias in multi-table queries
- Use snake_case for all column aliases
- Use CTEs (`WITH`) over nested subqueries — one CTE per logical step, named for what it produces (not what it reads)
- `GROUP BY` positional numbers (`1, 2, 3`) are acceptable for long select lists to avoid repetition
- Keyword order: `SELECT` → `FROM` → `JOIN` → `WHERE` → `GROUP BY` → `HAVING` → `QUALIFY` → `ORDER BY` → `LIMIT`

**Correctness**
- Use `SAFE_CAST` instead of `CAST` to avoid runtime errors on bad data
- Use `SAFE_DIVIDE(a, b)` instead of `a / b` to avoid division-by-zero errors
- Use `COALESCE` for null fallback; use `NULLIF(x, 0)` to turn zero into null before division
- Always include `ORDER BY` in window functions that use `ROW_NUMBER()`, `RANK()`, or `DENSE_RANK()` — omitting it produces non-deterministic results
- Use `QUALIFY ROW_NUMBER() OVER (...) = 1` for deduplication rather than a wrapping subquery
- Use `ABS(x)` directly instead of `IF(x >= 0, x, ABS(x))`

**Performance**
- Filter on partition/cluster columns in `WHERE` as early as possible to minimize bytes scanned
- Avoid applying functions to partition columns in `WHERE` (e.g., `DATE(ts) = ...` prevents partition pruning — use range predicates on the raw timestamp instead)
- Avoid `SELECT *` in production queries — project only the columns needed
- Avoid correlated subqueries — rewrite as `JOIN` or window function
- Use `COUNTIF(condition)` instead of `SUM(CASE WHEN condition THEN 1 ELSE 0 END)`

## Branch Policy

**Every code change, no matter how small, must happen on a named branch.**
This applies to bug fixes, single-line patches, refactors, and doc edits.
Never commit directly to `main`.

### Before touching any file

Run these three commands first — in this order:

```bash
git checkout main
git pull
git checkout -b <branch-name>
```

### Branch naming

| Change type | Pattern | Example |
|-------------|---------|---------|
| Roadmap epic | `epic/<N>-<slug>` | `epic/3-parallel-ba-workers` |
| Bug fix | `fix/<slug>` | `fix/jira-original-estimate-expand` |
| Documentation only | `docs/<slug>` | `docs/update-readme` |
| Refactor | `refactor/<slug>` | `refactor/trim-history-manager` |
| Test | `test/<slug>` | `test/eval-routing-coverage` |

Keep slugs short (3–5 words, hyphenated, lowercase).

### After making changes

1. Run tests before committing:
   ```bash
   python3 -m pytest -q --ignore=tests/test_jira_agent.py --ignore=tests/test_slack_agent.py --ignore=tests/test_routing_networked.py
   ```
2. Stage specific files — never `git add -A` or `git add .`
3. Commit with a message that explains *why*, not just *what*
4. Push and open a PR: `git push -u origin <branch>` → `gh pr create`

### If you forgot to branch first

```bash
git stash
git checkout -b <branch-name>
git stash pop
```

## Doc Update Workflow

Run this checklist after every PR is merged (or before opening the PR if doc changes should be part of the same commit).

The **draw.io MCP** (`mcp__drawio__*` tools) is used to keep the architecture diagram in sync with code changes.

### Decision tree — what needs updating?

| Change type | Docs to update | Diagram to update |
|---|---|---|
| New public symbol (class, method, param) | `PUBLIC_API.md`, `USERGUIDE.md`, `CHANGELOG.md` | — |
| New runtime component or pipeline stage | `PUBLIC_API.md`, `USERGUIDE.md`, `CHANGELOG.md`, `docs/focalpoint_one_pager.md` | `docs/focalpoint_architecture.drawio` — add the component box |
| Jira agent pipeline change | `CHANGELOG.md` | `docs/jira_agent_architecture.drawio` — update the affected stage |
| Routing change (ToolRouter / KeywordRouter) | `PUBLIC_API.md` (if params changed), `CHANGELOG.md` | `docs/focalpoint_architecture.drawio` — update ToolRouter node |
| New example agent | `README.md`, `CHANGELOG.md` | Create `docs/<agent>_architecture.drawio` |
| Bug fix only | `CHANGELOG.md` | — unless the fix revealed a misdrawn flow |
| Release | `CHANGELOG.md` (promote `[Unreleased]` → version), `ROADMAP_30_60_90.md` | Re-export all `.drawio` files to `.png` via draw.io MCP |

### Steps

1. **Changelog** — always add an entry to `CHANGELOG.md` under `[Unreleased]`
2. **Public API** — update `PUBLIC_API.md` if any constructor signature, method, or exported symbol changed
3. **User guide** — update `USERGUIDE.md` if the change affects how a user instantiates or calls a public class
4. **One-pager** — update `docs/focalpoint_one_pager.md` if a new runtime component was added
5. **Architecture diagram** — use draw.io MCP tools to update the relevant `.drawio` file, then export to PNG
6. **README** — add a one-line entry if the change adds a user-visible feature or new example
7. **Commit** — stage only doc files modified, never `git add -A`

### At release only

1. Promote `[Unreleased]` → `[X.Y.Z] — YYYY-MM-DD` in `CHANGELOG.md`
2. Stamp completed epics in `ROADMAP_30_60_90.md`: `Released in: vX.Y.Z — PR #N`
3. Re-export all `.drawio` files to `.png`
4. Tag the commit: `git tag vX.Y.Z && git push origin vX.Y.Z`
