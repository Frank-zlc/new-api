#!/usr/bin/env bash
#
# sync-upstream.sh — Sync fork with upstream and re-apply company patches.
#
# Usage:
#   scripts/sync-upstream.sh            # interactive, normal sync
#   scripts/sync-upstream.sh --dry-run  # show what would happen, do nothing
#   scripts/sync-upstream.sh --check    # only check if upstream has new commits
#
# What it does:
#   1. Verifies preconditions (clean tree, on company branch, upstream remote exists)
#   2. Tags current company HEAD as pre-sync/<timestamp> (safety net)
#   3. Fetches upstream, fast-forwards main to upstream/main
#   4. Rebases company onto new main
#   5. On conflict: stops in rebase, prints actionable next-step commands
#   6. On success: scans upstream commits for keywords matching our patches
#      and warns if upstream may have fixed the same bug (manual review required)
#   7. Never pushes — you decide when to push.
#
# Exit codes:
#   0  Success (or no-op when no upstream changes)
#   1  Precondition failed (dirty tree, wrong branch, missing remote, ...)
#   2  Conflict during rebase — manual intervention required
#   3  User aborted

set -euo pipefail

# ─── config ──────────────────────────────────────────────────────────────────
COMPANY_BRANCH="${COMPANY_BRANCH:-company}"
MAIN_BRANCH="${MAIN_BRANCH:-main}"
UPSTREAM_REMOTE="${UPSTREAM_REMOTE:-upstream}"
UPSTREAM_URL="${UPSTREAM_URL:-https://github.com/QuantumNous/new-api.git}"

# Keywords used to grep upstream commits for potential overlap with our patches.
# Extend this when adding new patches. One keyword per line.
PATCH_KEYWORDS=(
  "openrouter.*usage"
  "openrouter.*cache"
  "cache_creation_input_tokens"
  "buildClaudeUsageFromOpenAIUsage"
  "ResponseOpenAI2Claude.*usage"
)

# ─── helpers ─────────────────────────────────────────────────────────────────
c_reset=$'\033[0m'
c_red=$'\033[31m'
c_green=$'\033[32m'
c_yellow=$'\033[33m'
c_blue=$'\033[34m'
c_bold=$'\033[1m'

info()  { printf "%s==>%s %s\n"        "$c_blue"   "$c_reset" "$*"; }
ok()    { printf "%s✓%s %s\n"          "$c_green"  "$c_reset" "$*"; }
warn()  { printf "%s⚠ %s%s\n"          "$c_yellow" "$*"       "$c_reset"; }
err()   { printf "%s✗ %s%s\n" >&2      "$c_red"    "$*"       "$c_reset"; }
hdr()   { printf "\n%s%s── %s ──%s\n"  "$c_bold"   "$c_blue"  "$*" "$c_reset"; }

die()   { err "$@"; exit 1; }

DRY_RUN=0
CHECK_ONLY=0
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=1 ;;
    --check)   CHECK_ONLY=1 ;;
    -h|--help)
      sed -n '2,/^set -euo/p' "$0" | sed 's/^# \{0,1\}//' | sed '$d'
      exit 0
      ;;
    *) die "Unknown argument: $arg (use --help)" ;;
  esac
done

run() {
  if [[ $DRY_RUN -eq 1 ]]; then
    printf "  %s[dry-run]%s %s\n" "$c_yellow" "$c_reset" "$*"
  else
    eval "$@"
  fi
}

# ─── 1. preflight ────────────────────────────────────────────────────────────
hdr "Preflight checks"

# Run from repo root regardless of cwd
repo_root="$(git rev-parse --show-toplevel 2>/dev/null)" || die "Not in a git repository."
cd "$repo_root"
ok "Repository: $repo_root"

# Working tree must be clean
if ! git diff --quiet || ! git diff --cached --quiet; then
  err "Working tree is not clean."
  git status --short
  die "Commit or stash changes before syncing."
fi
if [[ -n "$(git ls-files --others --exclude-standard)" ]]; then
  warn "Untracked files present (will not be touched, but listed for awareness):"
  git ls-files --others --exclude-standard | sed 's/^/    /'
