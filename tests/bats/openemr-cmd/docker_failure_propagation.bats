# BATS: docker compose failures propagate (no silent swallowing).
#
# The script runs under `set -euo pipefail`. docker compose invocations
# in cmd_worktree_up/down/remove are wrapped with 2>/dev/null in some
# spots but NEVER `|| true`, so a non-zero exit must abort the
# operation. These tests pin that contract: if docker fails, the user
# sees the failure (non-zero exit code) and state is not silently
# advanced past the failure point.

load '../test_helper/bats-support/load'
load '../test_helper/bats-assert/load'
load 'helpers'

# Variant docker stub: respond to the 'compose' plugin probe with success
# (so check_docker_compose_install picks the plugin path) but fail every
# subsequent 'compose ...' subcommand with exit 7.
oc_make_docker_failing_stub_dir() {
    local d log
    d=$(oc_mktempdir)
    log="${d}/docker.log"
    : > "${log}"
    cat > "${d}/docker" <<STUB
#!/bin/sh
echo "\$@" >> "${log}"
# Plugin probe: 'docker compose' (no further args) must succeed so
# check_docker_compose_install detects the plugin path.
if [ "\$#" = "1" ] && [ "\$1" = "compose" ]; then
    exit 0
fi
# Any subsequent compose subcommand (up/down/ps/etc.) fails with code 7.
case " \$* " in
    *' compose '*) exit 7 ;;
esac
# Non-compose invocations succeed (no current ones, but be defensive).
exit 0
STUB
    chmod +x "${d}/docker"
    echo "${d}"
}

setup() {
    SCRIPT="$(oc_script_path)"
    [[ -x "$SCRIPT" ]] || skip "openemr-cmd script not found"
    TMP_PARENT=$(oc_mktempdir)
    TMP_ROOT="${TMP_PARENT}/primary"
    mkdir -p "${TMP_ROOT}"
    oc_init_repo_with_fixtures "${TMP_ROOT}"
    STUB_OK_DIR=$(oc_make_docker_stub_dir)
    STUB_FAIL_DIR=$(oc_make_docker_failing_stub_dir)
    STATE_FILE="${TMP_ROOT}/.worktrees.json"
    export TMP_PARENT TMP_ROOT STUB_OK_DIR STUB_FAIL_DIR STATE_FILE
}

teardown() {
    [[ -n "${TMP_PARENT:-}" ]] && rm -rf "${TMP_PARENT}"
    [[ -n "${STUB_OK_DIR:-}" ]] && rm -rf "${STUB_OK_DIR}"
    [[ -n "${STUB_FAIL_DIR:-}" ]] && rm -rf "${STUB_FAIL_DIR}"
    return 0
}

# Add a worktree (with the OK stub) so the FAIL-stub tests have a target.
fixture_add() {
    local branch=$1 env=${2:-easy}
    env \
        PATH="${STUB_OK_DIR}:${PATH}" \
        OPENEMR_ROOT="${TMP_ROOT}" \
        WORKTREE_PARENT="${TMP_PARENT}" \
        WT_CANONICAL_URL="file://${TMP_ROOT}" \
        "${SCRIPT}" worktree add "${branch}" -b --env "${env}" >/dev/null 2>&1
}

# --- worktree up: docker compose up fails -----------------------------------

@test "docker failure: 'worktree up' surfaces non-zero exit when docker compose up fails" {
    fixture_add up-fail-branch
    run env \
        PATH="${STUB_FAIL_DIR}:${PATH}" \
        OPENEMR_ROOT="${TMP_ROOT}" \
        WORKTREE_PARENT="${TMP_PARENT}" \
        "${SCRIPT}" worktree up up-fail-branch
    assert_failure
    # State entry still present — `up` does not mutate state.
    [[ "$(jq -r 'has("up-fail-branch")' "${STATE_FILE}")" = "true" ]] \
        || fail "state entry disappeared on failed up"
}

# --- worktree down: docker compose down fails -------------------------------

@test "docker failure: 'worktree down' surfaces non-zero exit when docker compose down fails" {
    fixture_add down-fail-branch
    run env \
        PATH="${STUB_FAIL_DIR}:${PATH}" \
        OPENEMR_ROOT="${TMP_ROOT}" \
        WORKTREE_PARENT="${TMP_PARENT}" \
        "${SCRIPT}" worktree down down-fail-branch
    assert_failure
    [[ "$(jq -r 'has("down-fail-branch")' "${STATE_FILE}")" = "true" ]] \
        || fail "state entry disappeared on failed down"
}

# --- worktree remove: docker compose down fails -----------------------------
# 'remove' wraps compose down with 2>/dev/null. set -e still propagates the
# exit code. State entry must remain intact so the user can retry once they
# resolve the docker issue.

@test "docker failure: 'worktree remove' aborts on compose down failure; state + dir preserved for retry" {
    fixture_add rm-fail-branch
    local wt_dir="${TMP_PARENT}/openemr-wt-rm-fail-branch"
    [[ -d "${wt_dir}" ]] || fail "fixture worktree dir not created"
    run bash -c "printf 'y\n' | env \
        PATH='${STUB_FAIL_DIR}:${PATH}' \
        OPENEMR_ROOT='${TMP_ROOT}' \
        WORKTREE_PARENT='${TMP_PARENT}' \
        WT_STATE_LOCK_TIMEOUT_S=5 \
        '${SCRIPT}' worktree remove rm-fail-branch --keep-volumes"
    assert_failure
    # State entry preserved.
    [[ "$(jq -r 'has("rm-fail-branch")' "${STATE_FILE}")" = "true" ]] \
        || fail "state entry was removed despite docker failure"
    # Worktree dir preserved.
    [[ -d "${wt_dir}" ]] || fail "worktree dir was removed despite docker failure"
    # Lockfile cleaned up by the EXIT trap.
    [[ ! -e "${STATE_FILE}.lock" ]] || fail "lockfile lingering after failed remove"
}
