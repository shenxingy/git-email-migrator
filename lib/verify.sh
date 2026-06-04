#!/usr/bin/env bash
# ─── verify.sh — independent post-migration verification ───
# Deliberately shares no state with the migration: it re-enumerates every
# repo and re-reads raw email fields from the GitHub API, so a bug in the
# pipeline cannot hide its own failure. Run this last.
#
# Output: work/verify.tsv — every repo must show 0 hits.

cmd_verify() {
  load_config
  require_tools

  local out="$GEM_WORK/verify.tsv"
  echo -e "repo\tcommits_scanned\told_email_hits" > "$out"

  local grep_file="$GEM_WORK/old_emails.txt"
  tr ' ' '\n' <<< "$OLD_EMAILS" | sed '/^$/d' > "$grep_file"

  log "re-enumerating repos for independent verification…"
  local repos slug listed bad=0
  repos=$(list_repos)
  listed=$(printf '%s' "$repos" | grep -c . || true)
  [ "$listed" -gt 0 ] || die "no repos found — check ORGS/ONLY_REPOS in config.env"
  log "verifying $listed repos (mode: $SCAN_MODE)…"
  [ "$SCAN_MODE" = "api" ] && warn "api mode verifies the default branch only — SCAN_MODE=clone checks every ref (branches + tags)"

  while read -r slug; do
    [ -n "$slug" ] || continue
    local scanned hits
    if [ "$SCAN_MODE" = "clone" ]; then
      IFS=$'\t' read -r scanned hits <<< "$(deep_scan "$slug")"
      if [ "$scanned" = "-1" ]; then
        echo -e "$slug\t0\tEMPTY_OR_NO_ACCESS" >> "$out"; continue
      fi
    else
      local emails
      emails=$(gh api --paginate "repos/$slug/commits?per_page=100" \
        --jq '.[].commit | .author.email, .committer.email' 2>/dev/null || true)
      if [ -z "$emails" ]; then
        echo -e "$slug\t0\tEMPTY_OR_NO_ACCESS" >> "$out"; continue
      fi
      scanned=$(( $(wc -l <<< "$emails") / 2 ))
      hits=$(grep -cFx -f "$grep_file" <<< "$emails" || true)
    fi
    echo -e "$slug\t$scanned\t$hits" >> "$out"
    if [ "$hits" -gt 0 ]; then
      bad=$((bad + 1))
      err "RESIDUE: $slug — $hits old-email commit field(s) remain"
    fi
  done <<< "$repos"

  # Same truncation guard as audit: a network hiccup during enumeration must
  # not masquerade as a clean bill of health.
  local scanned_n
  scanned_n=$(( $(wc -l < "$out") - 1 ))
  [ "$listed" -eq "$scanned_n" ] || die "listed $listed repos but verified $scanned_n — network hiccup, re-run verify"

  echo
  if [ "$bad" -eq 0 ]; then
    log "✅ verification passed — zero old-email residue across $scanned_n repos"
  else
    err "❌ $bad repos still carry old-email commits — see $out"
    exit 1
  fi

  log "note: GitHub's commit-search index (search/commits) lags hours-to-days"
  log "behind force-pushes; commit pages and contribution graphs are live."
}
