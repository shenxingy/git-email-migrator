#!/usr/bin/env bash
# ─── unblock.sh — retry PUSH_FAIL repos (protected branches, archived repos) ───
# Two failure modes need account-level toggles that the core pipeline refuses
# to touch on its own:
#
#   PROTECTED_BRANCH → snapshot protection → enable allow_force_pushes →
#                      rewrite+push → restore the exact prior setting
#   ARCHIVED         → unarchive → rewrite+push → re-archive
#
# Protection snapshots are saved to work/protection__<repo>.json before any
# change. Only classic branch protection is handled; repos using rulesets are
# reported for manual review.

cmd_unblock() {
  load_config
  require_tools
  [ "$DRY_RUN" = "1" ] && die "unblock modifies repo settings and force-pushes — set DRY_RUN=0 first"

  local migrate_tsv="$GEM_WORK/migrate.tsv"
  [ -f "$migrate_tsv" ] || die "no migrate results — run: ./migrate.sh migrate"

  local mailmap out
  mailmap=$(write_mailmap)
  out="$GEM_WORK/unblock.tsv"
  echo -e "repo\tstatus\tdetail" > "$out"

  local failures
  failures=$(awk -F'\t' '$2=="PUSH_FAIL" {print $1"\t"$5}' "$migrate_tsv")
  [ -n "$failures" ] || { log "✅ no PUSH_FAIL entries to unblock"; return 0; }

  local slug reason
  while IFS=$'\t' read -r slug reason; do
    case "$reason" in
      ARCHIVED)         unblock_archived  "$slug" "$mailmap" "$out" ;;
      PROTECTED_BRANCH) unblock_protected "$slug" "$mailmap" "$out" ;;
      *) echo -e "$slug\tMANUAL\tunrecognized failure: $reason" >> "$out" ;;
    esac
  done <<< "$failures"

  echo
  column -t -s$'\t' "$out"
}

unblock_archived() {
  local slug=$1 mailmap=$2 out=$3
  log "════ $slug (archived) ════"
  gh api -X PATCH "repos/$slug" -F archived=false >/dev/null \
    || { echo -e "$slug\tUNARCHIVE_FAIL\tno admin permission?" >> "$out"; return; }
  local status
  status=$(rewrite_push_once "$slug" "$mailmap")
  gh api -X PATCH "repos/$slug" -F archived=true >/dev/null \
    || warn "$slug: re-archive failed — re-archive it manually"
  echo -e "$slug\t$status\tre-archived" >> "$out"
}

unblock_protected() {
  local slug=$1 mailmap=$2 out=$3
  log "════ $slug (protected branch) ════"

  local branch
  branch=$(gh api "repos/$slug" --jq '.default_branch')

  # Rulesets are a different API surface — report rather than guess.
  local rulesets
  rulesets=$(gh api "repos/$slug/rulesets" --jq 'length' 2>/dev/null || echo 0)
  if [ "${rulesets:-0}" -gt 0 ]; then
    echo -e "$slug\tMANUAL\thas rulesets — temporarily disable them in repo settings, re-run migrate" >> "$out"
    return
  fi

  # Snapshot current protection, then build the minimal PUT payload that
  # preserves it with allow_force_pushes toggled.
  local snap
  snap="$GEM_WORK/protection__$(slug_to_name "$slug").json"
  gh api "repos/$slug/branches/$branch/protection" > "$snap" 2>/dev/null \
    || { echo -e "$slug\tMANUAL\tcould not read protection (admin required)" >> "$out"; return; }

  if ! put_protection "$slug" "$branch" "$snap" true; then
    echo -e "$slug\tPROTECTION_TOGGLE_FAIL\tcould not enable force-push" >> "$out"; return
  fi

  local status
  status=$(rewrite_push_once "$slug" "$mailmap")

  put_protection "$slug" "$branch" "$snap" false \
    || warn "$slug: failed to restore protection — restore it manually from $snap"

  echo -e "$slug\t$status\tprotection restored" >> "$out"
}

# PUT branch protection rebuilt from a GET snapshot, with allow_force_pushes
# forced to $4. The GET and PUT schemas differ, hence the jq reshaping.
put_protection() {
  local slug=$1 branch=$2 snap=$3 force=$4
  jq --argjson force "$force" '{
      required_status_checks: (if .required_status_checks
        then {
          strict: .required_status_checks.strict,
          # modern app-scoped checks format; falls back to legacy contexts
          checks: (.required_status_checks.checks
                   // [(.required_status_checks.contexts // [])[] | {context: .}])
        }
        else null end),
      enforce_admins: (.enforce_admins.enabled // false),
      required_pull_request_reviews: (if .required_pull_request_reviews
        then {
          dismiss_stale_reviews: (.required_pull_request_reviews.dismiss_stale_reviews // false),
          require_code_owner_reviews: (.required_pull_request_reviews.require_code_owner_reviews // false),
          required_approving_review_count: (.required_pull_request_reviews.required_approving_review_count // 0)
        } else null end),
      restrictions: (if .restrictions
        then {
          users: [.restrictions.users[]?.login],
          teams: [.restrictions.teams[]?.slug],
          apps:  [.restrictions.apps[]?.slug]
        } else null end),
      allow_force_pushes: $force,
      allow_deletions: (.allow_deletions.enabled // false),
      required_linear_history: (.required_linear_history.enabled // false),
      required_conversation_resolution: (.required_conversation_resolution.enabled // false)
    }' "$snap" \
  | gh api -X PUT "repos/$slug/branches/$branch/protection" --input - >/dev/null
}

# One-shot rewrite + push, reusing the same validation gates as migrate_one.
# Accepts post_total <= pre_total: after a partial push, the remote holds old
# and rewritten history side by side, and the deterministic rewrite collapses
# the duplicates back to the canonical count.
rewrite_push_once() {
  local slug=$1 mailmap=$2
  local name dir
  name=$(slug_to_name "$slug")
  dir="$GEM_WORK/unblock__$name.git"
  rm -rf "$dir"

  git clone --bare --quiet "$(repo_url "$slug")" "$dir" || { echo "CLONE_FAIL"; return; }

  local pre_total pre_tree
  pre_total=$(git -C "$dir" rev-list --all --count)
  pre_tree=$(git -C "$dir" rev-parse 'HEAD^{tree}' 2>/dev/null || echo none)
  git -C "$dir" bundle create "$GEM_BACKUP/unblock__$name.bundle" --all --quiet 2>/dev/null || true

  (cd "$dir" && git filter-repo --mailmap "$mailmap" --quiet) || { rm -rf "$dir"; echo "FILTER_FAIL"; return; }

  local post_total post_bad post_tree
  post_total=$(git -C "$dir" rev-list --all --count)
  post_bad=$(cd "$dir" && count_old_emails)
  post_tree=$(git -C "$dir" rev-parse 'HEAD^{tree}' 2>/dev/null || echo none)

  if [ "$post_bad" -ne 0 ] || [ "$pre_tree" != "$post_tree" ] || [ "$post_total" -gt "$pre_total" ]; then
    rm -rf "$dir"; echo "VALIDATE_FAIL"; return
  fi

  local rc=0 tag_rc=0
  git -C "$dir" push --force --all  "$(repo_url "$slug")" >/dev/null 2>&1 || rc=$?
  git -C "$dir" push --force --tags "$(repo_url "$slug")" >/dev/null 2>&1 || tag_rc=$?
  rm -rf "$dir"
  if [ $rc -ne 0 ]; then echo "PUSH_FAIL"
  elif [ $tag_rc -ne 0 ]; then echo "TAG_PUSH_FAIL"
  else echo "OK"; fi
}
