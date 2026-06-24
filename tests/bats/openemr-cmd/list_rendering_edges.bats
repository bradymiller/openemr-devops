# BATS: cmd_worktree_list rendering for state entries with awkward
# characters. The list path walks state via `jq | @tsv` + read -r, then
# printf-aligns columns. Pathological-but-possible state entries should
# render without crashing or breaking out of the printf format.

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

oc_list() {
    env \
        PATH="${STUB_DIR}:${PATH}" \
        OPENEMR_ROOT="${TMP_ROOT}" \
        WORKTREE_PARENT="${TMP_PARENT}" \
        "${SCRIPT}" worktree list
}

# --- unicode in branch name -------------------------------------------------

@test "list: unicode branch name renders without crashing" {
    cat > "${STATE_FILE}" <<JSON
{
  "feature/résumé": {"offset": 1, "dir": "${TMP_PARENT}/openemr-wt-feature-rsum", "env": "easy"},
  "feature/日本語": {"offset": 2, "dir": "${TMP_PARENT}/openemr-wt-feature-",     "env": "easy-light"}
}
JSON
    run oc_list
    assert_success
    # Both entries appear in output. The branch column may be width-truncated
    # by printf when the multi-byte char count exceeds 30 — we just check
    # the branch name strings are present somewhere in the output.
    assert_output --partial "feature/résumé"
    assert_output --partial "feature/日本語"
}

# --- dir path with spaces ---------------------------------------------------

@test "list: dir path containing spaces renders intact (no field splitting)" {
    local spaced_parent="${TMP_PARENT}/has spaces"
    mkdir -p "${spaced_parent}/openemr-wt-spaced"
    cat > "${STATE_FILE}" <<JSON
{
  "feature/spaced": {"offset": 1, "dir": "${spaced_parent}/openemr-wt-spaced", "env": "easy"}
}
JSON
    run oc_list
    assert_success
    # The full path (with the space) should appear verbatim in output.
    assert_output --partial "${spaced_parent}/openemr-wt-spaced"
    # And the branch name should still be present.
    assert_output --partial "feature/spaced"
}

# --- very long branch name --------------------------------------------------

@test "list: very long branch name does not break formatting" {
    local long
    long=$(printf 'b%.0s' {1..200})
    cat > "${STATE_FILE}" <<JSON
{
  "${long}": {"offset": 1, "dir": "${TMP_PARENT}/openemr-wt-${long}", "env": "easy"}
}
JSON
    run oc_list
    assert_success
    # printf "%-30s" left-pads, doesn't truncate. The long name should
    # appear in full somewhere in the output.
    assert_output --partial "${long}"
}

# --- many entries -----------------------------------------------------------

@test "list: 25 entries all render in a single pass" {
    # Build a state file with 25 entries. None of the dirs exist, so they
    # all show as 'missing' — that's fine, we're testing the iteration
    # path, not the status detection.
    local entries=""
    local i
    for i in $(seq 1 25); do
        if [[ -n "${entries}" ]]; then entries="${entries},"; fi
        entries="${entries}\"branch-${i}\":{\"offset\":${i},\"dir\":\"${TMP_PARENT}/gone-${i}\",\"env\":\"easy\"}"
    done
    echo "{${entries}}" > "${STATE_FILE}"

    run oc_list
    assert_success
    assert_output --partial "branch-1"
    assert_output --partial "branch-25"
    # Stale-count hint mentions the right total.
    assert_output --partial "(25 stale state entries"
}
