#!/usr/bin/env bash
# ─── local-e2e.sh — offline end-to-end test ───
# Simulates a remote with a local bare repo (GEM_REMOTE_BASE override), then
# exercises the full pipeline: dry-run migrate → live migrate → sync → restore.
# Asserts every safety property the README promises. No network, no GitHub.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

PASS=0
ok()   { PASS=$((PASS+1)); printf '  ✔ %s\n' "$1"; }
fail() { printf '  ✘ %s\n' "$1" >&2; exit 1; }

OLD1="legacy@corp.test"
OLD2="intern@corp.test"
KEEP="colleague@elsewhere.test"
NEW="permanent@example.test"

# ─── Fixture: a "remote" bare repo with old-email commits everywhere ───
mkdir -p "$TMP/remotes/acme"
git init --bare --quiet "$TMP/remotes/acme/widget.git"

mkdir -p "$TMP/clones"
git clone --quiet "$TMP/remotes/acme/widget.git" "$TMP/clones/widget" 2>/dev/null
cd "$TMP/clones/widget"
git config user.name "Dev One"

git config user.email "$OLD1"
echo a > a.txt && git add a.txt && git commit -qm "feat: first"
git config user.email "$KEEP"
echo b > b.txt && git add b.txt && git commit -qm "feat: by a colleague"
git config user.email "$OLD2"
echo c > c.txt && git add c.txt && git commit -qm "fix: third"

git config user.email "$OLD1"
git tag -a v1.0 -m "release v1.0"                      # tagger = OLD1
git checkout -qb feature
echo d > d.txt && git add d.txt && git commit -qm "feat: branch-only commit"  # only on feature
git checkout -q master 2>/dev/null || git checkout -q main

git push --quiet --all origin && git push --quiet --tags origin

DEFAULT_BRANCH=$(git rev-parse --abbrev-ref HEAD)
PRE_MAIN_SHA=$(git rev-parse HEAD)
PRE_TREE=$(git rev-parse 'HEAD^{tree}')
PRE_DATES=$(git log --all --format='%at' | sort)
PRE_COUNT=$(git rev-list --all --count)

# ─── Pipeline environment: point the tool at the local "remote" ───
export GEM_REMOTE_BASE="$TMP/remotes/"
export GEM_WORK="$TMP/work" GEM_BACKUP="$TMP/backup" GEM_CONFIG="$TMP/config.env"
mkdir -p "$GEM_WORK"

write_config() {  # $1 = DRY_RUN value
  cat > "$GEM_CONFIG" <<EOF
OLD_EMAILS="$OLD1 $OLD2"
NEW_EMAIL="$NEW"
DRY_RUN=$1
ONLY_REPOS="acme/widget"
LOCAL_ROOTS="$TMP/clones"
EOF
}

# audit needs the GitHub API, so the target list is handcrafted — the unit
# under test here is migrate/sync/restore, not enumeration.
echo -e "repo\tcreated\tcommits_scanned\told_email_hits" >  "$GEM_WORK/audit.tsv"
echo -e "acme/widget\t2026-01-01\t4\t4"                  >> "$GEM_WORK/audit.tsv"

echo "── dry-run migrate ──"
write_config 1
"$ROOT/migrate.sh" migrate >/dev/null
grep -q $'acme/widget\tDRY_RUN_OK' "$GEM_WORK/migrate.tsv" || fail "dry run should validate and report DRY_RUN_OK"
ok "dry run validates without pushing"
[ "$(git -C "$TMP/remotes/acme/widget.git" rev-parse "refs/heads/$DEFAULT_BRANCH")" = "$PRE_MAIN_SHA" ] \
  || fail "dry run must not touch the remote"
ok "remote untouched after dry run"

echo "── live migrate ──"
write_config 0
"$ROOT/migrate.sh" migrate >/dev/null
grep -q $'acme/widget\tOK\t' "$GEM_WORK/migrate.tsv" || fail "live migrate should report OK"
ok "live migrate pushed"

R="$TMP/remotes/acme/widget.git"
RESIDUE=$(git -C "$R" log --all --format='%ae%n%ce' | grep -cE "^($OLD1|$OLD2)$" || true)
[ "$RESIDUE" -eq 0 ] || fail "old emails remain on branches ($RESIDUE)"
ok "zero residue across ALL refs (incl. branch-only commit)"

TAG_BAD=$(git -C "$R" cat-file tag v1.0 | grep -c "$OLD1" || true)
[ "$TAG_BAD" -eq 0 ] || fail "annotated tag still carries the old tagger email"
ok "annotated tag rewritten"

[ "$(git -C "$R" rev-parse "refs/heads/$DEFAULT_BRANCH^{tree}")" = "$PRE_TREE" ] || fail "tree hash changed"
ok "file trees bit-identical"
[ "$(git -C "$R" rev-list --all --count)" = "$PRE_COUNT" ] || fail "commit count changed"
ok "commit count preserved"
[ "$(git -C "$R" log --all --format='%at' | sort)" = "$PRE_DATES" ] || fail "author dates changed"
ok "author dates preserved (contribution graph keeps its squares)"
git -C "$R" log --all --format='%ae' | grep -qFx "$KEEP" || fail "colleague's email was rewritten"
ok "other people's emails untouched"

echo "── sync local clone ──"
cd "$TMP/clones/widget"
echo "uncommitted work" >> a.txt                      # dirty file must survive
"$ROOT/migrate.sh" sync >/dev/null
grep -q $'widget\t'"$DEFAULT_BRANCH"$'\tRESET' "$GEM_WORK/sync.tsv" || fail "sync should RESET the current branch"
NEW_MAIN_SHA=$(git -C "$R" rev-parse "refs/heads/$DEFAULT_BRANCH")
[ "$(git rev-parse HEAD)" = "$NEW_MAIN_SHA" ] || fail "local branch not repointed to rewritten history"
ok "local branch repointed to rewritten history"
grep -q "uncommitted work" a.txt || fail "dirty file content lost"
[ -z "$(git diff --cached)" ] || fail "sync left phantom staged changes"
ok "dirty worktree survived sync untouched"

echo "── restore from backup bundle ──"
"$ROOT/migrate.sh" restore acme/widget >/dev/null
[ "$(git -C "$R" rev-parse "refs/heads/$DEFAULT_BRANCH")" = "$PRE_MAIN_SHA" ] || fail "restore did not bring back original history"
ok "restore returns the remote to its exact pre-migration state"

echo
echo "✅ all $PASS assertions passed"
