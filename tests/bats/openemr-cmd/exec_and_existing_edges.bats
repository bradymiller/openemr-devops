# BATS: existing-state edges + `worktree exec` argument-shape tests.
#
# Covered:
#   - re-add of an existing branch refuses (no double-write)
#   - exec with no args / missing cmd surfaces usage
#   - exec for an unknown branch surfaces "No worktree found"
#   - exec when the container isn't running surfaces a clear hint
#   - down/stop for an unknown branch surface "No worktree found"

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

oc_run() {
    env \
        PATH="${STUB_DIR}:${PATH}" \
        OPENEMR_ROOT="${TMP_ROOT}" \
        WORKTREE_PARENT="${TMP_PARENT}" \
        WT_CANONICAL_URL="file://${TMP_ROOT}" \
        WT_STATE_LOCK_TIMEOUT_S=5 \
        "${SCRIPT}" "$@"
}

# --- existing state edges ---------------------------------------------------

@test "existing state: re-add of an already-tracked branch refuses with clear error" {
    oc_run worktree add dup-branch -b --env easy >/dev/null
    local before
    before=$(cat "${STATE_FILE}")
    run oc_run worktree add dup-branch -b --env easy
    assert_failure
    assert_output --partial "already exists"
    # State unchanged — no clobber of the original entry.
    [[ "$(cat "${STATE_FILE}")" = "${before}" ]] || fail "state file mutated by failed re-add"
}

@test "existing state: 'down' for unknown branch fails with state lookup error" {
    # No state file at all yet → "No worktrees found".
    run oc_run worktree down ghost-branch
    assert_failure
    assert_output --partial "No worktrees found"
}

@test "existing state: 'stop' for unknown branch (state file exists but entry missing) fails cleanly" {
    # Seed an empty-but-valid state file.
    echo '{}' > "${STATE_FILE}"
    run oc_run worktree stop ghost-branch
    assert_failure
    # wt_compose_cmd's wt_state_get returns "" → wt_die "No worktree found for branch 'ghost-branch'"
    assert_output --partial "No worktree found for branch 'ghost-branch'"
}

# --- exec argument-shape edges ---------------------------------------------

@test "exec: no args at all surfaces usage" {
    echo '{}' > "${STATE_FILE}"
    run oc_run worktree exec
    assert_failure
    assert_output --partial "Usage:"
    assert_output --partial "worktree exec"
}

@test "exec: branch supplied but no command surfaces usage" {
    echo '{}' > "${STATE_FILE}"
    run oc_run worktree exec some-branch
    assert_failure
    assert_output --partial "Usage:"
    assert_output --partial "worktree exec"
}

@test "exec: unknown branch surfaces 'No worktree found'" {
    echo '{}' > "${STATE_FILE}"
    run oc_run worktree exec ghost-branch some-subcommand
    assert_failure
    assert_output --partial "No worktree found for branch 'ghost-branch'"
}

@test "exec: branch exists but no container running surfaces clear hint" {
    # Add a worktree so the branch is in state, then exec when container
    # discovery returns nothing (DOCKER_PS_OUTPUT default = empty).
    oc_run worktree add no-container -b --env easy >/dev/null
    run oc_run worktree exec no-container some-subcommand
    assert_failure
    assert_output --partial "OpenEMR container is not running for worktree 'no-container'"
    # Hint mentions 'worktree up' as the next step.
    assert_output --partial "worktree up no-container"
}
