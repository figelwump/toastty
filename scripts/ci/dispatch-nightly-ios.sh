#!/usr/bin/env bash
set -euo pipefail

repository="${GITHUB_REPOSITORY:?GITHUB_REPOSITORY is required}"
branch=feat/task-system-coordinator
if ! git show-ref --verify --quiet "refs/remotes/origin/$branch"; then
  branch="${GITHUB_REF_NAME:?GITHUB_REF_NAME is required}"
fi
head="$(git rev-parse --verify "refs/remotes/origin/$branch^{commit}")"

# Query the exact branch. PR checks and the scheduler itself cannot count as a
# full run. Limit the result to the newest dispatch, including pending runs.
latest="$(gh api --method GET "repos/$repository/actions/workflows/mobile-ios.yml/runs" \
  -f "branch=$branch" -f event=workflow_dispatch -F per_page=1 \
  --jq '.workflow_runs[0] // empty | [.head_sha,.status,.conclusion] | @tsv')"
if [[ -n "$latest" ]]; then
  IFS=$'\t' read -r previous status conclusion <<< "$latest"
  [[ "$previous" =~ ^[0-9a-f]{40}$ && -n "$status" ]] || {
    echo "GitHub returned invalid run metadata." >&2
    exit 1
  }

  if [[ "$status" != completed || "$conclusion" == success ]] &&
    git cat-file -e "$previous^{commit}" 2>/dev/null; then
    # Keep this list aligned with the ios filter in .github/ci-paths.yml.
    # Compare snapshots directly, including deletions and rewritten history.
    if git diff --quiet "$previous" "$head" -- \
      .github/workflows/mobile-ios.yml .github/ci-paths.yml .github/ios-xcode-version \
      .node-version .tool-versions ios Sources/App/Resources/WebPanels \
      Sources/ConversationUI Sources/RemoteProtocol Tests/ConversationUI \
      Tests/RemoteProtocol scripts/ci/select-ios-xcode.sh; then
      printf 'The latest full dispatch already covers the iOS inputs on %s at %s.\n' "$branch" "$head"
      exit 0
    else
      result=$?
      [[ "$result" == 1 ]] || exit "$result"
    fi
  fi
fi

printf 'Dispatching full Toastty CI for %s (observed tip %s).\n' "$branch" "$head"
gh workflow run mobile-ios.yml --repo "$repository" --ref "$branch"
