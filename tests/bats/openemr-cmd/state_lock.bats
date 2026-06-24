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

@test "lock: an age-stale lock whose holder PID is STILL ALIVE is NOT stolen" {
    # Owner-aware steal: even when the lock is older than the stale
    # threshold, we must verify the holder PID is gone (kill -0 fails)
    # before reaping. A slow-but-alive holder (e.g., midway through a
    # multi-minute canonical fetch) deserves to keep its lock.
    mkdir "${LOCK_DIR}"
    # Use $$ — guaranteed-live PID (the bats process itself).
    echo $$ > "${LOCK_DIR}/holder"
    touch -t 200001010000 "${LOCK_DIR}"   # backdate to look "stale"
    WT_STATE_LOCK_STALE_S=60 WT_STATE_LOCK_TIMEOUT_S=1 \
        run_locked 'wt_acquire_state_lock' 2>&1
    assert_failure
    # Steal did NOT fire (holder is alive).
    refute_output --partial "Stealing stale state lock"
    # Acquirer timed out instead.
    assert_output --partial "Timed out waiting for state lock"
    # And critically: the lockdir + holder file are untouched.
    [[ -d "${LOCK_DIR}" ]] || fail "lockdir was deleted despite live holder"
    [[ "$(cat "${LOCK_DIR}/holder")" = "$$" ]] || fail "holder file was overwritten"
    rm -rf "${LOCK_DIR}"
}

@test "lock: an age-stale lock whose holder PID IS DEAD is stolen" {
    # Use a PID we know to be dead: spawn a quick subshell, capture
    # its PID, wait for it to exit, then use that PID. The kernel may
    # eventually recycle it, but for the test's lifetime it's reliably
    # dead and the kill -0 check returns failure.
    mkdir "${LOCK_DIR}"
    local dead_pid
    dead_pid=$( ( exec sh -c 'exit 0' ) & echo $! )
    wait "${dead_pid}" 2>/dev/null || true
    # If the PID is still alive somehow (very unlikely), skip rather
    # than write a flaky assertion.
    if kill -0 "${dead_pid}" 2>/dev/null; then
        skip "PID ${dead_pid} did not actually die — test environment quirk"
    fi
    echo "${dead_pid}" > "${LOCK_DIR}/holder"
    touch -t 200001010000 "${LOCK_DIR}"
    WT_STATE_LOCK_STALE_S=60 WT_STATE_LOCK_TIMEOUT_S=5 \
        run_locked '
            wt_acquire_state_lock
            wt_release_state_lock
        '
    assert_success
    assert_output --partial "Stealing stale state lock"
    [[ ! -e "${LOCK_DIR}" ]] || fail "lockdir should be gone after the steal+acquire+release cycle"
}

@test "lock: release is identity-checked — does NOT rmdir a different holder's lock" {
    # Simulate the second-order race: process A acquired, was stolen
    # from, and then tries to release. The release MUST notice that
    # the holder file no longer has its PID and leave the lockdir
    # alone (otherwise it would delete the new holder's lock and
    # reopen the race).
    #
    # We fake the state by writing a holder PID different from $$
    # into the lockdir, then setting WT_STATE_LOCK_HELD=1 so release
    # thinks "we" hold it, and asserting release leaves the dir intact.
    mkdir "${LOCK_DIR}"
    echo 99999 > "${LOCK_DIR}/holder"   # pretend a different process holds it now
    run_locked 'WT_STATE_LOCK_HELD=1; wt_release_state_lock'
    assert_success
    [[ -d "${LOCK_DIR}" ]] || fail "release deleted a lockdir whose holder PID was NOT ours"
    [[ "$(cat "${LOCK_DIR}/holder")" = "99999" ]] || fail "release overwrote/cleared a different holder's marker"
    rm -rf "${LOCK_DIR}"
}

# --- release is safe to call when not held ----------------------------------

@test "lock: release without prior acquire is a no-op (WT_STATE_LOCK_HELD=0)" {
    run_locked 'wt_release_state_lock'
    assert_success
    [[ ! -e "${LOCK_DIR}" ]]
}

@test "lock: wt_lock_mtime_s returns single-line numeric output (no stat-format-mismatch pollution)" {
    # Regression test for the cross-platform stat bug: on Linux, an old
    # `wt_lock_mtime_s` chained `stat -c %Y` || `stat -f %m`, which on
    # GNU stat interpreted `-f` as filesystem-info mode. When the first
    # stat failed (e.g., lockdir vanished mid-call under concurrent
    # steal), the second stat printed a multi-line "File: ..." block to
    # stdout, and that polluted text propagated into `(( ... ))` arithmetic
    # causing bash to abort with "File: unbound variable". The fix is to
    # pick the right flag once based on stat flavor and never fall
    # through. This test pins:
    #   (a) the function returns single-line output, and
    #   (b) the missing-path case returns "0" — not multi-line stat help.
    mkdir "${LOCK_DIR}"
    run_locked '
        out=$(wt_lock_mtime_s "'"${LOCK_DIR}"'")
        lines=$(printf "%s" "$out" | wc -l)
        echo "lines=${lines}"
        echo "out=${out}"
    '
    assert_success
    # `wc -l` counts newlines; a single-line value (mtime) has 0 newlines.
    assert_output --partial "lines=0"
    rmdir "${LOCK_DIR}"

    # Missing-path case: must return "0", not multi-line stat output.
    run_locked '
        out=$(wt_lock_mtime_s "'"${TMP_ROOT}/definitely-not-here"'")
        echo "[${out}]"
    '
    assert_success
    assert_output "[0]"
}
