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

.github/workflows/docker-build-release.yml        ← byte-identical across all branches; reads tags from input set by master's orchestrator
.github/workflows/docker-build-flex-core.yml      ← reusable workflow holding the actual flex build steps
.github/workflows/docker-build-322.yml            ← thin caller for alpine 3.22 PHP matrix
.github/workflows/docker-build-323.yml            ← thin caller for alpine 3.23 PHP matrix
.github/workflows/docker-build-edge.yml           ← thin caller for alpine edge PHP matrix
.github/workflows/docker-build-binary.yml
.github/workflows/docker-test-release.yml         ← PR validation for release Dockerfile (renamed from devops's test-production.yml; no more multi-version glob)
.github/workflows/docker-test-flex-322.yml        ← PR validation for alpine 3.22 flex
.github/workflows/docker-test-flex-323.yml        ← PR validation for alpine 3.23 flex
.github/workflows/docker-test-flex-edge.yml       ← PR validation for alpine edge flex
.github/workflows/docker-test-binary.yml
.github/workflows/docker-test-bats.yml            ← runs tests/bats/{flex,binary,release}/
.github/workflows/docker-test-core.yml            ← reusable building block
.github/workflows/docker-test-container-functionality.yml
.github/workflows/docker-release-cron.yml         ← schedule + fan-out via workflow_dispatch --ref
```

**openemr/openemr `rel-X.Y.Z`** (each release branch):

```
docker/openemr/release/Dockerfile          ← version-pinned for X.Y.Z
tests/bats/release/                        ← branch-local BATS tests, version prefixes stripped
.github/workflows/docker-build-release.yml        ← byte-identical to master's; tags come from orchestrator input
.github/workflows/docker-test-release.yml         ← runs against this branch's Dockerfile
.github/workflows/docker-test-bats.yml            ← runs only tests/bats/release/
```

No flex / no binary / no orchestrator / no test-core / no test-flex-* on rel branches. They are self-contained for their one production image.

Per-branch tag mapping (defined in master's orchestrator, not the rel branches):
- master → `dev`
- `rel-811` → `8.1.1`, `next`
- `rel-810` → `8.1.0`
- `rel-800` → `8.0.0`, `latest`
- `rel-704` → `7.0.4`

## Validated foundation

The core design assumption -- that `workflow_dispatch --ref <rel-branch>` from a master-side orchestrator runs the rel-branch's workflow definition AND checks out the rel-branch's tree -- was validated in a throwaway fork experiment. Both the dispatched workflow's YAML steps and the runner's checkout came from the target branch, not master. Confirmed `github.ref` == `refs/heads/<target-branch>` in the dispatched run.

This means: when master's `docker-release-cron.yml` dispatches `docker-build-release.yml --ref rel-810`, the resulting run uses rel-810's `docker-build-release.yml` definition (its tag list, its build steps) against rel-810's `docker/openemr/release/Dockerfile`. Per-branch isolation is real.

## Master orchestrates schedule AND tag assignment

`docker-release-cron.yml` on master does two jobs: it owns the cron tick (since GitHub Actions `schedule:` only fires from the default branch), and it owns the source of truth for which docker tags each branch should push. The orchestrator passes the tag list to each dispatched build as a `workflow_dispatch` input. Consequences:

- `docker-build-release.yml` is **byte-identical** across master and every rel branch. The only per-branch differences are the Dockerfile contents and the BATS tests.
- Tag promotion (rotating `latest`, bumping `next`) is a one-line edit on master -- no PR against the affected rel branch.
- Branch-cut doesn't require editing the new rel branch's workflow file at all; just add a fan-out entry on master with the new branch's tag list.

### Orchestrator skeleton (master)

A single inline matrix is the source of truth for which branches build and which logical tags each pushes. Adding a rel branch is a one-row diff; rotating `latest` is a one-line diff.

```yaml
# .github/workflows/docker-release-cron.yml
on:
  schedule:
  - cron: '0 6 * * *'
  workflow_dispatch:
    inputs:
      include:
        description: 'Branches to build (comma-separated, or "all"). Examples: "all", "rel-810", "rel-810,master"'
        type: string
        default: 'all'
      exclude:
        description: 'Branches to skip (comma-separated). Useful with include=all.'
        type: string
        default: ''

permissions:
  actions: write
  contents: read

jobs:
  fan-out:
    runs-on: ubuntu-24.04
    strategy:
      fail-fast: false
      matrix:
        include:
        - branch: master
          tags: 'dev'
        - branch: rel-811
          tags: '8.1.1,next'
        - branch: rel-810
          tags: '8.1.0'
        - branch: rel-800
          tags: '8.0.0,latest'
        - branch: rel-704
          tags: '7.0.4'
    steps:
    - name: Dispatch ${{ matrix.branch }} with tags ${{ matrix.tags }}
      if: >-
        ${{
          (github.event_name == 'schedule'
            || inputs.include == 'all'
            || contains(format(',{0},', inputs.include), format(',{0},', matrix.branch)))
          && !contains(format(',{0},', inputs.exclude), format(',{0},', matrix.branch))
        }}
      env:
        GH_TOKEN: ${{ github.token }}
      run: |
        gh workflow run docker-build-release.yml \
          --repo ${{ github.repository }} \
          --ref ${{ matrix.branch }} \
          -f tags="${{ matrix.tags }}"
        echo "Dispatched ${{ matrix.branch }} with tags=${{ matrix.tags }}"
```

The `format(',{0},', x)` wrapping in `contains()` is exact-match (prevents `rel-810` from substring-matching `rel-8100`). Cron runs (`github.event_name == 'schedule'`) bypass both `include` and `exclude` filters and run every matrix entry. Manual dispatch takes a text input -- type `all` (the default) for everything, or list specific branches like `rel-810,master`. The matrix-only design has no per-branch input cap, so it scales beyond GitHub's 10-input limit if releases ever accumulate.

The orchestrator carries **logical** tags only (`8.1.0,next`); docker-build-release.yml is responsible for expanding version-number tags into dated siblings -- see below.

### docker-build-release.yml (byte-identical across all branches)

```yaml
# .github/workflows/docker-build-release.yml -- identical on master and every rel-X.Y.Z
on:
  workflow_dispatch:
    inputs:
      tags:
        description: 'Comma-separated tags to push (e.g. "8.1.0,latest"; leave default for an ad-hoc test build)'
        required: true
        type: string
        default: 'manual-test'
  push:
    tags: ['v*']    # real release tagging; tag value drives docker tag

jobs:
  build:
    runs-on: ubuntu-24.04
    steps:
    - uses: actions/checkout@v5

    - name: Compute build date
      id: build_date
      run: echo "date=$(date +'%Y-%m-%d')" >> "$GITHUB_OUTPUT"

    - name: Expand tag list (add dated variant for version-number tags)
      id: tags
      env:
        INPUT_TAGS: ${{ inputs.tags }}
        BUILD_DATE: ${{ steps.build_date.outputs.date }}
      run: |
        {
          echo 'tags<<EOF'
          IFS=',' read -ra TAGS <<< "$INPUT_TAGS"
          for t in "${TAGS[@]}"; do
            t="${t// /}"   # strip whitespace
            [ -z "$t" ] && continue
            echo "openemr/openemr:${t}"
            # Rule: version-number tags (digits and dots only) also get a dated sibling.
            # "8.1.0" -> push "8.1.0" + "8.1.0-2026-06-12"
            # "next" / "dev" / "latest" / "manual-test" -> no dated variant.
            if [[ "$t" =~ ^[0-9]+(\.[0-9]+)+$ ]]; then
              echo "openemr/openemr:${t}-${BUILD_DATE}"
            fi
          done
          echo EOF
        } >> "$GITHUB_OUTPUT"

    - name: Build and push
      uses: docker/build-push-action@v6
      with:
        context: ./docker/openemr/release
        push: true
        tags: ${{ steps.tags.outputs.tags }}
```

When the orchestrator dispatches `-f tags="8.1.0,latest"`, the build pushes `openemr/openemr:8.1.0`, `openemr/openemr:8.1.0-2026-06-12`, and `openemr/openemr:latest` -- the version-number `8.1.0` gets a dated sibling, the floating `latest` doesn't. When a maintainer manually dispatches for testing, the form pre-fills `manual-test` -- safe sentinel that never clobbers production tags, never gets a dated variant.

The dated-tag rule matches the current devops convention (`date +'%Y-%m-%d'` from build-openemr.yml's tag-merge step) and lives in docker-build-release.yml so the orchestrator stays purely declarative -- the matrix carries only logical tags.

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
| `build-flex-core.yml` (reusable) | `openemr` master `docker-build-flex-core.yml` (prefixed during move) |
| `build-322.yml` / `build-323.yml` / `build-edge.yml` | `openemr` master, prefixed to `docker-build-322.yml` / `docker-build-323.yml` / `docker-build-edge.yml` |
| `build-704/800/810/811.yml` | Per-rel-branch `docker-build-release.yml` (orchestrator-driven, single-row matrix entry on master) |
| `test-bats.yml` | Master + each rel branch as `docker-test-bats.yml` (filtered to local BATS dirs) |
| `test-production.yml` | Master + each rel branch as `docker-test-release.yml` (simplified, no multi-version glob) |
| `test-flex-322.yml` / `test-flex-323.yml` / `test-flex-edge.yml` | `openemr` master, prefixed to `docker-test-flex-322.yml` etc. |
| `test-core.yml` | `openemr` master as `docker-test-core.yml` (reusable) |
| `test-container-functionality.yml` | `openemr` master as `docker-test-container-functionality.yml` |
| `build-release-on-tag.yml` + `build-release.yml` (release packaging / tarballs in devops) | Replaced by in-repo `on: push: tags:` triggers on each rel branch's `docker-build-release.yml`. Devops's `build-release.yml` (packaging) is distinct from the docker workflow and needs migrating under a non-colliding name (e.g. `package-release.yml`). |
| `hadolint.yml` (existing in openemr core, not devops) | Rename to `docker-lint-hadolint.yml`. Update self-references at line 11+19 inside the file + the `[![Dockerfile Linting](.../hadolint.yml/badge.svg)]` badge URL in README.md. Check name (`Dockerfile Linting`) is unaffected since it's set via `name:`. |

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
| 1a. Foundation on master | Path layout decisions, Docker Hub credential provisioning (org-level preferred), empty `docker-release-cron.yml` skeleton. | ~1 day |
| 1b. Flex + binary migration | Port both Dockerfiles, their build + test workflows, their BATS dirs. Prefix all moved workflow filenames with `docker-` (see "what moves where"). The flex workflows are lift-and-shift modulo the prefix -- the per-variant split serves the recently-refactored "add/remove alpine version = file add/delete" model. Also: rename existing `hadolint.yml` → `docker-lint-hadolint.yml` (fixes the 2 self-references inside it + the README badge URL); update `docker-compose-lint.yml` and renamed-hadolint includes to cover new Dockerfile paths. | ~1 day |
| 1c. Master's release Dockerfile + orchestrator | Add `docker/openemr/release/`, `docker-build-release.yml` (reads tags from input), `docker-test-release.yml`, `tests/bats/release/` skeleton. Build `docker-release-cron.yml` with the matrix-driven fan-out + include/exclude inputs. Wire master's own self-dispatch and verify end-to-end. | ~1 day |
| 2. Per rel-branch migration | For each rel-X.Y.Z: cherry-pick Dockerfile + the byte-identical `docker-build-release.yml` + `docker-test-release.yml` + `docker-test-bats.yml`, rename `tests/bats/X.Y.Z/` → `tests/bats/release/`, strip hard-coded version prefixes, smoke-test via workflow_dispatch, add the new branch to master's orchestrator, then delete the matching `build-XXX.yml` and `tests/bats/X.Y.Z/` from devops. | ~0.5-1 day × N |
| 3. Release tag automation | Replace cross-repo `repository_dispatch openemr-tag` (core → devops) with the in-repo `on: push: tags:` trigger already present on each rel branch's `docker-build-release.yml`. Sort out the existing devops `build-release.yml` (release packaging / tarballs) -- distinct from the docker build workflow; needs migration to core under a non-colliding name like `package-release.yml`. | ~1 day |
| 4. Consumer auto-sync | Add an in-repo auto-PR step for digest pins in `docker/development-*` compose files after each push. | ~1 day |
| 5. Devops cleanup | Delete migrated docker paths, BATS dirs, workflows. Remove dead dependabot entries. Add README banner pointing at new locations. Keep `openemr-cmd/`, `kubernetes/`, `tests/bats/openemr-cmd/`, and their workflows. | ~0.5 day |

Total active engineering: **~1.5 weeks** assuming 4 active rel branches. Calendar window will be longer to coordinate with active release activity.

## Branch-cut process under the final model

3 steps when cutting a new `rel-X.Y.Z`:

1. Cut `rel-X.Y.Z` from master
2. Pin `docker/openemr/release/Dockerfile` to X.Y.Z on the new branch
3. Add a fan-out entry on master's `docker-release-cron.yml` with the new branch's tag list (and a `run_rel_XYZ` boolean input)

`docker-build-release.yml`, `docker-test-release.yml`, `docker-test-bats.yml`, BATS contents, dependabot, hadolint paths, lint configs -- none change at branch-cut, because `docker-build-release.yml` is identical across branches and the paths are uniform.

When it's time to rotate `latest` (e.g., 8.1.0 graduates to GA): a two-line edit in master's orchestrator. No PR against either rel branch.

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

- **Multi-arch (amd64+arm64).** Current `build-811.yml` does a digest-merge step. The per-rel `docker-build-release.yml` must preserve this -- easy to miss if copied from a single-arch template.
- **Branch protection on rel-X.Y.Z.** Confirm dispatching workflows can write to their own branch's tags / have the right `permissions:` block.
- **Cross-repo docs.** Wiki and third-party guides referencing `openemr-devops/docker/...` paths will need updating. Sunset banner in the devops README should buy 1-2 release cycles of overlap before we delete the old paths.

## Rollback

Reversible at any phase. Each devops `build-XXX.yml` can be restored from git history if a per-branch migration goes wrong. Docker Hub registry names don't change at any point, so consumers (kubernetes manifests, development-* compose files, third-party docs) keep working throughout the transition.

## Feedback wanted

- Thoughts on path naming (item 2 above)?
- Org-level vs repo-level Docker Hub secrets (item 1)?
- Anything missing from the inventory of what moves?
