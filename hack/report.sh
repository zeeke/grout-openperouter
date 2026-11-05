#!/usr/bin/env bash
# Track grout regressions with a single open issue labeled "grout-regression".
#
# - failure, no open issue  -> open one
# - failure, open issue     -> comment on it (the breakage is still ongoing)
# - success, open issue     -> comment and close it, unless this push is older
#                              than the one that opened it (runs finish out of order)
#
# Env:
#   GH_TOKEN, GITHUB_REPOSITORY, GITHUB_SERVER_URL, GITHUB_RUN_ID
#   RESULT                success | failure
#   GROUT_SHA GROUT_BASE_SHA GROUT_RUN_ID OPENPEROUTER_SHA
#   JOB_RESULTS           human readable "job: result" lines
set -euo pipefail

LABEL=grout-regression
: "${RESULT:?}" "${GROUT_SHA:?}" "${GROUT_RUN_ID:?}" "${GITHUB_REPOSITORY:?}"

run_url="${GITHUB_SERVER_URL}/${GITHUB_REPOSITORY}/actions/runs/${GITHUB_RUN_ID}"
grout_commit="https://github.com/DPDK/grout/commit/${GROUT_SHA}"
if [[ -n "${GROUT_BASE_SHA:-}" ]]; then
  grout_changes="https://github.com/DPDK/grout/compare/${GROUT_BASE_SHA}...${GROUT_SHA}"
else
  grout_changes="$grout_commit"
fi

body=$(cat <<EOF
**Result:** ${RESULT}

| | |
|---|---|
| grout commit | [\`${GROUT_SHA:0:12}\`](${grout_commit}) |
| grout changes in this push | ${grout_changes} |
| grout publish run | https://github.com/DPDK/grout/actions/runs/${GROUT_RUN_ID} |
| openperouter commit | [\`${OPENPEROUTER_SHA:0:12}\`](https://github.com/openperouter/openperouter/commit/${OPENPEROUTER_SHA}) |
| e2e run | ${run_url} |

Jobs:
\`\`\`
${JOB_RESULTS}
\`\`\`
EOF
)

gh label create "$LABEL" -R "$GITHUB_REPOSITORY" --color B60205 \
  --description "openperouter grout lane broken by grout main" 2>/dev/null || true

issue=$(gh issue list -R "$GITHUB_REPOSITORY" -l "$LABEL" -s open -L 1 --json number --jq '.[0].number // empty')

if [[ "$RESULT" == failure ]]; then
  if [[ -n "$issue" ]]; then
    gh issue comment "$issue" -R "$GITHUB_REPOSITORY" --body "Still failing.

${body}"
  else
    # The marker lets a later success tell whether it is newer than this failure.
    gh issue create -R "$GITHUB_REPOSITORY" -l "$LABEL" \
      --title "openperouter grout lanes fail with grout ${GROUT_SHA:0:12}" \
      --body "<!-- first-failing-grout-run: ${GROUT_RUN_ID} -->
openperouter's grout e2e lanes started failing on grout main.

Check whether openperouter main itself is green before blaming grout:
https://github.com/openperouter/openperouter/actions/workflows/ci.yaml?query=branch%3Amain

${body}"
  fi
  exit 0
fi

[[ -z "$issue" ]] && exit 0

first_failing=$(gh issue view "$issue" -R "$GITHUB_REPOSITORY" --json body \
  --jq '.body | capture("first-failing-grout-run: (?<id>[0-9]+)").id // empty')
# Publish run IDs grow with time, so they order grout pushes.
if [[ -n "$first_failing" ]] && (( GROUT_RUN_ID < first_failing )); then
  echo "success on an older grout push than issue #${issue}; leaving it open"
  exit 0
fi
gh issue close "$issue" -R "$GITHUB_REPOSITORY" --comment "Passing again.

${body}"
