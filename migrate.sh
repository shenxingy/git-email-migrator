#!/usr/bin/env bash
# ─── git-email-migrator — rewrite your commit email everywhere, safely ───
# https://github.com/shenxingy/git-email-migrator
#
#   ./migrate.sh audit     discover every repo carrying your old email
#   ./migrate.sh migrate   rewrite + validate (+ push when DRY_RUN=0)
#   ./migrate.sh unblock   retry protected-branch / archived-repo failures
#   ./migrate.sh sync      repoint local clones to the rewritten history
#   ./migrate.sh verify    independent zero-residue verification
#   ./migrate.sh restore   roll one repo back from its backup bundle

set -euo pipefail

GEM_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export GEM_ROOT

# shellcheck source=lib/common.sh
source "$GEM_ROOT/lib/common.sh"
# shellcheck source=lib/audit.sh
source "$GEM_ROOT/lib/audit.sh"
# shellcheck source=lib/rewrite.sh
source "$GEM_ROOT/lib/rewrite.sh"
# shellcheck source=lib/unblock.sh
source "$GEM_ROOT/lib/unblock.sh"
# shellcheck source=lib/sync-local.sh
source "$GEM_ROOT/lib/sync-local.sh"
# shellcheck source=lib/verify.sh
source "$GEM_ROOT/lib/verify.sh"

usage() {
  sed -n '2,10p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
  cat <<'EOF'

Setup:
  cp config.example.env config.env   # then edit it
  ./migrate.sh audit

Safety model:
  - DRY_RUN=1 (the default) never pushes anything
  - every repo is backed up to a git bundle before rewriting
  - a rewrite is only pushed after three validation gates pass:
      commit count sane, HEAD tree hash identical, zero old-email residue
EOF
}

main() {
  local cmd="${1:-help}"
  shift || true
  case "$cmd" in
    audit)    cmd_audit   "$@" ;;
    migrate)  cmd_migrate "$@" ;;
    unblock)  cmd_unblock "$@" ;;
    sync)     cmd_sync    "$@" ;;
    verify)   cmd_verify  "$@" ;;
    restore)  cmd_restore "$@" ;;
    help|-h|--help) usage ;;
    *) usage; die "unknown command: $cmd" ;;
  esac
}

main "$@"
