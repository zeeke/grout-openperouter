# grout-openperouter

Cross-project CI: runs [openperouter](https://github.com/openperouter/openperouter)'s
grout e2e lanes against every push to [grout](https://github.com/DPDK/grout)'s `main`,
to catch grout regressions that break openperouter.

## How it works

1. **`poll.yml`** runs every 6h (or manually). [`hack/poll.sh`](hack/poll.sh) lists
   grout's `Publish` workflow runs for pushes to `main`. It dispatches one
   `grout-e2e.yml` run for each successful push that hasn't been tested yet.
   - Already tested pushes are recognized by the grout SHA in the e2e run name.
   - Pushes whose grout `Publish` run failed are skipped. Their commits are
     counted in the next tested push's compare link.
   - Only pushes from the last 96h are considered, because grout keeps its
     artifacts for 5 days. At most 3 runs are dispatched per poll.
2. **`grout-e2e.yml`**:
   - checks out the latest openperouter `main`, pinned to one commit per run;
   - downloads `rpm-x86_64-packages` from that grout `Publish` run;
   - runs [`hack/patch-dockerfile.py`](hack/patch-dockerfile.py), which swaps
     the pinned grout release download in `Dockerfile.grout` for the downloaded
     RPMs;
   - builds `router:main-grout` and runs the `grout` (kind) and `qemu-grout`
     lanes. The steps are copied from openperouter's `ci.yaml`.
3. **Reporting** ([`hack/report.sh`](hack/report.sh)) keeps a single open issue
   labeled `grout-regression`:
   - a failure opens the issue, or comments on it if it's already open;
   - the next success comments and closes it.

## Manual run

```sh
# test a specific grout push (the Publish run ID comes from DPDK/grout's Actions tab)
gh workflow run grout-e2e.yml -f grout_run_id=<id> -f grout_sha=<sha>
# preview what the poller would dispatch
gh workflow run poll.yml -f dry_run=true
```

## Maintenance

- If openperouter changes how `Dockerfile.grout` installs grout, the patch
  script fails on purpose. Look for `build-grout-image: failure` in the issue.
- If openperouter's grout lanes in `ci.yaml` change, update `grout-e2e.yml` to
  match.
- If downloading artifacts across repos with `github.token` is refused, add a
  `GROUT_ARTIFACTS_TOKEN` secret: a fine-grained PAT with public repo read access.
