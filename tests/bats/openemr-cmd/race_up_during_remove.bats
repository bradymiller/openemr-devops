# BATS: `worktree up` does NOT acquire the state lock.
#
# Today, only state-mutating ops (add / remove / set-env / prune) take
# the lock. Read-and-act ops (up / down / start / stop / list) read
# state without coordination. That means a `worktree up` can race with
# a concurrent `worktree remove` on the same branch:
#
#   - If up reads state before remove's wt_state_remove runs, up sees
#     the entry and proceeds to `docker compose up`, creating new
#     containers AFTER remove already brought the old ones down. Once
#     remove finishes, those new containers are orphaned (no state
#     entry pointing at them).
#
# These tests PIN that current contract — there's no read-side
# coordination — so any future change that adds a lock to `up` is an
# intentional decision, not an accidental behavior shift. The race
# itself is documented as a follow-up to revisit.

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
    LOCK_FILE="${STATE_FILE}.lock"
    export TMP_PARENT TMP_ROOT STUB_DIR STATE_FILE LOCK_FILE
}

teardown() {
    [[ -n "${TMP_PARENT:-}" ]] && rm -rf "${TMP_PARENT}"
    [[ -n "${STUB_DIR:-}" ]] && rm -rf "${STUB_DIR}"
    return 0
}

oc_add() {
    env \
        PATH="${STUB_DIR}:${PATH}" \
        OPENEMR_ROOT="${TMP_ROOT}" \
        WORKTREE_PARENT="${TMP_PARENT}" \
        WT_CANONICAL_URL="file://${TMP_ROOT}" \
        "${SCRIPT}" worktree add "$@"
}

# --- contract: up does not block on a held lock ---------------------------

@test "race: 'worktree up' does NOT acquire the state lock (runs even when lock is held)" {
    oc_add up-vs-lock -b --env easy >/dev/null
    # Manually hold the lock as a different process would.
    echo 99999 > "${LOCK_FILE}"

    # With a very short timeout — if up tried to acquire the lock, it
    # would time out in 1 second. The fact that it doesn't time out
    # proves it doesn't acquire the lock.
    run env \
        PATH="${STUB_DIR}:${PATH}" \
        OPENEMR_ROOT="${TMP_ROOT}" \
        WORKTREE_PARENT="${TMP_PARENT}" \
        WT_STATE_LOCK_TIMEOUT_S=1 \
        "${SCRIPT}" worktree up up-vs-lock
    # Should succeed (docker stub returns 0).
    assert_success
    refute_output --partial "Timed out waiting for state lock"
    # Lockfile we placed manually still there — up did not touch it.
    [[ -f "${LOCK_FILE}" ]] || fail "manual lockfile vanished after up; expected no-touch"
    [[ "$(cat "${LOCK_FILE}")" = "99999" ]] || fail "manual holder PID overwritten"
    rm -f "${LOCK_FILE}"
}

# --- companion: down / start / stop / list also don't acquire the lock ----
# Pinning the broader contract so any future "add lock to read paths"
# change has to update these explicitly.

@test "race: 'worktree down' does NOT acquire the state lock" {
    oc_add down-vs-lock -b --env easy >/dev/null
    echo 99999 > "${LOCK_FILE}"
    run env \
        PATH="${STUB_DIR}:${PATH}" \
        OPENEMR_ROOT="${TMP_ROOT}" \
        WORKTREE_PARENT="${TMP_PARENT}" \
        WT_STATE_LOCK_TIMEOUT_S=1 \
        "${SCRIPT}" worktree down down-vs-lock --keep-volumes
    assert_success
    refute_output --partial "Timed out"
    [[ -f "${LOCK_FILE}" ]] || fail "manual lockfile vanished after down"
    rm -f "${LOCK_FILE}"
}

@test "race: 'worktree list' does NOT acquire the state lock" {
    oc_add list-vs-lock -b --env easy >/dev/null
    echo 99999 > "${LOCK_FILE}"
    run env \
        PATH="${STUB_DIR}:${PATH}" \
        OPENEMR_ROOT="${TMP_ROOT}" \
        WORKTREE_PARENT="${TMP_PARENT}" \
        WT_STATE_LOCK_TIMEOUT_S=1 \
        "${SCRIPT}" worktree list
    assert_success
    refute_output --partial "Timed out"
    assert_output --partial "list-vs-lock"
    [[ -f "${LOCK_FILE}" ]] || fail "manual lockfile vanished after list"
    rm -f "${LOCK_FILE}"
}

# --- contract: up after remove cleared state surfaces a clean error -------

@test "race: 'worktree up' after the state entry is gone surfaces 'No worktree found'" {
    # Simulate the post-remove state: state file exists but has no entry
    # for the branch.
    echo '{}' > "${STATE_FILE}"
    run env \
        PATH="${STUB_DIR}:${PATH}" \
        OPENEMR_ROOT="${TMP_ROOT}" \
        WORKTREE_PARENT="${TMP_PARENT}" \
        "${SCRIPT}" worktree up gone-branch
    assert_failure
    # wt_compose_cmd's wt_state_get returns empty → wt_die at line ~638.
    assert_output --partial "No worktree found for branch 'gone-branch'"
}
