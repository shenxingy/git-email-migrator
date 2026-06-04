#!/usr/bin/env bash
# ─── common.sh — shared helpers: config, logging, validation ───
# Sourced by every command. Not executable on its own.

set -euo pipefail

# ─── Paths ───
GEM_ROOT="${GEM_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
GEM_WORK="${GEM_WORK:-$GEM_ROOT/work}"
GEM_BACKUP="${GEM_BACKUP:-$GEM_ROOT/backups}"
GEM_CONFIG="${GEM_CONFIG:-$GEM_ROOT/config.env}"

# ─── Logging ───
log()  { printf '\033[1;34m[gem]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[gem:warn]\033[0m %s\n' "$*" >&2; }
err()  { printf '\033[1;31m[gem:error]\033[0m %s\n' "$*" >&2; }
die()  { err "$*"; exit 1; }

# ─── Config ───
# Required: OLD_EMAILS (space-separated), NEW_EMAIL
# Optional: ORGS (space-separated; defaults to your user + memberships),
#           EXCLUDE_REPOS (space-separated owner/name slugs),
#           DRY_RUN (default 1 — nothing is pushed unless explicitly disabled)
load_config() {
  [ -f "$GEM_CONFIG" ] || die "config not found: $GEM_CONFIG (copy config.example.env to config.env)"
  # shellcheck source=/dev/null
  source "$GEM_CONFIG"
  : "${OLD_EMAILS:?OLD_EMAILS is required (space-separated list)}"
  : "${NEW_EMAIL:?NEW_EMAIL is required}"
  DRY_RUN="${DRY_RUN:-1}"
  ORGS="${ORGS:-}"
  EXCLUDE_REPOS="${EXCLUDE_REPOS:-}"
  mkdir -p "$GEM_WORK" "$GEM_BACKUP"
}

# ─── Preflight ───
require_tools() {
  command -v git >/dev/null || die "git is required"
  command -v gh  >/dev/null || die "gh (GitHub CLI) is required — https://cli.github.com"
  command -v git-filter-repo >/dev/null || die "git-filter-repo is required — pip install git-filter-repo"
  gh auth status >/dev/null 2>&1 || die "gh is not authenticated — run: gh auth login"
}

# ─── Mailmap ───
# git-filter-repo mailmap format: <new-email> <old-email> maps email only,
# leaving author/committer names untouched.
write_mailmap() {
  local f="$GEM_WORK/mailmap.txt" old
  : > "$f"
  for old in $OLD_EMAILS; do
    printf '<%s> <%s>\n' "$NEW_EMAIL" "$old" >> "$f"
  done
  echo "$f"
}

# ─── Repo enumeration ───
# All repos across the authenticated user + every org they belong to
# (or the explicit ORGS list), minus EXCLUDE_REPOS.
list_repos() {
  local owners owner
  if [ -n "$ORGS" ]; then
    owners="$ORGS"
  else
    owners="$(gh api user --jq '.login') $(gh api user/orgs --paginate --jq '.[].login' | tr '\n' ' ')"
  fi
  for owner in $owners; do
    gh repo list "$owner" --limit 1000 --json nameWithOwner --jq '.[].nameWithOwner'
  done | sort -u | filter_excluded
}

filter_excluded() {
  if [ -z "$EXCLUDE_REPOS" ]; then cat; return; fi
  grep -vFx -f <(tr ' ' '\n' <<< "$EXCLUDE_REPOS" | sed '/^$/d')
}

# ─── Email counting in a local (bare) clone ───
# Counts author+committer lines matching any OLD_EMAIL across all refs.
count_old_emails() {
  local total=0 old n
  for old in $OLD_EMAILS; do
    n=$(git log --all --format='%ae%n%ce' 2>/dev/null | grep -cFx "$old" || true)
    total=$((total + n))
  done
  echo "$total"
}

# ─── Slug helpers ───
slug_to_name() { echo "${1//\//__}"; }
