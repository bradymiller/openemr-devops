# BATS: cmd_worktree_exec — container resolution + dispatch.
#
# `worktree exec <branch> <cmd> [args...]` resolves the worktree's openemr
# container by compose project label + service label, then re-execs the
# openemr-cmd script with `-d <container_id> <cmd> [args...]`. This is the
# mechanism the openemr/CLAUDE.md tells you to use for running any
# openemr-cmd command against a specific worktree's stack from outside it.
#
# Tests cover the argument-validation error paths plus a happy-path
# assertion that docker is called with the right project+service label
# filters. The actual exec into the in-container dispatch path is not
# asserted on directly — that's behavior of the -d path, separately
# exercised in cli_smoke.bats.

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
    export TMP_PARENT TMP_ROOT STUB_DIR
}

teardown() {
    [[ -n "${TMP_PARENT:-}" ]] && rm -rf "${TMP_PARENT}"
    [[ -n "${STUB_DIR:-}" ]] && rm -rf "${STUB_DIR}"
    return 0
}

# Add a worktree so subsequent exec calls have something to dispatch against.
setup_worktree() {
    run env \
        PATH="${STUB_DIR}:${PATH}" \
        OPENEMR_ROOT="${TMP_ROOT}" \
        WORKTREE_PARENT="${TMP_PARENT}" \
        WT_CANONICAL_URL="file://${TMP_ROOT}" \
        "${SCRIPT}" worktree add "$@"
    assert_success
    : > "${STUB_DIR}/docker.log"
}

run_exec() {
    run env \
        PATH="${STUB_DIR}:${PATH}" \
        OPENEMR_ROOT="${TMP_ROOT}" \
        WORKTREE_PARENT="${TMP_PARENT}" \
        DOCKER_PS_OUTPUT="${DOCKER_PS_OUTPUT-}" \
        "${SCRIPT}" worktree exec "$@"
}

# --- argument validation ----------------------------------------------------

@test "exec: missing branch arg shows usage" {
    run env PATH="${STUB_DIR}:${PATH}" OPENEMR_ROOT="${TMP_ROOT}" \
        WORKTREE_PARENT="${TMP_PARENT}" "${SCRIPT}" worktree exec
    assert_failure
    assert_output --partial "Usage: openemr-cmd worktree exec <branch>"
}

@test "exec: branch with no command shows usage" {
    setup_worktree feature-exec-noargs -b
    run_exec feature-exec-noargs
    assert_failure
    assert_output --partial "Usage: openemr-cmd worktree exec <branch>"
}

@test "exec: state file missing dies with 'No worktrees found'" {
    # Don't run setup_worktree — leave state file absent.
    run_exec some-branch some-cmd
    assert_failure
    assert_output --partial "No worktrees found"
}

@test "exec: unknown branch dies with 'No worktree found for branch'" {
    setup_worktree feature-known -b
    run_exec feature-unknown some-cmd
    assert_failure
    assert_output --partial "No worktree found for branch 'feature-unknown'"
}

# --- container resolution ---------------------------------------------------

@test "exec: when no container matches the labels, dies with 'not running' hint" {
    setup_worktree feature-no-container -b
    # DOCKER_PS_OUTPUT empty (default) -> docker ps returns nothing ->
    # container_id stays empty -> the "not running" wt_die fires.
    run_exec feature-no-container some-cmd
    assert_failure
    assert_output --partial "OpenEMR container is not running for worktree 'feature-no-container'"
    assert_output --partial "openemr-cmd worktree up feature-no-container"
}

@test "exec: container resolution queries docker ps with the right project+service labels" {
    setup_worktree feature-resolve -b
    # Make docker ps return a fake container id so the script proceeds to
    # the exec. The exec then re-invokes $SCRIPT with -d <id> ... which
    # goes into the -d dispatch path; that path also calls docker, but we
    # only assert on the FIRST 'ps' invocation here (the label-filter one).
    DOCKER_PS_OUTPUT="abc123fakecid" run_exec feature-resolve dl 2>/dev/null || true
    # The label-filter ps call is what proves container resolution went
    # via the right path. Both --filter args must be present on the same
    # invocation, plus --format {{.ID}}.
    local ps_call
    ps_call=$(grep -F -e "ps --filter " "${STUB_DIR}/docker.log" \
              | grep -F -e "label=com.docker.compose.project=openemr-feature-resolve" \
              | grep -F -e "label=com.docker.compose.service=openemr" \
              | head -1)
    [[ -n "${ps_call}" ]] || { cat "${STUB_DIR}/docker.log"; fail "expected label-filter ps call not found"; }
    [[ "${ps_call}" == *"--format {{.ID}}"* ]] \
        || fail "expected --format {{.ID}}; got: ${ps_call}"
}