fi
ok "Working tree is clean."

# Must be on company branch
current_branch="$(git symbolic-ref --short HEAD 2>/dev/null || echo '<detached>')"
if [[ "$current_branch" != "$COMPANY_BRANCH" ]]; then
  warn "Current branch is '$current_branch', expected '$COMPANY_BRANCH'."
  read -r -p "Switch to '$COMPANY_BRANCH' and continue? [y/N] " ans
  [[ "$ans" =~ ^[Yy]$ ]] || die "Aborted by user."
  run "git checkout '$COMPANY_BRANCH'"
fi
ok "On branch: $COMPANY_BRANCH"

# Upstream remote must exist
if ! git remote get-url "$UPSTREAM_REMOTE" >/dev/null 2>&1; then
  warn "Remote '$UPSTREAM_REMOTE' is not configured."
  read -r -p "Add it now as $UPSTREAM_URL ? [y/N] " ans
  [[ "$ans" =~ ^[Yy]$ ]] || die "Aborted — add remote manually and retry."
  run "git remote add '$UPSTREAM_REMOTE' '$UPSTREAM_URL'"
fi
upstream_url="$(git remote get-url "$UPSTREAM_REMOTE")"
ok "Upstream: $UPSTREAM_REMOTE → $upstream_url"

# main branch must exist locally
if ! git rev-parse --verify --quiet "$MAIN_BRANCH" >/dev/null; then
  die "Local '$MAIN_BRANCH' branch does not exist."
fi

# ─── 2. fetch upstream & compare ─────────────────────────────────────────────
hdr "Fetching upstream"
run "git fetch '$UPSTREAM_REMOTE' --tags --prune"
ok "Fetched $UPSTREAM_REMOTE."

main_local="$(git rev-parse "$MAIN_BRANCH")"
main_upstream="$(git rev-parse "$UPSTREAM_REMOTE/$MAIN_BRANCH")"

if [[ "$main_local" == "$main_upstream" ]]; then
  ok "Already up-to-date with $UPSTREAM_REMOTE/$MAIN_BRANCH ($(git rev-parse --short HEAD))."
  if [[ $CHECK_ONLY -eq 1 ]]; then exit 0; fi
  # Still rebase company in case it lagged behind main
  company_base="$(git merge-base "$COMPANY_BRANCH" "$MAIN_BRANCH")"
  if [[ "$company_base" == "$(git rev-parse "$MAIN_BRANCH")" ]]; then
    ok "Company is already on top of main. Nothing to do."
    exit 0
  fi
fi

new_commits_count="$(git rev-list --count "$main_local..$main_upstream")"
info "$UPSTREAM_REMOTE/$MAIN_BRANCH has ${c_bold}$new_commits_count${c_reset} new commits:"
git --no-pager log --oneline --no-decorate "$main_local..$main_upstream" | head -20 | sed 's/^/    /'
if (( new_commits_count > 20 )); then
  printf "    ... (%d more)\n" "$((new_commits_count - 20))"
fi

# ─── 3. scan upstream for potential overlap with our patches ─────────────────
hdr "Scanning upstream commits for patch overlap"
overlap_hits=""
for kw in "${PATCH_KEYWORDS[@]}"; do
  hits=$(git --no-pager log --oneline -i --grep="$kw" "$main_local..$main_upstream" || true)
  if [[ -n "$hits" ]]; then
    overlap_hits+=$'\n'"  keyword: $kw"$'\n'"$hits"$'\n'
  fi
done

if [[ -n "$overlap_hits" ]]; then
  warn "Upstream may have touched code our patches modify:"
  printf "%s\n" "$overlap_hits" | sed 's/^/    /'
  warn "Review whether our patches are still needed before re-applying."
  if [[ $CHECK_ONLY -eq 0 ]]; then
    read -r -p "Continue with sync anyway? [y/N] " ans
    [[ "$ans" =~ ^[Yy]$ ]] || exit 3
  fi
else
  ok "No upstream commits match patch keywords. Likely safe to rebase."
fi

