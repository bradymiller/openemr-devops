# BATS: lower-value edges — offset gap-filling, set-env no-op + invalid env,
# and WT_STATE_LOCK_TIMEOUT_S=0 fail-fast.

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

# --- offset gap-filling -----------------------------------------------------

@test "offset: wt_next_offset fills the lowest gap (state has 1,3 → next add gets 2)" {
    # Seed the state with offsets 1 and 3, leaving 2 as the gap.
    cat > "${STATE_FILE}" <<JSON
{
  "alpha": {"offset": 1, "dir": "${TMP_PARENT}/openemr-wt-alpha", "env": "easy"},
  "gamma": {"offset": 3, "dir": "${TMP_PARENT}/openemr-wt-gamma", "env": "easy"}
}
JSON
    # Pre-create the registered worktrees so wt_validate_dir would pass if
    # something walked them (add doesn't validate existing entries; this is
    # just defensive setup).
    git -C "${TMP_ROOT}" worktree add --quiet -b alpha "${TMP_PARENT}/openemr-wt-alpha" >/dev/null
    git -C "${TMP_ROOT}" worktree add --quiet -b gamma "${TMP_PARENT}/openemr-wt-gamma" >/dev/null

    oc_run worktree add beta -b --env easy >/dev/null
    local beta_offset
    beta_offset=$(jq -r '.beta.offset' "${STATE_FILE}")
    [[ "${beta_offset}" = "2" ]] || fail "expected next offset 2 (filling the gap), got '${beta_offset}'"
}

@test "offset: wt_next_offset returns 1 on an empty state" {
    echo '{}' > "${STATE_FILE}"
    oc_run worktree add solo -b --env easy >/dev/null
    [[ "$(jq -r '.solo.offset' "${STATE_FILE}")" = "1" ]] || fail "expected first offset 1"
}

@test "offset: wt_next_offset returns N+1 when no gap (state has 1,2,3)" {
    cat > "${STATE_FILE}" <<JSON
{
  "a": {"offset": 1, "dir": "${TMP_PARENT}/openemr-wt-a", "env": "easy"},
  "b": {"offset": 2, "dir": "${TMP_PARENT}/openemr-wt-b", "env": "easy"},
  "c": {"offset": 3, "dir": "${TMP_PARENT}/openemr-wt-c", "env": "easy"}
}
JSON
    git -C "${TMP_ROOT}" worktree add --quiet -b a "${TMP_PARENT}/openemr-wt-a" >/dev/null
    git -C "${TMP_ROOT}" worktree add --quiet -b b "${TMP_PARENT}/openemr-wt-b" >/dev/null
    git -C "${TMP_ROOT}" worktree add --quiet -b c "${TMP_PARENT}/openemr-wt-c" >/dev/null

    oc_run worktree add d -b --env easy >/dev/null
    [[ "$(jq -r '.d.offset' "${STATE_FILE}")" = "4" ]] || fail "expected offset 4"
}

# --- set-env no-op / invalid env -------------------------------------------

@test "set-env: target env is the same as current env → no-op with informational message" {
    oc_run worktree add already-easy -b --env easy >/dev/null
    local before
    before=$(cat "${STATE_FILE}")
    run oc_run worktree set-env already-easy easy
    assert_success
    assert_output --partial "already on env 'easy'"
    # State unchanged.
    [[ "$(cat "${STATE_FILE}")" = "${before}" ]] || fail "state mutated by no-op set-env"
}

@test "set-env: invalid env name surfaces wt_validate_env error" {
    oc_run worktree add valid-branch -b --env easy >/dev/null
    run oc_run worktree set-env valid-branch nonsense-env
    assert_failure
    assert_output --partial "Invalid env"
    # State still says 'easy'.
    [[ "$(jq -r '."valid-branch".env' "${STATE_FILE}")" = "easy" ]] \
        || fail "state env field mutated despite invalid input"
}

# --- WT_STATE_LOCK_TIMEOUT_S=0 fail-fast -----------------------------------

@test "lock-timeout=0: a held lock causes immediate fail (no spin)" {
    # Hold the lock externally; ask for timeout=0 so the script must
    # fail-fast on the very first attempt.
    local lockfile="${STATE_FILE}.lock"
    echo 99999 > "${lockfile}"
    # Use `time` to bound the call — should return in well under a second.
    local start_s end_s elapsed
    start_s=$(date +%s)
    run env \
        PATH="${STUB_DIR}:${PATH}" \
        OPENEMR_ROOT="${TMP_ROOT}" \
        WORKTREE_PARENT="${TMP_PARENT}" \
        WT_STATE_LOCK_TIMEOUT_S=0 \
        "${SCRIPT}" worktree prune
    end_s=$(date +%s)
    elapsed=$((end_s - start_s))
    assert_failure
    assert_output --partial "Timed out waiting for state lock"
    (( elapsed <= 2 )) || fail "expected fail-fast under 2s, took ${elapsed}s"
    rm -f "${lockfile}"
}
