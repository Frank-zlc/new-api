# Upstream Sync Workflow

This fork carries local patches on the `company` branch. Use this workflow to
keep `company` rebased on top of the latest upstream code without losing the
patches.

## One-time setup

```bash
# Add upstream (only once)
git remote add upstream https://github.com/QuantumNous/new-api.git
git fetch upstream

# Make local main track upstream (so it always mirrors upstream/main)
git checkout main
git branch --set-upstream-to=upstream/main main

# Verify
git remote -v
# origin    https://github.com/<you>/new-api.git (fetch/push)
# upstream  https://github.com/QuantumNous/new-api.git (fetch/push)
```

## Branch model

```
upstream/main ──● ──● ──●         (official, read-only for us)
                       │
local main    ────────● fast-forward
                       │
company       ────────●─[patch1]─[patch2]─[patch3]
                                                  ▲
                                                  └─ HEAD, deployed
```

- `main` — **never commit here**, only `git pull` from upstream
- `company` — deployed branch, holds all local patches on top of `main`
- `fix/*` — short-lived branches for new patches, merged/rebased into `company`

## Daily: making a new patch

```bash
git checkout main
git pull --ff-only        # safety: only fast-forward
git checkout -b fix/short-description

# ... edit code ...
git commit -m "fix(scope): one-line summary

Body explains the why. Reference issue/screenshot if any.

Patch-ID: <stable-tag>   # used by sync script to detect overlap
"

# Merge into company
git checkout company
git rebase main           # bring company up-to-date first
git merge --ff-only fix/short-description   # or cherry-pick
git branch -d fix/short-description
```

## Sync: pulling new upstream code

```bash
# Quick check — only reports, no mutation
scripts/sync-upstream.sh --check

# Real sync (interactive)
scripts/sync-upstream.sh
```

### What the script does

1. **Preflight** — verifies clean working tree, correct branch, `upstream` remote
2. **Snapshot** — tags current `company` HEAD as `pre-sync/<timestamp>` (rollback anchor)
3. **Fetch** — pulls `upstream/main`, lists new commits
4. **Overlap scan** — greps upstream commits for keywords matching our patches.
   If hits, warns: upstream may have fixed the bug; review before rebasing.
5. **Fast-forward** — `main` → `upstream/main` (refuses if `main` has diverged)
6. **Rebase** — `company` onto new `main`
7. **Reports** — success, conflict, or upstream-fix detected

### Possible outcomes

| Outcome | What the script does | What you do |
|---|---|---|
| ✅ Clean rebase | Tells you new HEAD + push command | Build, test, push with `--force-with-lease` |
| ⚠️ Upstream keyword hit | Stops and asks for confirmation | Review the upstream commit; decide to skip patch or rebase anyway |
| 🔴 Conflict | Stops in rebase, prints conflicted files + 3 options | Resolve manually OR abort OR skip (if upstream fixed it) |
| 💤 Nothing new | Exits with "up-to-date" | Nothing — you are current |

### Recovery

The script always tags the previous `company` HEAD before mutating anything. To
undo a sync:

```bash
git checkout company
git reset --hard pre-sync/<timestamp>     # tag printed by the script
# (don't force-push origin/company until you've verified)
```

## When upstream fixes one of your patches

The script will detect overlap via `PATCH_KEYWORDS` and warn you. Once
confirmed, drop the obsolete patch:

```bash
# During rebase, when the obsolete commit conflicts:
git rebase --skip                  # drops just this commit

# Or before syncing, edit company history to remove the patch cleanly:
git checkout company
git rebase -i main                 # mark the commit as 'drop'
```

Then update `scripts/sync-upstream.sh` to remove the keyword from
`PATCH_KEYWORDS` so future syncs don't trip on the same notice.

## Adding new patch keywords

Each long-lived patch should add a regex line to `PATCH_KEYWORDS` in
`scripts/sync-upstream.sh`. The keyword should match function names, file paths,
or distinctive identifiers your patch touches. Example:

```bash
PATCH_KEYWORDS=(
  "openrouter.*usage"                  # matches "fix(openrouter): usage ..."
  "cache_creation_input_tokens"        # matches anyone fixing this field
  "buildClaudeUsageFromOpenAIUsage"    # matches anyone refactoring this func
)
```

## Push policy

The script intentionally **does not push**. After every sync:

```bash
go build ./... && go test ./...
git push --force-with-lease origin company   # not --force
```

`--force-with-lease` refuses to overwrite remote commits you haven't seen,
which protects you against accidentally clobbering someone else's push.
