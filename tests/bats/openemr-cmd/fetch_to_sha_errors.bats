# BATS: wt_fetch_to_sha error paths, surfaced through the canonical
# fetch path of `worktree add -b` (no --base).
#
# wt_fetch_to_sha is reached either via WT_CANONICAL_URL (default -b
# fetch) or via wt_resolve_base when --base looks like a URL. The
# success paths are covered by worktree_misc and add_base_forms; this
# file pins the failure modes.

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

    # An empty-but-valid git repo (no branches, no master) for the
    # "URL reachable, ref not present" scenario.
    EMPTY_ROOT="${TMP_PARENT}/empty-repo"
    mkdir -p "${EMPTY_ROOT}"
    git -C "${EMPTY_ROOT}" init --quiet --bare

    STUB_DIR=$(oc_make_docker_stub_dir)
    STATE_FILE="${TMP_ROOT}/.worktrees.json"
    export TMP_PARENT TMP_ROOT EMPTY_ROOT STUB_DIR STATE_FILE
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
        WT_STATE_LOCK_TIMEOUT_S=5 \
        "$@" \
        "${SCRIPT}" worktree add wt-fetch-fail -b --env easy
}

# --- WT_CANONICAL_URL unreachable ------------------------------------------

@test "fetch: WT_CANONICAL_URL pointing at a nonexistent file:// path dies cleanly" {
    run oc_add WT_CANONICAL_URL="file:///nonexistent/canonical-url-bats-test.git"
    assert_failure
    # The die-message surfaces the URL we tried (already covered in
    # worktree_misc.bats); pin a second time here for the no-half-state
    # part of the contract.
    assert_output --partial "Failed to fetch master"
    assert_output --partial "/nonexistent/canonical-url-bats-test.git"
    # No half-built state or dir.
    if [[ -f "${STATE_FILE}" ]]; then
        [[ "$(jq -r 'has("wt-fetch-fail")' "${STATE_FILE}")" = "false" ]] \
            || fail "state entry written despite fetch failure"
    fi
    [[ ! -d "${TMP_PARENT}/openemr-wt-wt-fetch-fail" ]] \
        || fail "worktree dir created despite fetch failure"
    # Lockfile released by EXIT trap.
    [[ ! -e "${STATE_FILE}.lock" ]] || fail "lockfile lingering"
}

# --- URL reachable but ref absent ------------------------------------------

@test "fetch: URL reachable but ref absent (empty repo has no 'master') dies cleanly" {
    # An empty bare repo: file:// is reachable, but 'master' doesn't exist.
    run oc_add WT_CANONICAL_URL="file://${EMPTY_ROOT}"
    assert_failure
    assert_output --partial "Failed to fetch master"
    assert_output --partial "${EMPTY_ROOT}"
    if [[ -f "${STATE_FILE}" ]]; then
        [[ "$(jq -r 'has("wt-fetch-fail")' "${STATE_FILE}")" = "false" ]] \
            || fail "state entry written despite ref-missing fetch failure"
    fi
}

# --- --base URL form failure paths -----------------------------------------

@test "--base file://<nonexistent>#<ref>: dies cleanly with no half-state" {
    run env \
        PATH="${STUB_DIR}:${PATH}" \
        OPENEMR_ROOT="${TMP_ROOT}" \
        WORKTREE_PARENT="${TMP_PARENT}" \
        "${SCRIPT}" worktree add base-url-bad -b \
            --base "file:///nonexistent/also-bogus.git#master" --env easy
    assert_failure
    assert_output --partial "Failed to resolve --base"
    if [[ -f "${STATE_FILE}" ]]; then
        [[ "$(jq -r 'has("base-url-bad")' "${STATE_FILE}")" = "false" ]] \
            || fail "state entry written despite --base URL failure"
    fi
}

@test "--base file://<reachable>#<nonexistent-ref>: dies cleanly" {
    run env \
        PATH="${STUB_DIR}:${PATH}" \
        OPENEMR_ROOT="${TMP_ROOT}" \
        WORKTREE_PARENT="${TMP_PARENT}" \
        "${SCRIPT}" worktree add base-bad-ref -b \
            --base "file://${EMPTY_ROOT}#no-such-branch" --env easy
    assert_failure
    assert_output --partial "Failed to resolve --base"
}
