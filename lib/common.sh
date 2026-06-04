#!/usr/bin/env bash
# ─── common.sh — shared helpers: config, logging, validation ───
# Sourced by every command. Not executable on its own.

set -euo pipefail

# ─── Paths ───
GEM_ROOT="${GEM_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
GEM_WORK="${GEM_WORK:-$GEM_ROOT/work}"
GEM_BACKUP="${GEM_BACKUP:-$GEM_ROOT/backups}"
GEM_CONFIG="${GEM_CONFIG:-$GEM_ROOT/config.env}"
# Remote base — overridable so the test suite can point at local bare repos.
GEM_REMOTE_BASE="${GEM_REMOTE_BASE:-https://github.com/}"

repo_url() { echo "${GEM_REMOTE_BASE}$1.git"; }

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
  ONLY_REPOS="${ONLY_REPOS:-}"
  SCAN_MODE="${SCAN_MODE:-api}"
  case "$SCAN_MODE" in api|clone) ;; *) die "SCAN_MODE must be 'api' or 'clone'" ;; esac
  mkdir -p "$GEM_WORK" "$GEM_BACKUP"
}

# ─── Preflight ───
require_tools() {
  command -v git >/dev/null || die "git is required"
  command -v jq  >/dev/null || die "jq is required — https://jqlang.github.io/jq"
  command -v git-filter-repo >/dev/null || die "git-filter-repo is required — pip install git-filter-repo"
  # gh is only needed when talking to github.com (tests use a local remote base)
  case "$GEM_REMOTE_BASE" in
    https://github.com/*)
      command -v gh >/dev/null || die "gh (GitHub CLI) is required — https://cli.github.com"
      gh auth status >/dev/null 2>&1 || die "gh is not authenticated — run: gh auth login"
      # Clones/pushes use HTTPS; make sure git can use gh's credentials.
      # Idempotent — wires gh up as a git credential helper for github.com.
      gh auth setup-git >/dev/null 2>&1 || warn "gh auth setup-git failed — HTTPS pushes may not authenticate"
      ;;
  esac
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
# ONLY_REPOS (explicit slugs) if set; otherwise all repos across the
# authenticated user + every org they belong to (or the explicit ORGS list).
# EXCLUDE_REPOS is always applied.
list_repos() {
  if [ -n "$ONLY_REPOS" ]; then
    tr ' ' '\n' <<< "$ONLY_REPOS" | sed '/^$/d' | sort -u | filter_excluded
    return
  fi
  local owners owner batch n
  if [ -n "$ORGS" ]; then
    owners="$ORGS"
  else
    owners="$(gh api user --jq '.login') $(gh api user/orgs --paginate --jq '.[].login' | tr '\n' ' ')"
  fi
  for owner in $owners; do
    batch=$(gh repo list "$owner" --limit 1000 --json nameWithOwner --jq '.[].nameWithOwner')
    n=$(printf '%s' "$batch" | grep -c . || true)
    [ "$n" -ge 1000 ] && warn "$owner returned $n repos — gh repo list caps at 1000, some may be missing"
    printf '%s\n' "$batch"
  done | sed '/^$/d' | sort -u | filter_excluded
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

# ─── Deep scan: bare-clone a repo and count old emails across ALL refs ───
# The commits API only covers the default branch; this covers everything
# (branches, tags) at the cost of a clone. Prints "total<TAB>hits", or
# "-1<TAB>-1" on clone failure.
deep_scan() {
  local slug=$1 dir total hits
  dir="$GEM_WORK/scan__$(slug_to_name "$slug").git"
  rm -rf "$dir"
  if ! git clone --bare --quiet "$(repo_url "$slug")" "$dir" 2>/dev/null; then
    printf -- '-1\t-1\n'; return
  fi
  total=$(git -C "$dir" rev-list --all --count 2>/dev/null || echo 0)
  hits=$(cd "$dir" && count_old_emails)
  rm -rf "$dir"
  printf '%s\t%s\n' "$total" "$hits"
}
