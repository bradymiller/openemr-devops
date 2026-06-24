# BATS: 'openemr-cmd worktree list' status split + two-message footer.
#
# Context: PR #766 split the old single "missing" status into three:
#   missing  — dir gone from disk (prunable)
#   partial  — dir intact + registered as git worktree, compose files gone
#              (regen-able — NOT prunable)
#   invalid  — wt_validate_dir_safe rejects for other reasons (prunable)
#
# The list footer now emits up to TWO independent advisories:
#   - "(N stale state entries ...prune... left intact)"  for missing+invalid
#   - "(N entries have missing compose files ...regen...)" for partial
#
# These tests pin the row status text AND the footer behavior so a future
# refactor cannot silently re-merge the three statuses or drop the regen
# advisory.

load '../test_helper/bats-support/load'
load '../test_helper/bats-assert/load'
load 'helpers'

setup() {
    SCRIPT="$(oc_script_path)"
    [[ -x "$SCRIPT" ]] || skip "openemr-cmd script not found"
    command -v jq >/dev/null 2>&1 || skip "jq not installed"

    TMP_WT_PARENT=$(oc_mktempdir)
    TMP_OPENEMR_ROOT="${TMP_WT_PARENT}/repo"
    mkdir -p "${TMP_OPENEMR_ROOT}"
    STUB_DIR=$(oc_make_docker_stub_dir)
    STATE_FILE="${TMP_OPENEMR_ROOT}/.worktrees.json"

    oc_init_repo "${TMP_OPENEMR_ROOT}"
}

teardown() {
    [[ -n "${TMP_WT_PARENT:-}" ]] && rm -rf "${TMP_WT_PARENT}"
    [[ -n "${STUB_DIR:-}" ]]      && rm -rf "${STUB_DIR}"
}

oc_run_list() {
    run env \
        PATH="${STUB_DIR}:$PATH" \
        OPENEMR_ROOT="${TMP_OPENEMR_ROOT}" \
        WORKTREE_PARENT="${TMP_WT_PARENT}" \
        "$SCRIPT" worktree list
}

# --- partial: regen footer, NOT prune footer --------------------------------

@test "list partial entry: row shows 'partial', emits regen footer only (no prune footer)" {
    # A 'partial' fixture: dir exists, is a registered git worktree, but
    # the docker/development-easy/.env and docker-compose.override.yml
    # files are absent.
    local wt_dir
    wt_dir=$(oc_add_registered_worktree "${TMP_OPENEMR_ROOT}" "${TMP_WT_PARENT}" "feature/partial")
    cat > "${STATE_FILE}" <<JSON
{
  "feature/partial": {"offset": 1, "dir": "${wt_dir}", "env": "easy"}
}
JSON

    oc_run_list
    assert_success
    # Row's STATUS column should be 'partial'.
    echo "$output" | grep -E '^feature/partial[[:space:]]+easy[[:space:]]+1[[:space:]]+partial[[:space:]]' \
        || fail "expected 'feature/partial easy 1 partial' row not found in output"
    # Regen footer present.
    assert_output --partial 'entries have missing compose files'
    assert_output --partial 'openemr-cmd worktree regen'
    # Prune footer must NOT be present — partial entries are not prunable.
    refute_output --partial 'stale state entries'
}

# --- missing: prune footer (with 'left intact' note), NOT regen footer ------

@test "list missing entry: row shows 'missing', emits prune footer with 'left intact' note" {
    cat > "${STATE_FILE}" <<JSON
{
  "feature/missing": {"offset": 1, "dir": "${TMP_WT_PARENT}/gone", "env": "easy"}
}
JSON

    oc_run_list
    assert_success
    echo "$output" | grep -E '^feature/missing[[:space:]]+easy[[:space:]]+1[[:space:]]+missing[[:space:]]' \
        || fail "expected 'feature/missing easy 1 missing' row not found in output"
    # Prune footer text + the explicit 'directories on disk are left intact'
    # note that distinguishes prune-state from a destructive 'rm'.
    assert_output --partial 'stale state entries'
    assert_output --partial 'directories on disk are left intact'
    # Regen footer must NOT appear: no partial entries here.
    refute_output --partial 'missing compose files'
}

# --- both: both footers, each with count 1 ----------------------------------

