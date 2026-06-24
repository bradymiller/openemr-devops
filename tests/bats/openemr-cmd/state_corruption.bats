# BATS: behavior under corrupted .worktrees.json.
#
# We don't try to "recover" from a corrupted state file (jq can't parse
# it; there's no safe recovery without losing data). The invariant we
# pin here: when state is corrupted, the failing op MUST NOT overwrite
# it with an empty/blank file. The user's broken state must remain on
# disk so they can inspect/restore it.

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

oc_run_with_state() {
    env \
        PATH="${STUB_DIR}:${PATH}" \
        OPENEMR_ROOT="${TMP_ROOT}" \
        WORKTREE_PARENT="${TMP_PARENT}" \
        WT_CANONICAL_URL="file://${TMP_ROOT}" \
        WT_STATE_LOCK_TIMEOUT_S=5 \
        "${SCRIPT}" "$@"
}

# --- empty state file -------------------------------------------------------

@test "state corruption: empty .worktrees.json — add transparently repairs (zero-byte = nothing to preserve)" {
    # A zero-byte state file has no data to lose, so the script is free to
    # treat it like a missing file. jq's null input + assignment produces a
    # well-formed object on first write. This pins that behavior.
    : > "${STATE_FILE}"
    run oc_run_with_state worktree add foo -b --env easy
    assert_success
    # File is now valid JSON containing our entry.
    jq empty "${STATE_FILE}" || fail "state file is not valid JSON after add"
    [[ "$(jq -r 'has("foo")' "${STATE_FILE}")" = "true" ]] || fail "added entry missing"
}

@test "state corruption: empty .worktrees.json — list transparently repairs and shows no entries" {
    # wt_init_state treats empty as uninitialized and writes '{}'. list then
    # walks an empty object and reports no worktrees, exiting cleanly.
    : > "${STATE_FILE}"
    run oc_run_with_state worktree list
    assert_success
    jq empty "${STATE_FILE}" || fail "list left state file unparseable"
    [[ "$(jq -r 'length' "${STATE_FILE}")" = "0" ]] || fail "list invented entries"
}

# --- garbage non-JSON content ----------------------------------------------

@test "state corruption: non-JSON content — add fails, original content preserved" {
    printf 'not json at all\n' > "${STATE_FILE}"
    local before
    before=$(cat "${STATE_FILE}")
    run oc_run_with_state worktree add foo -b --env easy
    assert_failure
    [[ "$(cat "${STATE_FILE}")" = "${before}" ]] || fail "state file mutated by failing op"
}

@test "state corruption: non-JSON content — remove fails, original content preserved" {
    printf 'totally bogus\n' > "${STATE_FILE}"
    local before
    before=$(cat "${STATE_FILE}")
    # Feed 'y' in case the prompt is reached (it shouldn't be).
    run bash -c "printf 'y\n' | env \
        PATH='${STUB_DIR}:${PATH}' \
        OPENEMR_ROOT='${TMP_ROOT}' \
        WORKTREE_PARENT='${TMP_PARENT}' \
        WT_STATE_LOCK_TIMEOUT_S=5 \
        '${SCRIPT}' worktree remove foo --keep-volumes"
    assert_failure
    [[ "$(cat "${STATE_FILE}")" = "${before}" ]] || fail "state file mutated by failing remove"
}

# --- truncated JSON ---------------------------------------------------------

@test "state corruption: truncated JSON — prune fails cleanly, file preserved" {
    # Mid-write torn JSON (the leading brace and one half-written entry).
    printf '{"feat":{"off' > "${STATE_FILE}"
    local before
    before=$(cat "${STATE_FILE}")
    run oc_run_with_state worktree prune
    assert_failure
    [[ "$(cat "${STATE_FILE}")" = "${before}" ]] || fail "prune rewrote corrupted state"
}

@test "state corruption: truncated JSON — list fails cleanly, file preserved" {
    printf '{"feat":{"off' > "${STATE_FILE}"
    local before
    before=$(cat "${STATE_FILE}")
    run oc_run_with_state worktree list
    [[ "$(cat "${STATE_FILE}")" = "${before}" ]] || fail "list rewrote corrupted state"
}

# --- wrong shape (top-level array) ------------------------------------------

@test "state corruption: top-level array instead of object — add fails, file preserved" {
    # Valid JSON, but the script's state model expects an object keyed by branch.
    echo '["not", "an", "object"]' > "${STATE_FILE}"
    local before
    before=$(cat "${STATE_FILE}")
    run oc_run_with_state worktree add foo -b --env easy
    assert_failure
    [[ "$(cat "${STATE_FILE}")" = "${before}" ]] || fail "state file mutated by failing add"
}

# --- recovery via manual cleanup --------------------------------------------

@test "state corruption: after manual rm of corrupted file, add succeeds with fresh state" {
    printf 'busted\n' > "${STATE_FILE}"
    # Documented recovery: remove the corrupted state file.
    rm -f "${STATE_FILE}"
    run oc_run_with_state worktree add recovered -b --env easy
    assert_success
    [[ "$(jq -r 'has("recovered")' "${STATE_FILE}")" = "true" ]] \
        || fail "state entry missing after manual-recovery + add"
}
