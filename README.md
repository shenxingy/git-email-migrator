# git-email-migrator

[![CI](https://github.com/shenxingy/git-email-migrator/actions/workflows/ci.yml/badge.svg)](https://github.com/shenxingy/git-email-migrator/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![shell: bash](https://img.shields.io/badge/shell-bash-89e051.svg)](#requirements)

Rewrite the author/committer email on **every commit, in every repo you own — safely**.

Built for one scenario: your company/school email is being decommissioned, thousands
of your commits point at it, and you don't want your GitHub contribution graph to
vanish. Battle-tested on a real migration: **~6,000 commits across 200+ repos,
zero data loss, zero residue.**

```
Before:  github search author-email:old@company.com  →  6,088 commits
After:                                                →  0
```

## Table of Contents

- [Why this exists](#why-this-exists)
- [What it does](#what-it-does)
- [Safety model](#safety-model)
- [Requirements](#requirements)
- [Quickstart](#quickstart)
- [Commands](#commands)
- [After migrating](#after-migrating)
- [Docs](#docs)
- [License](#license)

## Why this exists

GitHub attributes commits to your profile by matching the commit's email against
the **verified emails on your account** — live, at render time. The moment an
email leaves your account (or the account loses access to it), every commit made
with it becomes unattributed: gray avatar, no profile link, contribution squares
gone. Re-adding the email restores attribution, but you can't re-verify an email
whose mail service no longer exists — and a decommissioned domain can even be
re-registered by someone else who could then *claim your commits*.

The durable fix is to rewrite history so your commits use an address you'll
control forever. Doing that across hundreds of repos — with protected branches,
archived repos, org permissions, collaborators, and local clones in play —
is exactly the part everyone gets wrong. This tool automates it with guardrails.

> **⚠️ This tool force-pushes rewritten history.** Commit hashes change.
> Collaborators must re-sync their clones (one command, see
> [After migrating](#after-migrating)), and links to old commit SHAs break.
> Read the [FAQ](docs/faq.md) before running it on shared repos.

## What it does

```
audit ──→ migrate ──→ unblock ──→ sync ──→ verify
  │           │            │         │        │
  │           │            │         │        └─ independent re-scan, must be 0
  │           │            │         └─ repoint local clones (dirty files survive)
  │           │            └─ protected/archived repos: toggle, push, restore
  │           └─ per repo: bare clone → bundle backup → filter-repo mailmap
  │                        → 3 validation gates → force-push
  └─ enumerate user + all orgs, scan raw email fields, build target list
```

The rewrite itself is a [`git filter-repo`](https://github.com/newren/git-filter-repo)
mailmap pass: **only the email field changes**. Author names, commit messages,
dates, and every file tree stay bit-identical — which also means your
contribution squares keep their exact dates and counts, just attributed through
the new address.

## Safety model

| Guardrail | Detail |
|---|---|
| **Dry-run by default** | `DRY_RUN=1` clones, rewrites, and validates locally — pushes nothing until you flip it |
| **Full backups** | every repo is snapshotted to a git bundle before rewriting; `restore` rolls a repo back with one command |
| **Validation gates** | a rewrite is only pushed if: commit count is sane, `HEAD` tree hash is bit-identical, and zero old-email fields remain |
| **No half-pushes** | any failed gate skips the repo and records why; nothing partially rewritten ever leaves your machine |
| **Settings restored** | branch protections are snapshotted and restored to their exact prior state; archived repos are re-archived |
| **Independent verify** | the final scan shares no state with the pipeline — it re-enumerates and re-reads everything from the API |
| **Truncation guards** | repo enumeration is cross-checked, so a silent network failure can't masquerade as "all clean" |

## Requirements

- `bash` 4+, `git` 2.22+, `jq`
- [GitHub CLI (`gh`)](https://cli.github.com), authenticated with access to your repos
- [`git-filter-repo`](https://github.com/newren/git-filter-repo) (`pip install git-filter-repo`)

## Quickstart

```bash
git clone https://github.com/shenxingy/git-email-migrator.git
cd git-email-migrator

cp config.example.env config.env
$EDITOR config.env            # set OLD_EMAILS and NEW_EMAIL

# 0. CRITICAL: verify NEW_EMAIL on your GitHub account first
#    (Settings → Emails). Attribution follows verified emails.

# 1. Find every repo carrying the old email
#    (tip: set ONLY_REPOS="you/one-small-repo" for a trial run first)
./migrate.sh audit

# 2. Dry run — rewrite + validate locally, push nothing
./migrate.sh migrate

# 3. Review work/migrate.tsv, then go live:
#    edit config.env → DRY_RUN=0, and re-run
./migrate.sh migrate

# 4. Handle protected/archived repos, if any failed
./migrate.sh unblock

# 5. Repoint your local clones (uncommitted work survives)
./migrate.sh sync

# 6. Prove it: independent zero-residue scan across every ref
SCAN_MODE=clone ./migrate.sh verify
```

## Commands

| Command | What it does | Writes |
|---|---|---|
| `audit` | enumerate user + org repos, count old-email commits per repo | `work/audit.tsv` |
| `migrate` | rewrite, validate, and (when `DRY_RUN=0`) force-push each affected repo | `work/migrate.tsv` |
| `unblock` | retry `PUSH_FAIL` repos: toggle branch protection / unarchive, push, restore settings | `work/unblock.tsv` |
| `sync` | repoint local clones to rewritten history via tree-hash + timestamp commit mapping | `work/sync.tsv` |
| `verify` | independent full re-scan; exits non-zero on any residue | `work/verify.tsv` |
| `restore <owner/repo>` | force-push a repo's backup bundle, undoing its rewrite | — |

## After migrating

1. **Tell collaborators** on shared repos to re-sync (their work is safe —
   trees are identical, only hashes changed):
   ```bash
   git stash && git fetch origin && git reset --hard origin/HEAD && git stash pop
   ```
2. **Other machines** of yours need the same treatment — or just run
   `./migrate.sh sync` there too.
3. **Keep the old email on your GitHub account** until the contribution graph
   has rebuilt (up to 24 h), as a belt-and-braces fallback. After that it's
   genuinely optional.
4. **Don't panic about search.** `search/commits` results lag hours-to-days
   behind force-pushes. Commit pages and the contribution graph are live.
5. Delete `backups/` once you've confirmed everything (give it a week).

## Docs

- [How it works](docs/how-it-works.md) — GitHub's email→attribution model, why
  the graph survives a rewrite, fork caveats
- [Troubleshooting](docs/troubleshooting.md) — protected branches, rulesets,
  archived repos, hung SSH pushes, mixed-history validation
- [FAQ](docs/faq.md) — "will I lose my green squares?", collaborator impact,
  signed commits, repos you don't own

## License

[MIT](LICENSE)
