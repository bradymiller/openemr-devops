# BATS: cmd_worktree_add when the branch (not the primary) is missing
# pieces of the docker/ layout.
#
# cmd_worktree_add does an early sanity check on the PRIMARY repo's
# compose subdir (line ~696), but the actual write happens against the
# WORKTREE'S checkout. A branch can predate one of the env variants
# (no docker/development-easy-light/) or be missing docker/library
# entirely. Each case has a distinct contract:
#
#   - docker/library missing: wt_write_override resolves it via realpath
#     and dies with "Missing directory: '<dir>/docker/library'"
#     (existing guard, pinned here as a regression check too).
#   - docker/development-<env>/ missing on the branch: cmd_worktree_add
#     calls `mkdir -p` at line ~740, which CREATES the subdir. Then it
#     writes .env + override into it. The resulting worktree has a
#     synthesized compose dir with no docker-compose.yml. The error
#     surfaces later, at `worktree up`, when docker compose tries to
#     load the missing -f. This file pins that two-stage behavior so a
#     future refactor that moves the error earlier is intentional.

load '../test_helper/bats-support/load'
load '../test_helper/bats-assert/load'
load 'helpers'

setup() {
    SCRIPT="$(oc_script_path)"
    [[ -x "$SCRIPT" ]] || skip "openemr-cmd script not found"
    TMP_PARENT=$(oc_mktempdir)
    TMP_ROOT="${TMP_PARENT}/primary"
    mkdir -p "${TMP_ROOT}"
    oc_init_repo_with_fixtures "${TMP_ROOT}"
    STUB_DIR=$(oc_make_docker_stub_dir)
    STATE_FILE="${TMP_ROOT}/.worktrees.json"
    export TMP_PARENT TMP_ROOT STUB_DIR STATE_FILE
}

teardown() {
    [[ -n "${TMP_PARENT:-}" ]] && rm -rf "${TMP_PARENT}"
    [[ -n "${STUB_DIR:-}" ]] && rm -rf "${STUB_DIR}"
    return 0
}

# Make a branch that mutates the checkout (delete a subdir) and commits.
make_branch_without() {
    local branch=$1 path_to_remove=$2
    git -C "${TMP_ROOT}" checkout --quiet -b "${branch}" master
    git -C "${TMP_ROOT}" rm -rq "${path_to_remove}"
    git -C "${TMP_ROOT}" -c user.email=bats@e.com -c user.name=bats \
        -c commit.gpgsign=false \
        commit --quiet -m "drop ${path_to_remove}"
    git -C "${TMP_ROOT}" checkout --quiet master
}

oc_add() {
    env \
        PATH="${STUB_DIR}:${PATH}" \
        OPENEMR_ROOT="${TMP_ROOT}" \
        WORKTREE_PARENT="${TMP_PARENT}" \
        WT_CANONICAL_URL="file://${TMP_ROOT}" \
        WT_STATE_LOCK_TIMEOUT_S=5 \
        "${SCRIPT}" worktree add "$@"
}

# --- docker/library missing on the branch ----------------------------------

@test "add: branch without docker/library/ dies with 'Missing directory'" {
    make_branch_without no-library docker/library
    run oc_add wt-no-library --base no-library -b --env easy
    assert_failure
    assert_output --partial "Missing directory"
    assert_output --partial "docker/library"
    # No state entry written.
    if [[ -f "${STATE_FILE}" ]]; then
        [[ "$(jq -r 'has("wt-no-library")' "${STATE_FILE}")" = "false" ]] \
            || fail "state entry written despite docker/library missing"
    fi
}

# --- docker/development-<env>/ missing on the branch -----------------------

@test "add: branch without docker/development-<env>/ silently synthesizes the dir (current contract)" {
    # Branch lacks docker/development-easy-light. Add succeeds because
    # cmd_worktree_add does `mkdir -p ${dir}/${compose_subdir}` after the
    # checkout, and wt_write_env / wt_write_override only need the dir to
    # exist (they don't check for an upstream docker-compose.yml).
    make_branch_without no-easy-light docker/development-easy-light
    run oc_add wt-no-easy-light --base no-easy-light -b --env easy-light
    assert_success
    # State entry written.
    [[ "$(jq -r 'has("wt-no-easy-light")' "${STATE_FILE}")" = "true" ]] \
        || fail "state entry missing despite successful add"
    # The compose dir was synthesized.
    [[ -d "${TMP_PARENT}/openemr-wt-wt-no-easy-light/docker/development-easy-light" ]] \
        || fail "compose subdir not created"
    # .env + override are written.
    [[ -f "${TMP_PARENT}/openemr-wt-wt-no-easy-light/docker/development-easy-light/.env" ]] \
        || fail ".env not written"
    [[ -f "${TMP_PARENT}/openemr-wt-wt-no-easy-light/docker/development-easy-light/docker-compose.override.yml" ]] \
        || fail "override not written"
    # docker-compose.yml is NOT magically created — the user's eventual
    # `worktree up` will fail when docker compose tries to load it.
    [[ ! -f "${TMP_PARENT}/openemr-wt-wt-no-easy-light/docker/development-easy-light/docker-compose.yml" ]] \
        || fail "docker-compose.yml unexpectedly synthesized; that would be a contract change"
}

@test "add: synthesized compose dir leads to docker compose failure on 'worktree up'" {
    # Companion to the above: surface where the error actually lands.
    # The docker stub returns success for everything (which is realistic
    # of what a real docker daemon would do up to the point of "this
    # compose file doesn't exist"). To exercise the failure surface, we
    # need to drive docker compose with a real -f that doesn't exist —
    # since our stub ignores -f, the up call "succeeds" against the stub.
    # Pin instead that the WORKING tree has the gap so any real docker
    # invocation would fail.
    make_branch_without no-easy docker/development-easy
    run oc_add wt-up-will-fail --base no-easy -b --env easy
    assert_success
    [[ ! -f "${TMP_PARENT}/openemr-wt-wt-up-will-fail/docker/development-easy/docker-compose.yml" ]] \
        || fail "docker-compose.yml present on branch that should lack it"
}
