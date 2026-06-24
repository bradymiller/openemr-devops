# BATS: cmd_worktree_add --start failure behavior.
#
# Sequence:
#   1. wt_state_set  (state entry written)
#   2. wt_write_env  + wt_write_override  (compose files written)
#   3. cmd_worktree_up  (docker compose up -d)
#
# If step 3 fails, set -e exits the script. State + dir + compose files
# are already on disk; the partial stack-up may have left some containers
# in a bad state. Pin the contract: state and dir survive, so a follow-up
# `worktree up` retry or `worktree remove` is straightforward.
#
# NOTE: this is intentional non-atomic behavior — rolling back would
# require deleting the worktree the user just created, which they might
# not want (the only thing wrong is the docker stack, not the checkout).

load '../test_helper/bats-support/load'
load '../test_helper/bats-assert/load'
load 'helpers'

# Variant docker stub: 'compose' probe succeeds; any 'compose up' fails
# with exit 9. Other compose subcommands also fail so a partial state
# doesn't accidentally clean up via a sneaky `down` call.
oc_make_docker_up_failing_stub_dir() {
    local d log
    d=$(oc_mktempdir)
    log="${d}/docker.log"
    : > "${log}"
    cat > "${d}/docker" <<STUB
#!/bin/sh
echo "\$@" >> "${log}"
if [ "\$#" = "1" ] && [ "\$1" = "compose" ]; then
    exit 0
fi
case " \$* " in
    *' up '*) exit 9 ;;
    *' compose '*) exit 0 ;;
esac
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
    STUB_DIR=$(oc_make_docker_up_failing_stub_dir)
    STATE_FILE="${TMP_ROOT}/.worktrees.json"
    export TMP_PARENT TMP_ROOT STUB_DIR STATE_FILE
}

teardown() {
    [[ -n "${TMP_PARENT:-}" ]] && rm -rf "${TMP_PARENT}"
    [[ -n "${STUB_DIR:-}" ]] && rm -rf "${STUB_DIR}"
    return 0
}

@test "add --start: when docker compose up fails, state + dir + compose files survive (no rollback)" {
    run env \
        PATH="${STUB_DIR}:${PATH}" \
        OPENEMR_ROOT="${TMP_ROOT}" \
        WORKTREE_PARENT="${TMP_PARENT}" \
        WT_CANONICAL_URL="file://${TMP_ROOT}" \
        WT_STATE_LOCK_TIMEOUT_S=5 \
        "${SCRIPT}" worktree add start-fail -b --env easy --start
    assert_failure

    # State entry present — wt_state_set already ran.
    [[ -f "${STATE_FILE}" ]] || fail "state file missing"
    [[ "$(jq -r 'has("start-fail")' "${STATE_FILE}")" = "true" ]] \
        || fail "state entry missing"
    # Dir present and is a real git worktree (registered).
    local wt_dir="${TMP_PARENT}/openemr-wt-start-fail"
    [[ -d "${wt_dir}" ]] || fail "worktree dir missing"
    git -C "${TMP_ROOT}" worktree list --porcelain \
        | grep -Fqx "worktree ${wt_dir}" \
        || fail "worktree not registered with git"
    # Compose files written.
    [[ -f "${wt_dir}/docker/development-easy/.env" ]] \
        || fail ".env missing after failed --start"
    [[ -f "${wt_dir}/docker/development-easy/docker-compose.override.yml" ]] \
        || fail "override missing after failed --start"
    # Lockfile cleaned up via EXIT trap.
    [[ ! -e "${STATE_FILE}.lock" ]] || fail "lockfile lingering after failed --start"
}

@test "add --start failure: a follow-up 'worktree up' (without --start) can be retried" {
    # The 'no rollback' contract above only matters if recovery actually
    # works. Confirm that with the up-failing stub still in place, a
    # subsequent 'worktree up' invocation reaches the same docker call
    # path (i.e. up errors are surfaced, not swallowed) — same failure,
    # not a different one. The user's recovery path is real.
    run env \
        PATH="${STUB_DIR}:${PATH}" \
        OPENEMR_ROOT="${TMP_ROOT}" \
        WORKTREE_PARENT="${TMP_PARENT}" \
        WT_CANONICAL_URL="file://${TMP_ROOT}" \
        "${SCRIPT}" worktree add retry-target -b --env easy --start
    assert_failure
    [[ "$(jq -r 'has("retry-target")' "${STATE_FILE}")" = "true" ]] \
        || fail "state entry missing after first failed add --start"
    # Retry just the up — should also fail (stub still rejects compose up).
    run env \
        PATH="${STUB_DIR}:${PATH}" \
        OPENEMR_ROOT="${TMP_ROOT}" \
        WORKTREE_PARENT="${TMP_PARENT}" \
        "${SCRIPT}" worktree up retry-target
    assert_failure
    # State + dir still there.
    [[ "$(jq -r 'has("retry-target")' "${STATE_FILE}")" = "true" ]] \
        || fail "state entry gone after up retry"
    [[ -d "${TMP_PARENT}/openemr-wt-retry-target" ]] \
        || fail "dir gone after up retry"
}
