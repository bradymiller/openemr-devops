# BATS: wt_acquire_state_lock / wt_release_state_lock mechanics.
#
# The state lock is the mkdir-based primitive that serializes
# cmd_worktree_add / _remove / _set_env. Concurrent correctness is
# exercised end-to-end in worktree_concurrent.bats; this file pins the
# lock primitive itself:
#
#   - acquire/release roundtrip leaves no lockdir
#   - a held lock blocks a second acquirer until released
#   - a stale lock (older than WT_STATE_LOCK_STALE_S) is stolen
#   - the timeout fires with a clear error rather than blocking forever
#
# All tests source the script's function defs so the helpers run under
# the bats process — no need to drive cmd_worktree_add to exercise the
# lock layer.

load '../test_helper/bats-support/load'
load '../test_helper/bats-assert/load'
load 'helpers'

setup() {
    SCRIPT="$(oc_script_path)"
    [[ -x "$SCRIPT" ]] || skip "openemr-cmd script not found"
    TMP_ROOT=$(oc_mktempdir)
    TMP_STATE="${TMP_ROOT}/.worktrees.json"
    LOCK_DIR="${TMP_STATE}.lock"
    echo '{}' > "${TMP_STATE}"
    export TMP_ROOT TMP_STATE LOCK_DIR
}

teardown() {
    [[ -n "${TMP_ROOT:-}" ]] && rm -rf "${TMP_ROOT}"
    return 0
}

# Run a snippet with the script's function defs sourced. WT_STATE_FILE is
# overridden so the lock helpers operate on our tmp file's sibling lockdir.
run_locked() {
    local snippet=$1
    run env \
        OPENEMR_ROOT="${TMP_ROOT}" \
        WT_STATE_FILE="${TMP_STATE}" \
        WT_STATE_LOCK_STALE_S="${WT_STATE_LOCK_STALE_S:-120}" \
        WT_STATE_LOCK_TIMEOUT_S="${WT_STATE_LOCK_TIMEOUT_S:-300}" \
        bash -c "
            set -uo pipefail
            eval \"\$(head -n ${OC_SCRIPT_FUNCS_END} '${SCRIPT}')\"
            # Re-export WT_STATE_FILE so the lock helpers see our tmp file
            # (the script's top-level assignment otherwise overrides our env).
            WT_STATE_FILE='${TMP_STATE}'
            WT_STATE_LOCK_DIR='${LOCK_DIR}'
            ${snippet}
        "
}

# --- acquire/release roundtrip ----------------------------------------------

@test "lock: acquire then release leaves no lockdir on disk" {
    run_locked 'wt_acquire_state_lock; wt_release_state_lock'
    assert_success
    [[ ! -e "${LOCK_DIR}" ]] || fail "lockdir still exists after release"
}

@test "lock: acquire is idempotent for the same shell process (second acquire is a no-op)" {
    # wt_acquire_state_lock checks WT_STATE_LOCK_HELD to short-circuit a
    # second acquire from the same shell. Without that, the second acquire
    # would block waiting on its own lock and hit the timeout.
    run_locked '
        wt_acquire_state_lock
        wt_acquire_state_lock
        wt_release_state_lock
    '
    assert_success
    [[ ! -e "${LOCK_DIR}" ]]
}

# --- another process holds the lock -----------------------------------------

@test "lock: a held lock blocks a second acquirer until release" {
    # Hold the lock externally by manually creating the lockdir. The script
    # acquire should spin (timeout very short for this test) and fail.
    mkdir "${LOCK_DIR}"
    WT_STATE_LOCK_TIMEOUT_S=1 WT_STATE_LOCK_STALE_S=9999 \
        run_locked 'wt_acquire_state_lock' 2>&1
    assert_failure
    assert_output --partial "Timed out waiting for state lock"
    # Our externally-held lockdir is still there (the timeout path doesn't
    # rmdir it — only release does).
    [[ -d "${LOCK_DIR}" ]]
    rmdir "${LOCK_DIR}"
}

# --- stale-lock steal -------------------------------------------------------

@test "lock: a stale lock (older than WT_STATE_LOCK_STALE_S) is stolen" {
    # Create a stale lockdir, then backdate its mtime to look ancient.
    mkdir "${LOCK_DIR}"
    # touch -d/-t portably: use touch -t with an explicit old timestamp.
    # 2000-01-01 is well past any reasonable stale-threshold.
    touch -t 200001010000 "${LOCK_DIR}"
    # Stale threshold = 60s; lock backdated ~25 years → should be stolen.
    WT_STATE_LOCK_STALE_S=60 WT_STATE_LOCK_TIMEOUT_S=5 \
        run_locked '
            wt_acquire_state_lock
            wt_release_state_lock
        '
    assert_success
    assert_output --partial "Stealing stale state lock"
    [[ ! -e "${LOCK_DIR}" ]] || fail "lockdir should be released after the steal+acquire+release cycle"
}

@test "lock: a fresh externally-held lock is NOT stolen — waits and times out instead" {
    # The lock is fresh (mtime = now); the steal heuristic must NOT fire.
    mkdir "${LOCK_DIR}"
    WT_STATE_LOCK_STALE_S=60 WT_STATE_LOCK_TIMEOUT_S=1 \
        run_locked 'wt_acquire_state_lock' 2>&1
    assert_failure
    refute_output --partial "Stealing stale state lock"
    assert_output --partial "Timed out waiting for state lock"
    rmdir "${LOCK_DIR}"
}

# --- release is safe to call when not held ----------------------------------

@test "lock: release without prior acquire is a no-op (WT_STATE_LOCK_HELD=0)" {
    run_locked 'wt_release_state_lock'
    assert_success
    [[ ! -e "${LOCK_DIR}" ]]
}
