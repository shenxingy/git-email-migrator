#!/usr/bin/env bash
# ─── audit.sh — discover where your old email lives ───
# Enumerates every repo across your user account and org memberships, then
# counts commits on the default branch whose author OR committer email matches
# any OLD_EMAIL. Reads the raw email fields from the commits API — it does NOT
# use the `?author=` filter, which resolves emails to user accounts and
# over-matches (it would count ALL your commits, not just old-email ones).
#
# Output: work/audit.tsv  (repo, created, scanned, hits)

cmd_audit() {
  load_config
  require_tools

  local out="$GEM_WORK/audit.tsv"
  echo -e "repo\tcreated\tcommits_scanned\told_email_hits" > "$out"

  log "enumerating repos (user + org memberships)…"
  local repos total
  repos=$(list_repos)
  total=$(printf '%s' "$repos" | grep -c . || true)
  [ "$total" -gt 0 ] || { warn "no repos found — check ORGS/ONLY_REPOS in config.env"; return 0; }
  log "scanning $total repos (mode: $SCAN_MODE) for: $OLD_EMAILS"
  [ "$SCAN_MODE" = "api" ] && log "note: api mode covers the default branch only — use SCAN_MODE=clone for all refs"

  local slug i=0 grep_file="$GEM_WORK/old_emails.txt"
  tr ' ' '\n' <<< "$OLD_EMAILS" | sed '/^$/d' > "$grep_file"

  while read -r slug; do
    [ -n "$slug" ] || continue
    i=$((i + 1))
    local created scanned hits
    created=$(gh api "repos/$slug" --jq '.created_at[:10]' 2>/dev/null || echo "?")
    if [ "$SCAN_MODE" = "clone" ]; then
      IFS=$'\t' read -r scanned hits <<< "$(deep_scan "$slug")"
      if [ "$scanned" = "-1" ]; then
        echo -e "$slug\t$created\t0\tEMPTY_OR_NO_ACCESS" >> "$out"; continue
      fi
    else
      local emails
      emails=$(gh api --paginate "repos/$slug/commits?per_page=100" \
        --jq '.[].commit | .author.email, .committer.email' 2>/dev/null || true)
      if [ -z "$emails" ]; then
        echo -e "$slug\t$created\t0\tEMPTY_OR_NO_ACCESS" >> "$out"
        continue
      fi
      scanned=$(( $(wc -l <<< "$emails") / 2 ))
      hits=$(grep -cFx -f "$grep_file" <<< "$emails" || true)
    fi
    echo -e "$slug\t$created\t$scanned\t$hits" >> "$out"
    [ "$hits" -gt 0 ] && log "  [$i/$total] $slug — $hits hit(s)"
  done <<< "$repos"

  # Cross-check: the enumeration call can silently truncate on a network
  # error, which looks identical to "scanned everything". Fail loudly instead.
  local scanned_n
  scanned_n=$(( $(wc -l < "$out") - 1 ))
  [ "$total" -eq "$scanned_n" ] || warn "listed $total repos but scanned $scanned_n — re-run audit"

  echo
  log "audit complete → $out"
  awk -F'\t' 'NR>1 && $4 ~ /^[0-9]+$/ && $4>0 {n++; c+=$4} END {
    printf "[gem] repos with old-email commits: %d (total hits: %d)\n", n, c
    if (n == 0) print "[gem] ✅ nothing to migrate"
  }' "$out"

  # Global search count (default branches, may lag hours behind reality)
  local old
  for old in $OLD_EMAILS; do
    local n
    n=$(gh api "search/commits?q=author-email:$old&per_page=1" --jq '.total_count' 2>/dev/null || echo "?")
    log "GitHub-wide search count for $old: $n (search index may lag)"
  done
}
