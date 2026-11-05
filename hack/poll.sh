#!/usr/bin/env bash
# Dispatch one grout-e2e run per grout push to main that has not been tested yet.
#
# A grout push is identified by its "Publish" workflow run on DPDK/grout; that
# run carries the RPM artifacts we test (retained 5 days by grout). Already
# tested pushes are recognized by the run-name of our grout-e2e runs, which
# embeds the grout SHA.
#
# Env:
#   GH_TOKEN            token with actions:write on this repo
#   GITHUB_REPOSITORY   this repo (owner/name)
#   MAX_DISPATCH        max runs dispatched per poll (default 3)
#   MAX_AGE_HOURS       ignore pushes older than this (default 96, artifacts expire at 120)
#   DRY_RUN             if set, only print what would be dispatched
set -euo pipefail

GROUT_REPO=DPDK/grout
E2E_WORKFLOW=grout-e2e.yml
MAX_DISPATCH=${MAX_DISPATCH:-3}
MAX_AGE_HOURS=${MAX_AGE_HOURS:-96}
: "${GITHUB_REPOSITORY:?}"

cutoff=$(date -u -d "-${MAX_AGE_HOURS} hours" +%Y-%m-%dT%H:%M:%SZ)

# Newest first: id, head_sha, status, conclusion, created_at.
# The previous testable (successfully published) push is the base of the
# compare link, so commits from untestable pushes are attributed to this one.
mapfile -t runs < <(gh api "repos/${GROUT_REPO}/actions/workflows/publish.yml/runs?branch=main&event=push&per_page=50" \
  --jq '.workflow_runs[] | [.id, .head_sha, .status, (.conclusion // ""), .created_at] | @tsv')

tested=$(gh run list -R "$GITHUB_REPOSITORY" -w "$E2E_WORKFLOW" -L 500 --json displayTitle --jq '.[].displayTitle')

candidates=()
for i in "${!runs[@]}"; do
  IFS=$'\t' read -r id sha status conclusion created <<<"${runs[$i]}"
  [[ "$created" < "$cutoff" ]] && break
  base=""
  for (( j = i + 1; j < ${#runs[@]}; j++ )); do
    IFS=$'\t' read -r _ prev_sha _ prev_conclusion _ <<<"${runs[$j]}"
    if [[ "$prev_conclusion" == success ]]; then
      base=$prev_sha
      break
    fi
  done
  if [[ "$status" != completed ]]; then
    echo "skip ${sha:0:12}: publish run $id still $status (next poll will pick it up)"
    continue
  fi
  if [[ "$conclusion" != success ]]; then
    # grout's own CI failed; its packages may be missing or broken.
    echo "skip ${sha:0:12}: publish run $id concluded $conclusion"
    continue
  fi
  if grep -qF "$sha" <<<"$tested"; then
    echo "skip ${sha:0:12}: already tested"
    continue
  fi
  candidates+=("$id $sha $base")
done

if (( ${#candidates[@]} == 0 )); then
  echo "nothing to dispatch"
  exit 0
fi

# Oldest first, so results (and issue updates) arrive roughly in push order.
# When more than MAX_DISPATCH are pending, the newest ones win.
dispatched=0
for (( i = ${#candidates[@]} - 1; i >= 0; i-- )); do
  if (( i >= MAX_DISPATCH )); then
    read -r id sha _ <<<"${candidates[$i]}"
    echo "not dispatching ${sha:0:12}: over MAX_DISPATCH=${MAX_DISPATCH}"
    continue
  fi
  read -r id sha base <<<"${candidates[$i]}"
  echo "dispatch ${sha:0:12} (publish run $id, base ${base:0:12})"
  if [[ -z "${DRY_RUN:-}" ]]; then
    gh workflow run "$E2E_WORKFLOW" -R "$GITHUB_REPOSITORY" \
      -f grout_run_id="$id" -f grout_sha="$sha" -f grout_base_sha="$base"
  fi
  dispatched=$((dispatched + 1))
done
echo "dispatched $dispatched run(s)"
