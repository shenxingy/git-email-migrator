[← back to README](../README.md)

# Troubleshooting

Every entry here is a failure mode hit during the real ~6,000-commit migration
this tool was extracted from.

- [PUSH_FAIL: PROTECTED_BRANCH](#push_fail-protected_branch)
- [PUSH_FAIL: ARCHIVED](#push_fail-archived)
- [VALIDATE_FAIL after a partial push (mixed history)](#validate_fail-after-a-partial-push-mixed-history)
- [A push hangs forever](#a-push-hangs-forever)
- [Audit/verify scanned fewer repos than expected](#auditverify-scanned-fewer-repos-than-expected)
- [Repos with rulesets](#repos-with-rulesets)
- [`?author=` API filtering lies](#author-api-filtering-lies)
- [Search still shows old-email commits](#search-still-shows-old-email-commits)

## PUSH_FAIL: PROTECTED_BRANCH

Classic branch protection rejects force-pushes even from admins.
`./migrate.sh unblock` handles it: snapshots the protection JSON to
`work/protection__<repo>.json`, enables `allow_force_pushes`, pushes, then
restores the exact prior configuration. If restoration ever fails you still
have the snapshot to reapply manually.

## PUSH_FAIL: ARCHIVED

Archived repos are read-only. `unblock` unarchives → pushes → re-archives.
Requires admin permission on the repo.

## VALIDATE_FAIL after a partial push (mixed history)

Scenario: a first `migrate` run pushed a repo's side branches but the
protected default branch was rejected. The remote now holds **both** histories
— old `main`, rewritten side branches — and a fresh clone has roughly double
the commits. The strict "count must not change" expectation would fail here.

This is benign and handled: because the rewrite is deterministic, re-rewriting
the old commits produces byte-identical SHAs to the already-pushed ones, the
duplicates collapse, and the count converges back to the canonical number. The
pipeline therefore accepts `post_total <= pre_total` as long as the tree hash
is identical and zero residue remains.

## A push hangs forever

Symptom: `git push` sits for 10+ minutes; `ps` shows an `ssh … git-receive-pack`
child that never progresses. A stalled TCP connection, not a tool bug.

Fix: kill the stuck `ssh`/`git push` process and re-run the command — pushes
are idempotent here (deterministic rewrite, `--force`). The pipeline uses
HTTPS remotes via `gh`'s credential helper, which is less prone to this than
multiplexed SSH, but networks gonna network.

## Audit/verify scanned fewer repos than expected

Repo enumeration is a paginated network call; a transient TLS failure can
silently truncate the list, which would make a partial scan look like a clean
full scan. Both `audit` and `verify` cross-check *listed vs scanned* counts —
audit warns, verify hard-fails. If you see the warning, just re-run.

## Repos with rulesets

`unblock` only automates **classic** branch protection. Repos using the newer
rulesets API are reported as `MANUAL`: temporarily disable the ruleset in
*Settings → Rules*, re-run `migrate`, re-enable.

## `?author=` API filtering lies

`GET /repos/{owner}/{repo}/commits?author=<email>` resolves the email to a
**user account** and returns commits by that user under *any* of their emails.
For residue checking this over-matches catastrophically. This tool always
reads the raw `commit.author.email` / `commit.committer.email` fields instead.

## Search still shows old-email commits

`search/commits` is an index, rebuilt lazily — it lags hours-to-days behind
force-pushes and may briefly double-count. Judge success by `verify` (live
API reads) and by commit pages, not by search totals.