@test "list one missing + one partial: BOTH footers, each with count 1" {
    local wt_partial
    wt_partial=$(oc_add_registered_worktree "${TMP_OPENEMR_ROOT}" "${TMP_WT_PARENT}" "feature/partial")
    cat > "${STATE_FILE}" <<JSON
{
  "feature/missing": {"offset": 1, "dir": "${TMP_WT_PARENT}/gone", "env": "easy"},
  "feature/partial": {"offset": 2, "dir": "${wt_partial}",         "env": "easy"}
}
JSON

    oc_run_list
    assert_success
    # Both rows present with the right status.
    echo "$output" | grep -E '^feature/missing[[:space:]]+easy[[:space:]]+1[[:space:]]+missing[[:space:]]' \
        || fail "expected 'feature/missing ... missing' row not found"
    echo "$output" | grep -E '^feature/partial[[:space:]]+easy[[:space:]]+2[[:space:]]+partial[[:space:]]' \
        || fail "expected 'feature/partial ... partial' row not found"
    # Prune footer present with count 1.
    assert_output --partial '(1 stale state entries'
    # Regen footer present with count 1.
    assert_output --partial '(1 entries have missing compose files'
}

# --- running / stopped / none statuses --------------------------------------
# These require a "valid" fixture: registered git worktree + compose files
# present + wt_validate_dir_safe passing. The script then probes docker for
# running/stopped state. The recording stub's DOCKER_PS_OUTPUT controls what
# `docker compose ... ps ...` returns.
#
# Status decision in cmd_worktree_list:
#   running -> ps --services --filter status=running output contains "openemr"
#   stopped -> running output does NOT contain "openemr", but `ps -aq` is non-empty
#   none    -> both probes return empty

# Build a valid-looking worktree: registered + compose files present.
make_valid_worktree() {
    local branch=$1
    local wt_dir
    wt_dir=$(oc_add_registered_worktree "${TMP_OPENEMR_ROOT}" "${TMP_WT_PARENT}" "${branch}")
    mkdir -p "${wt_dir}/docker/development-easy"
    : > "${wt_dir}/docker/development-easy/.env"
    : > "${wt_dir}/docker/development-easy/docker-compose.override.yml"
    : > "${wt_dir}/docker/development-easy/docker-compose.yml"
    echo "${wt_dir}"
}

oc_run_list_with_ps() {
    local ps_out=$1
    run env \
        PATH="${STUB_DIR}:$PATH" \
        OPENEMR_ROOT="${TMP_OPENEMR_ROOT}" \
        WORKTREE_PARENT="${TMP_WT_PARENT}" \
        DOCKER_PS_OUTPUT="${ps_out}" \
        "$SCRIPT" worktree list
}

@test "list running entry: docker ps returns 'openemr' service, row shows 'running'" {
    local wt
    wt=$(make_valid_worktree "feature/running")
    cat > "${STATE_FILE}" <<JSON
{
  "feature/running": {"offset": 1, "dir": "${wt}", "env": "easy"}
}
JSON
    oc_run_list_with_ps "openemr"
    assert_success
    echo "$output" | grep -E '^feature/running[[:space:]]+easy[[:space:]]+1[[:space:]]+running[[:space:]]' \
        || { echo "$output"; fail "expected 'feature/running ... running' row not found"; }
    # No advisory footers — this is a clean running entry.
    refute_output --partial 'stale state entries'
    refute_output --partial 'missing compose files'
}

@test "list stopped entry: docker ps -aq non-empty + no running 'openemr' service, row shows 'stopped'" {
    local wt
    wt=$(make_valid_worktree "feature/stopped")
    cat > "${STATE_FILE}" <<JSON
{
  "feature/stopped": {"offset": 1, "dir": "${wt}", "env": "easy"}
}
JSON
    # DOCKER_PS_OUTPUT="abc123" — first call (ps --services --filter
    # status=running) returns "abc123" which doesn't match grep -q openemr,
    # so the script falls into the second probe (ps -aq). That returns
    # "abc123" too which is non-empty → status='stopped'.
    oc_run_list_with_ps "abc123"
    assert_success
    echo "$output" | grep -E '^feature/stopped[[:space:]]+easy[[:space:]]+1[[:space:]]+stopped[[:space:]]' \
        || { echo "$output"; fail "expected 'feature/stopped ... stopped' row not found"; }
}

@test "list 'none' status: both ps probes return empty, row shows 'none'" {
    local wt
    wt=$(make_valid_worktree "feature/none")
    cat > "${STATE_FILE}" <<JSON
{
  "feature/none": {"offset": 1, "dir": "${wt}", "env": "easy"}
}
JSON
    # DOCKER_PS_OUTPUT unset/empty (default) → both probes return empty
    # → status stays 'none' (the initial value before either if-branch fires).
    oc_run_list_with_ps ""
    assert_success
    echo "$output" | grep -E '^feature/none[[:space:]]+easy[[:space:]]+1[[:space:]]+none[[:space:]]' \
        || { echo "$output"; fail "expected 'feature/none ... none' row not found"; }
}
