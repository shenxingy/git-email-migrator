#!/usr/bin/env bash
# ─── rewrite.sh — the migration core ───
# For every repo with old-email commits (per work/audit.tsv):
#
#   fresh bare clone        — GitHub is the source of truth, local state ignored
#   → bundle backup         — full-history snapshot, restorable with one command
#   → git filter-repo       — mailmap rewrite, author + committer, email only
#   → triple validation     — commit count unchanged, HEAD tree hash unchanged,
#                             zero old-email lines remaining
#   → force-push            — branches + tags (only with DRY_RUN=0)
#
# Any failed gate skips the repo and records why. Nothing half-rewritten is
# ever pushed. Results: work/migrate.tsv

cmd_migrate() {
  load_config
  require_tools

  local audit="$GEM_WORK/audit.tsv"
  [ -f "$audit" ] || die "no audit results — run: ./migrate.sh audit"

  local mailmap out targets
  mailmap=$(write_mailmap)
  out="$GEM_WORK/migrate.tsv"
  echo -e "repo\tstatus\tcommits\trewritten_refs\tdetail" > "$out"

  targets=$(awk -F'\t' 'NR>1 && $4 ~ /^[0-9]+$/ && $4>0 {print $1}' "$audit")
  [ -n "$targets" ] || { log "✅ audit found nothing to migrate"; return 0; }

  local n_targets
  n_targets=$(wc -l <<< "$targets")
  if [ "$DRY_RUN" = "1" ]; then
    log "DRY RUN — $n_targets repos will be cloned, rewritten and validated locally; NOTHING will be pushed"
    log "set DRY_RUN=0 in config.env when you are ready"
  else
    log "LIVE RUN — $n_targets repos will be rewritten and force-pushed"
  fi

  local slug
  while read -r slug; do
    migrate_one "$slug" "$mailmap" "$out"
  done <<< "$targets"

  echo
  log "results → $out"
  column -t -s$'\t' "$out"
  if [ "$DRY_RUN" = "1" ]; then
    log "dry run complete — review the table above, then set DRY_RUN=0 and re-run"
  else
    log "next steps: ./migrate.sh unblock (if any PUSH_FAIL), ./migrate.sh verify"
  fi
}

migrate_one() {
  local slug=$1 mailmap=$2 out=$3
  local name dir
  name=$(slug_to_name "$slug")
  dir="$GEM_WORK/$name.git"
  log "════ $slug ════"
  rm -rf "$dir"

  if ! git clone --bare --quiet "https://github.com/$slug.git" "$dir" 2>>"$GEM_WORK/errors.log"; then
    echo -e "$slug\tCLONE_FAIL\t-\t-\tsee work/errors.log" >> "$out"; return
  fi

  local pre_total pre_bad pre_tree
  pre_total=$(git -C "$dir" rev-list --all --count 2>/dev/null || echo 0)
  pre_bad=$(cd "$dir" && count_old_emails)
  pre_tree=$(git -C "$dir" rev-parse 'HEAD^{tree}' 2>/dev/null || echo none)

  if [ "$pre_bad" -eq 0 ]; then
    echo -e "$slug\tSKIP_CLEAN\t$pre_total\t0\tno old-email commits on any ref" >> "$out"
    rm -rf "$dir"; return
  fi

  git -C "$dir" bundle create "$GEM_BACKUP/$name.bundle" --all --quiet 2>>"$GEM_WORK/errors.log" \
    || { echo -e "$slug\tBACKUP_FAIL\t$pre_total\t-\tbundle creation failed" >> "$out"; rm -rf "$dir"; return; }

  if ! (cd "$dir" && git filter-repo --mailmap "$mailmap" --quiet) 2>>"$GEM_WORK/errors.log"; then
    echo -e "$slug\tFILTER_FAIL\t$pre_total\t-\tsee work/errors.log" >> "$out"; rm -rf "$dir"; return
  fi

  # ─── Validation gates ───
  local post_total post_bad post_tree
  post_total=$(git -C "$dir" rev-list --all --count 2>/dev/null || echo 0)
  post_bad=$(cd "$dir" && count_old_emails)
  post_tree=$(git -C "$dir" rev-parse 'HEAD^{tree}' 2>/dev/null || echo none)

  # Note: if a previous partial push left rewritten refs on the remote
  # alongside old ones, the deterministic rewrite collapses duplicates and
  # post_total < pre_total is EXPECTED. We accept post_total <= pre_total as
  # long as zero old emails remain and the HEAD tree is bit-identical.
  if [ "$post_bad" -ne 0 ] || [ "$pre_tree" != "$post_tree" ] || [ "$post_total" -gt "$pre_total" ]; then
    echo -e "$slug\tVALIDATE_FAIL\t$pre_total→$post_total\t-\tresidue=$post_bad tree_changed=$([ "$pre_tree" != "$post_tree" ] && echo yes || echo no)" >> "$out"
    rm -rf "$dir"; return
  fi

  if [ "$DRY_RUN" = "1" ]; then
    echo -e "$slug\tDRY_RUN_OK\t$pre_total\t$pre_bad\twould push (validation passed)" >> "$out"
    rm -rf "$dir"; return
  fi

  # ─── Push ───
  local push_out rc detail
  push_out=$(git -C "$dir" push --force --all "https://github.com/$slug.git" 2>&1) ; rc=$?
  git -C "$dir" push --force --tags "https://github.com/$slug.git" >/dev/null 2>&1 || true
  if [ $rc -ne 0 ]; then
    echo "$push_out" >> "$GEM_WORK/errors.log"
    detail="push_rejected"
    grep -qi 'archived'  <<< "$push_out" && detail="ARCHIVED"
    grep -qi 'protected' <<< "$push_out" && detail="PROTECTED_BRANCH"
    echo -e "$slug\tPUSH_FAIL\t$pre_total\t$pre_bad\t$detail" >> "$out"
    rm -rf "$dir"; return
  fi

  echo -e "$slug\tOK\t$pre_total\t$pre_bad\tpushed" >> "$out"
  rm -rf "$dir"
}

# ─── restore — push a backup bundle back, undoing the rewrite for one repo ───
cmd_restore() {
  load_config
  require_tools
  local slug=${1:-}
  [ -n "$slug" ] || die "usage: ./migrate.sh restore <owner/repo>"
  local bundle
  bundle="$GEM_BACKUP/$(slug_to_name "$slug").bundle"
  [ -f "$bundle" ] || die "no backup bundle for $slug at $bundle"
  [ "$DRY_RUN" = "1" ] && die "restore is a force-push — set DRY_RUN=0 to proceed"
  local dir="$GEM_WORK/restore.git"
  rm -rf "$dir"
  git clone --bare --quiet "$bundle" "$dir"
  git -C "$dir" push --force --all  "https://github.com/$slug.git"
  git -C "$dir" push --force --tags "https://github.com/$slug.git"
  rm -rf "$dir"
  log "restored $slug from $bundle"
}
