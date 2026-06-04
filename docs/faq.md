[← back to README](../README.md)

# FAQ

- [Will I lose my green squares?](#will-i-lose-my-green-squares)
- [I already deleted the old email and my contributions vanished!](#i-already-deleted-the-old-email-and-my-contributions-vanished)
- [What happens to my collaborators?](#what-happens-to-my-collaborators)
- [What about repos I contributed to but don't own?](#what-about-repos-i-contributed-to-but-dont-own)
- [What about open pull requests?](#what-about-open-pull-requests)
- [Signed commits?](#signed-commits)
- [Why rewrite at all — can't I just keep the old email verified?](#why-rewrite-at-all--cant-i-just-keep-the-old-email-verified)
- [Does this touch commit dates or messages?](#does-this-touch-commit-dates-or-messages)
- [CI/CD triggered on force-push?](#cicd-triggered-on-force-push)
- [How long does it take?](#how-long-does-it-take)

## Will I lose my green squares?

No — that's the entire point. Squares are keyed on author **date** + verified
email. Dates are untouched; the email becomes one that's verified on your
account. The graph rebuilds to the same squares (allow up to 24 h).
**Prerequisite: verify `NEW_EMAIL` on your GitHub account before pushing.**

## I already deleted the old email and my contributions vanished!

If the mailbox still works: re-add and re-verify the same address on GitHub
**right now** — attribution restores automatically (graph rebuild ≤ 24 h).
Then run this tool so it never matters again. If the mailbox is already dead,
the rewrite is your only path — and it fully works.

## What happens to my collaborators?

Their commits are untouched (the mailmap only matches your old email), but
every commit **hash** after the earliest rewritten commit changes, so their
clones reference dead history. They re-sync losslessly with:

```bash
git stash && git fetch origin && git reset --hard origin/main && git stash pop
```

Unpushed local branches need `git rebase --onto origin/main <old-base>`.
Announce the migration before pushing shared repos; don't surprise people.

## What about repos I contributed to but don't own?

You can't rewrite history you don't control. Two options:

1. Keep the old email verified on your account forever (zero effort, works
   while the address is yours and the account keeps it).
2. Ask the owner to run the same mailmap rewrite on their side.

Add such repos to `EXCLUDE_REPOS` so the pipeline doesn't try.

## What about open pull requests?

PRs whose base/head commits were rewritten will show broken diffs or close
themselves. Merge or close important PRs before migrating, recreate the
stragglers after.

## Signed commits?

Rewriting invalidates GPG/SSH signatures on rewritten commits (the signed
metadata changed) — they'll show "Unverified" instead of "Verified". The
trade-off is permanent attribution; most people take it.

## Why rewrite at all — can't I just keep the old email verified?

You can, and it works — until it doesn't. The address stays verified on your
account even after its mail service dies, but if you ever remove it (or lose
the account), there's no way back, and an attacker who re-registers the dead
domain could try to claim the address. Rewriting removes the dependency
entirely. Belt and braces: do the rewrite *and* keep the old email verified
until the dust settles.

## Does this touch commit dates or messages?

No. Only the email field of matching author/committer entries. Names, dates,
messages, and all file content are bit-identical — and the pipeline *proves*
the latter per repo by comparing `HEAD^{tree}` hashes.

## CI/CD triggered on force-push?

Push-triggered workflows (deploys, builds) will fire once per repo. Content
is identical, so deploys are no-ops, but budget for the CI noise — or pause
heavyweight workflows first.

## How long does it take?

Dominated by clone size, not commit count. The reference migration —
200+ repos, ~6,000 rewritten commits, several multi-GB repos — took roughly
half an hour of wall-clock for the full pipeline including verification.
