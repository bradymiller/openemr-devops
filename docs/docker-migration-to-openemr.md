# Docker migration: openemr-devops to openemr core

Living planning doc for the docker-image migration proposed in
[openemr/openemr-devops#790](https://github.com/openemr/openemr-devops/issues/790).
Discussion happens in the issue thread; this file tracks the agreed-upon
shape of the work and gets updated as PRs land.

## Goal

Migrate the production OpenEMR docker images and their build/test pipelines from `openemr/openemr-devops` into `openemr/openemr`, with each production version's Dockerfile living on its corresponding `rel-X.Y.Z` branch and master holding the dev/flex/binary infrastructure. `openemr-cmd` and the Kubernetes manifests stay in this repo.

## Proposed model

Each branch carries the same filenames for its docker pipeline; contents diverge per branch. Master orchestrates the schedule; each rel branch owns its own Dockerfile, build steps, and tests end-to-end.

**openemr/openemr master:**

```
docker/openemr/release/Dockerfile          ← next-version / "dev" production image
docker/openemr/flex/Dockerfile             ← multi-version dev/edge (matrix-driven)
docker/openemr/binary/Dockerfile           ← static-binary helper

tests/bats/flex/                           ← BATS tests for flex
tests/bats/binary/                         ← BATS tests for binary
tests/bats/release/                        ← BATS tests for master's "next" Dockerfile

.github/workflows/build-release.yml        ← single-entry matrix: pushes "dev" + next tags
.github/workflows/build-flex-core.yml      ← reusable workflow holding the actual flex build steps
.github/workflows/build-322.yml            ← thin caller for alpine 3.22 PHP matrix
.github/workflows/build-323.yml            ← thin caller for alpine 3.23 PHP matrix
.github/workflows/build-edge.yml           ← thin caller for alpine edge PHP matrix
.github/workflows/build-binary.yml
.github/workflows/test-release.yml         ← PR validation for release Dockerfile
.github/workflows/test-flex-322.yml        ← PR validation for alpine 3.22 flex
.github/workflows/test-flex-323.yml        ← PR validation for alpine 3.23 flex
.github/workflows/test-flex-edge.yml       ← PR validation for alpine edge flex
.github/workflows/test-binary.yml
.github/workflows/test-bats.yml            ← runs tests/bats/{flex,binary,release}/
.github/workflows/test-production.yml      ← simplified -- no more multi-version glob
.github/workflows/test-core.yml            ← reusable building block
.github/workflows/test-container-functionality.yml
.github/workflows/release-cron.yml         ← schedule + fan-out via workflow_dispatch --ref
```

**openemr/openemr `rel-X.Y.Z`** (each release branch):

```
docker/openemr/release/Dockerfile          ← version-pinned for X.Y.Z
tests/bats/release/                        ← branch-local BATS tests, version prefixes stripped
.github/workflows/build-release.yml        ← single matrix entry with this release's tag list
.github/workflows/test-release.yml
.github/workflows/test-bats.yml            ← runs only tests/bats/release/
.github/workflows/test-production.yml      ← runs against this branch's Dockerfile
```

Per-branch tag examples:
- master → pushes `dev` and whatever-next tags
- `rel-811` → pushes `8.1.1` and `next`
- `rel-810` → pushes `8.1.0`
- `rel-800` → pushes `8.0.0` and `latest`
- `rel-704` → pushes `7.0.4`

No flex / no binary / no orchestrator / no test-core / no test-flex-* on rel branches. They are self-contained for their one production image.

## Validated foundation

The core design assumption -- that `workflow_dispatch --ref <rel-branch>` from a master-side orchestrator runs the rel-branch's workflow definition AND checks out the rel-branch's tree -- was validated in a throwaway fork experiment. Both the dispatched workflow's YAML steps and the runner's checkout came from the target branch, not master. Confirmed `github.ref` == `refs/heads/<target-branch>` in the dispatched run.

This means: when master's `release-cron.yml` dispatches `build-release.yml --ref rel-810`, the resulting run uses rel-810's `build-release.yml` definition (its tag list, its build steps) against rel-810's `docker/openemr/release/Dockerfile`. Per-branch isolation is real.

## Why scheduling has to live on master

GitHub Actions `on: schedule:` triggers only fire from the default branch. A `schedule:` block in a workflow file on `rel-810` will never fire. So the cron tick lives in master's `release-cron.yml`, which fans out via `gh workflow run --ref <branch>` to each active rel branch's `build-release.yml`. Rel-branch workflows have only `push:` / `pull_request:` / `workflow_dispatch:` triggers.

## What moves where (concrete)

| Source (openemr-devops) | Destination |
|---|---|
| `/docker/openemr/flex/` | `openemr` master `docker/openemr/flex/` |
| `/docker/openemr/binary/` | `openemr` master `docker/openemr/binary/` |
| `/docker/openemr/8.1.1/` | `openemr` `rel-811` as `docker/openemr/release/` |
| `/docker/openemr/8.1.0/` | `openemr` `rel-810` as `docker/openemr/release/` |
| `/docker/openemr/8.0.0/` | `openemr` `rel-800` as `docker/openemr/release/` |
| `/docker/openemr/7.0.4/` | `openemr` `rel-704` as `docker/openemr/release/` |
| `/tests/bats/flex/` | `openemr` master |
| `/tests/bats/binary/` | `openemr` master |
| `/tests/bats/8.1.1/` | `openemr` `rel-811` as `tests/bats/release/` |
| `/tests/bats/8.1.0/` | `openemr` `rel-810` as `tests/bats/release/` |
| `/tests/bats/helpers.bash` | Removed (one-line constant inlined in each `.bats` file) |
| `build-flex-core.yml` (reusable) | `openemr` master `build-flex-core.yml` (as-is) |
| `build-322.yml` / `build-323.yml` / `build-edge.yml` | `openemr` master, same filenames (as-is) |
| `build-704/800/810/811.yml` | Per-rel-branch `build-release.yml` (single matrix entry) |
| `test-bats.yml` | Master + each rel branch (filtered to local BATS dirs) |
| `test-production.yml` | Master + each rel branch (simplified, no multi-version glob) |
| `test-flex-322.yml` / `test-flex-323.yml` / `test-flex-edge.yml` | `openemr` master, same filenames (as-is) |
| `test-core.yml` | `openemr` master (reusable) |
| `test-container-functionality.yml` | `openemr` master |
| `build-release-on-tag.yml` + `build-release.yml` (release packaging) | Replaced by in-repo `on: push: tags:` triggers on each rel branch |

## Hard-coded version paths that get wiped

BATS files like `tests/bats/8.1.1/config_files.bats`:

- `@test "8.1.1 Dockerfile: ..."` → `@test "Dockerfile: ..."` (branch context tells you the version)
- `SCRIPT_DIR="$(get_script_dir 8.1.1)"` → direct path constant or removed entirely
- `helpers.bash`'s `get_script_dir` function → removed
- Workflow `paths:` triggers shrink from multi-version lists to just `tests/bats/release/**` and `docker/openemr/release/**` on rel branches

## Dependabot

The current devops dependabot.yml has entries for `/docker/openemr/{7.0.4,8.0.0,8.1.0,binary,flex}` but those entries have generated zero PRs in the past month -- the Dockerfiles use `FROM alpine:${ALPINE_VERSION}` (ARG expansion) which Dependabot's docker ecosystem cannot parse. The kubernetes entries (which use literal `image: alpine:3.23` refs) work fine and generate steady PR flow.

So no Dependabot migration is required for the production Dockerfiles -- the entries are inert. They can be deleted from devops dependabot.yml as housekeeping. Alpine version bumps continue to happen as deliberate edits to the `ARG ALPINE_VERSION=` line on the relevant branch.

## Phased plan

| Phase | Work | Effort |
|---|---|---|
| 1a. Foundation on master | Path layout decisions, Docker Hub credential provisioning (org-level preferred), empty `release-cron.yml` skeleton. | ~1 day |
| 1b. Flex + binary migration | Port both Dockerfiles, their build + test workflows, their BATS dirs. Lift-and-shift the flex workflows (build-flex-core + per-alpine build/test files) as-is -- the per-variant split serves the recently-refactored "add/remove alpine version = file add/delete" model. Update hadolint + docker-compose-lint includes. | ~1 day |
| 1c. Master's release Dockerfile + BATS | Add `docker/openemr/release/`, `build-release.yml` (single-entry matrix for `dev` tag), `test-release.yml`, `tests/bats/release/` skeleton. Wire `release-cron.yml` to self-dispatch master and verify end-to-end. | ~1 day |
| 2. Per rel-branch migration | For each rel-X.Y.Z: cherry-pick Dockerfile + workflows, rename `tests/bats/X.Y.Z/` → `tests/bats/release/`, strip hard-coded version prefixes, smoke-test via workflow_dispatch, then delete the matching `build-XXX.yml` and `tests/bats/X.Y.Z/` from devops. | ~0.5-1 day × N |
| 3. Release tag automation | Replace cross-repo `repository_dispatch openemr-tag` (core → devops) with in-repo `on: push: tags:` triggers on each rel branch's `build-release.yml`. | ~0.5 day |
| 4. Consumer auto-sync | Add an in-repo auto-PR step for digest pins in `docker/development-*` compose files after each push. | ~1 day |
| 5. Devops cleanup | Delete migrated docker paths, BATS dirs, workflows. Remove dead dependabot entries. Add README banner pointing at new locations. Keep `openemr-cmd/`, `kubernetes/`, `tests/bats/openemr-cmd/`, and their workflows. | ~0.5 day |

Total active engineering: **~1.5 weeks** assuming 4 active rel branches. Calendar window will be longer to coordinate with active release activity.

## Branch-cut process under the final model

5 steps when cutting a new `rel-X.Y.Z`:

1. Cut `rel-X.Y.Z` from master
2. Edit the matrix entry in `build-release.yml` to push the new release's tag list
3. Pin `docker/openemr/release/Dockerfile` to X.Y.Z
4. Add the branch name to master's `release-cron.yml` fan-out list
5. On master, re-shape "what next means" in `build-release.yml`

BATS, dependabot, hadolint paths, lint configs -- none change at branch-cut, because their paths are uniform across branches.

## Decisions to lock before phase 1

1. **Docker Hub credential scope.** Org-level secrets are preferred so both repos can push during the cutover. If repo-level only, plan a "freeze devops, flip secrets, enable core" window.
2. **Path naming for the release Dockerfile.** Proposed `docker/openemr/release/`. The existing `docker/openemr/production/docker-compose.yml` in `openemr` would need to either move (e.g., to `docker/production-compose/`) or coexist if we keep separate paths.
3. **Nightly cadence per release branch.** Today devops rebuilds 7.0.4, 8.0.0, 8.1.0, 8.1.1 every night. Worth questioning whether older releases need daily Alpine base-image refreshes -- weekly or only-on-bumps may be enough. Affects the orchestrator fan-out list, not the design.
4. **Binary helper location.** Keep in `openemr` master next to flex, leave in devops, or carve into its own repo? Doesn't affect the model.

## What stays in `openemr-devops`

- `utilities/openemr-cmd/`
- `kubernetes/` manifests
- `tests/bats/openemr-cmd/`
- `.github/workflows/test-bats-openemr-cmd.yml`
- `.github/workflows/test-kubernetes.yml`
- `.github/workflows/dependabot-auto-merge.yml` (and the dependabot.yml entries that drive it for kubernetes)

## Risks and wrinkles to plan for

- **Multi-arch (amd64+arm64).** Current `build-811.yml` does a digest-merge step. The per-rel `build-release.yml` must preserve this -- easy to miss if copied from a single-arch template.
- **Branch protection on rel-X.Y.Z.** Confirm dispatching workflows can write to their own branch's tags / have the right `permissions:` block.
- **Cross-repo docs.** Wiki and third-party guides referencing `openemr-devops/docker/...` paths will need updating. Sunset banner in the devops README should buy 1-2 release cycles of overlap before we delete the old paths.

## Rollback

Reversible at any phase. Each devops `build-XXX.yml` can be restored from git history if a per-branch migration goes wrong. Docker Hub registry names don't change at any point, so consumers (kubernetes manifests, development-* compose files, third-party docs) keep working throughout the transition.

## Feedback wanted

- Thoughts on path naming (item 2 above)?
- Org-level vs repo-level Docker Hub secrets (item 1)?
- Anything missing from the inventory of what moves?
- Anyone want to take a phase?
