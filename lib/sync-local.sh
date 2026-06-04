#!/usr/bin/env bash
# ─── sync-local.sh — repoint local clones to the rewritten history ───
# After the remote force-push, every local clone still points at pre-rewrite
# commit hashes. Because the rewrite only touched commit metadata, every tree
# and blob is bit-identical — so each old branch tip has exactly one rewritten
# counterpart with the same (tree hash, author timestamp, subject).
#
# For every repo under LOCAL_ROOTS:
#   fetch --prune
#   → for each local branch with an origin counterpart:
#       map old tip → rewritten commit (tree + timestamp + subject)
#       → current branch:  git reset --soft  (worktree and index untouched —
#                          dirty files, staged changes all survive)
#       → other branches:  git branch -f
#
# Branches that were BEHIND origin are mapped to the rewritten equivalent of
# their old position, not yanked forward — your working state is preserved
# exactly. Results: work/sync.tsv

cmd_sync() {
  load_config
  local roots="${LOCAL_ROOTS:-}"
  [ -n "$roots" ] || die "set LOCAL_ROOTS in config.env (space-separated dirs containing your clones)"

  local out="$GEM_WORK/sync.tsv"
  echo -e "repo\tbranch\tstatus\tdetail" > "$out"

  local root repo
  for root in $roots; do
    for repo in "$root"/*; do
      if [ ! -d "$repo/.git" ] || [ -L "$repo" ]; then continue; fi
      sync_repo "$repo" "$out"
    done
  done

  echo
  column -t -s$'\t' "$out"
  log "done — branches REPOINTed/RESET now match the rewritten remote"
}

sync_repo() {
  local repo=$1 out=$2
  local name
  name=$(basename "$repo")
  cd "$repo" || return

  git fetch origin --prune --quiet 2>/dev/null \
    || { echo -e "$name\t-\tFETCH_FAIL\tno origin or no network" >> "$out"; return; }

  local cur br old new
  cur=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")

  for br in $(git for-each-ref refs/heads --format='%(refname:short)'); do
    git rev-parse --verify --quiet "refs/remotes/origin/$br" >/dev/null \
      || { echo -e "$name\t$br\tNO_UPSTREAM\tlocal-only branch, left as-is" >> "$out"; continue; }

    old=$(git rev-parse "refs/heads/$br")

    # Already on rewritten history?
    if git merge-base --is-ancestor "$old" "origin/$br" 2>/dev/null; then
      echo -e "$name\t$br\tALREADY_OK\t-" >> "$out"; continue
    fi

    new=$(map_commit "origin/$br" "$old")
    if [ -z "$new" ]; then
      echo -e "$name\t$br\tNO_MATCH\tunpushed commits? rebase manually onto origin/$br" >> "$out"; continue
    fi

    if [ "$br" = "$cur" ]; then
      git reset --soft "$new"
      echo -e "$name\t$br\tRESET\t${old:0:8}→${new:0:8}" >> "$out"
    else
      git branch -f "$br" "$new"
      echo -e "$name\t$br\tREPOINT\t${old:0:8}→${new:0:8}" >> "$out"
    fi
  done
}

# Find the rewritten counterpart of $2 in the history of $1.
# Match on tree hash + author timestamp, then confirm the subject line —
# subjects are compared out-of-band because they can contain any character
# that would break field splitting.
map_commit() {
  local ref=$1 old=$2 tree ts subj cand
  tree=$(git rev-parse "$old^{tree}")
  ts=$(git log -1 --format='%at' "$old")
  subj=$(git log -1 --format='%s' "$old")
  for cand in $(git log "$ref" --format='%H %T %at' \
                | awk -v t="$tree" -v s="$ts" '$2==t && $3==s {print $1}'); do
    [ "$(git show -s --format='%s' "$cand")" = "$subj" ] && { echo "$cand"; return; }
  done
}
