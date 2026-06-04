[← back to README](../README.md)

# How it works

- [GitHub's attribution model](#githubs-attribution-model)
- [Why removing an email is dangerous](#why-removing-an-email-is-dangerous)
- [What a mailmap rewrite changes (and what it doesn't)](#what-a-mailmap-rewrite-changes-and-what-it-doesnt)
- [Why your contribution graph survives](#why-your-contribution-graph-survives)
- [The validation gates](#the-validation-gates)
- [Local clone syncing](#local-clone-syncing)
- [Forks](#forks)

## GitHub's attribution model

GitHub never stores "this commit belongs to user X". Attribution is resolved
**live** by matching the commit's `author.email` against the verified email
addresses on accounts:

```
commit e-mail  ──matches──▶  verified e-mail on your account  ──▶  your avatar,
                                                                   profile link,
                                                                   green square
```

This has two consequences:

1. Adding a verified email retroactively claims every commit ever made with it.
   GitHub's own docs: *"Your contributions graph will be rebuilt automatically
   when you add the new address."*
2. Removing an email instantly orphans every commit made with it.

## Why removing an email is dangerous

If the removed email's mail service still exists, you can re-add and re-verify
it — attribution comes back (allow up to 24 h for the graph rebuild).

If the mail service is **gone**, you can never re-verify. Worse, if the domain
is later re-registered, the new owner can verify *your* old address on *their*
account and claim your commit history. Decommissioned company/school domains
are exactly the addresses this happens to.

Hence this tool: move the history itself onto an address you'll always control.

## What a mailmap rewrite changes (and what it doesn't)

The rewrite is `git filter-repo --mailmap` with entries like:

```
<you@example.com> <old@company.com>
```

| Field | Changed? |
|---|---|
| author email / committer email | ✅ rewritten when it matches |
| author & committer **name** | ❌ untouched |
| author & committer **date** | ❌ untouched |
| commit message | ❌ untouched |
| every file / tree / blob | ❌ bit-identical |
| commit SHA | ⚠️ changes (it hashes the metadata) |
| GPG signatures | ⚠️ invalidated ("unverified" badge) — the metadata they signed changed |

## Why your contribution graph survives

Green squares are computed from (commit author **date**, commit author
**email**, default branch membership). The rewrite preserves dates and branch
topology exactly and swaps the email for one that's verified on your account —
so the graph recomputes to the same squares, same days, same counts.

## The validation gates

A rewritten repo is only pushed when all three hold:

1. **Count parity** — `git rev-list --all --count` must not grow. (It may
   *shrink* in one legitimate case: if an earlier partial push left rewritten
   refs alongside old ones, the deterministic rewrite collapses the duplicates
   back to the canonical count.)
2. **Tree identity** — `HEAD^{tree}` hash must be bit-identical pre/post.
   This single check proves no file content changed anywhere in the checkout.
3. **Zero residue** — no `author`/`committer` field on any ref still matches
   any `OLD_EMAILS` entry.

Determinism is what makes retries safe: rewriting the same history twice
produces byte-identical commits, so partial failures converge instead of
forking.

## Local clone syncing

After the force-push, local clones still point at old hashes. `sync` maps each
local branch tip to its rewritten counterpart by **(tree hash, author
timestamp, subject)** — a fingerprint the rewrite provably preserves — then:

- current branch → `git reset --soft` (index and worktree untouched; dirty
  files and staged changes survive, because the trees are identical)
- other branches → `git branch -f`

Branches that were behind origin get mapped to the rewritten equivalent of
*their old position* — nothing is yanked forward. Branches with unpushed
commits are reported (`NO_MATCH`) for a manual rebase rather than guessed at.

## Forks

Commits in forks don't count toward the contribution graph, so forks are
low-priority — but they still display the old email publicly. The pipeline
treats them like any other repo you own: audit finds them, migrate rewrites
them. Forks of *other people's* repos that you merely contributed to can't be
rewritten by you; keep the old email verified on your account to retain
attribution there (see [FAQ](faq.md)).