if [[ $CHECK_ONLY -eq 1 ]]; then
  info "(--check) Stopping before any mutation."
  exit 0
fi

# ─── 4. safety tag ───────────────────────────────────────────────────────────
hdr "Creating safety tag"
ts="$(date +%Y%m%d-%H%M%S)"
safety_tag="pre-sync/$ts"
run "git tag -a '$safety_tag' '$COMPANY_BRANCH' -m 'Safety snapshot before upstream sync'"
ok "Tagged $safety_tag at $(git rev-parse --short "$COMPANY_BRANCH")"
info "To roll back at any point: ${c_bold}git checkout $COMPANY_BRANCH && git reset --hard $safety_tag${c_reset}"

# ─── 5. fast-forward main ────────────────────────────────────────────────────
hdr "Fast-forwarding $MAIN_BRANCH"
run "git checkout '$MAIN_BRANCH'"
if ! run "git merge --ff-only '$UPSTREAM_REMOTE/$MAIN_BRANCH'"; then
  err "Fast-forward failed. Your local '$MAIN_BRANCH' has diverged from upstream."
  err "This should not happen if you never commit to '$MAIN_BRANCH' directly."
  err "Investigate with: git log --oneline $UPSTREAM_REMOTE/$MAIN_BRANCH..$MAIN_BRANCH"
  exit 1
fi
ok "$MAIN_BRANCH is now at $(git rev-parse --short HEAD)."

# ─── 6. rebase company onto new main ─────────────────────────────────────────
hdr "Rebasing $COMPANY_BRANCH onto $MAIN_BRANCH"
run "git checkout '$COMPANY_BRANCH'"

if [[ $DRY_RUN -eq 1 ]]; then
  info "[dry-run] Would now run: git rebase $MAIN_BRANCH"
  info "[dry-run] Stopping before mutation."
  exit 0
fi

if git rebase "$MAIN_BRANCH"; then
  ok "Rebase succeeded. $COMPANY_BRANCH is now on top of $MAIN_BRANCH."
  new_head="$(git rev-parse --short HEAD)"
  info "Old company HEAD: $(git rev-parse --short "$safety_tag")"
  info "New company HEAD: $new_head"
  hdr "Next steps"
  echo "  1. Review the rebased history:  git log --oneline $MAIN_BRANCH..HEAD"
  echo "  2. Build & run tests:           go build ./... && go test ./..."
  echo "  3. If everything looks good, push (use --force-with-lease, not --force):"
  echo "       git push --force-with-lease origin $COMPANY_BRANCH"
  echo "  4. If you need to roll back:    git reset --hard $safety_tag"
  exit 0
fi

# ─── 7. conflict handler ─────────────────────────────────────────────────────
hdr "${c_red}REBASE CONFLICT${c_reset}"
err "Rebase stopped due to conflicts. Repository is in 'REBASING' state."
echo
warn "Conflicted files:"
git --no-pager diff --name-only --diff-filter=U | sed 's/^/    /'
echo
warn "Commit currently being applied:"
git --no-pager log -1 --pretty=format:"    %h %s%n    Author: %an%n    Body:%n%b" REBASE_HEAD 2>/dev/null || true
echo

hdr "How to proceed"
cat <<EOF
  ${c_bold}Option A — resolve and continue:${c_reset}
    1. Edit each conflicted file, choose the right version
    2. git add <file> ...
    3. git rebase --continue
    4. Repeat if more conflicts surface
    5. When done, push:  git push --force-with-lease origin $COMPANY_BRANCH

  ${c_bold}Option B — abort and stay on old company:${c_reset}
    git rebase --abort
    (nothing pushed yet, you are unchanged from before this script ran)

  ${c_bold}Option C — upstream already fixed this bug, drop our patch:${c_reset}
    1. git rebase --skip            # drops the current conflicting commit
    2. Continue with remaining commits if any
    3. Verify the bug fix is indeed in upstream before pushing

  ${c_bold}Safety net:${c_reset} your old company tip is tagged as ${c_bold}$safety_tag${c_reset}
    Roll back any time with: git checkout $COMPANY_BRANCH && git reset --hard $safety_tag
EOF
exit 2
