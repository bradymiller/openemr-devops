# BATS: small but high-leverage assertions that don't fit the per-command
# files cleanly.
#
# Covered:
#   - WT_CANONICAL_URL env override is actually consulted on the default -b
#     fetch path (not hardcoded to the github URL)
#   - wt_compose_cmd loads docker-compose.yml + override.yml from the
#     WORKTREE'S checkout, not from the primary repo. The script's own
#     security note says "don't run against untrusted branches" because of
#     this; pin the contract so a future refactor can't silently change it.

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
    export TMP_PARENT TMP_ROOT STUB_DIR
}

teardown() {
    [[ -n "${TMP_PARENT:-}" ]] && rm -rf "${TMP_PARENT}"
    [[ -n "${STUB_DIR:-}" ]] && rm -rf "${STUB_DIR}"
    return 0
}

# --- WT_CANONICAL_URL env override ------------------------------------------

@test "WT_CANONICAL_URL: default -b path actually fetches from the override URL" {
    # Point WT_CANONICAL_URL at a deliberately broken URL; the default -b
    # path (no --base) calls wt_fetch_to_sha with WT_CANONICAL_URL, so the
    # fetch fails and the error message names the override URL — proving
    # the env var is being consulted (and not silently falling back to the
    # github.com canonical).
    local bogus="file:///nonexistent/canonical-url-override-test.git"
    run env \
        PATH="${STUB_DIR}:${PATH}" \
        OPENEMR_ROOT="${TMP_ROOT}" \
        WORKTREE_PARENT="${TMP_PARENT}" \
        WT_CANONICAL_URL="${bogus}" \
        "${SCRIPT}" worktree add canon-override -b
    assert_failure
    # The default-path wt_info is hardcoded ("from openemr/openemr (canonical)")
    # so it doesn't echo the URL; the fetch-failure wt_die DOES interpolate
    # ${WT_CANONICAL_URL}, which is what proves the override took effect.
    assert_output --partial "Failed to fetch master from ${bogus}"
    # The github.com URL should NOT appear anywhere in the output: a
    # regression that ignored the env var would show the default URL here.
    refute_output --partial "github.com/openemr/openemr.git"
}

# --- wt_compose_cmd source-of-compose-file ----------------------------------

@test "wt_compose_cmd: -f paths point at the WORKTREE's checkout, NOT the primary repo" {
    # Set up a worktree, then trigger a compose invocation (via worktree up)
    # and assert the recorded docker compose call has both -f args pointing
    # under the worktree dir. A regression that loaded the base compose
    # from OPENEMR_ROOT instead would fail this.
    local wt_dir="${TMP_PARENT}/openemr-wt-source-check"
    run env \
        PATH="${STUB_DIR}:${PATH}" \
        OPENEMR_ROOT="${TMP_ROOT}" \
        WORKTREE_PARENT="${TMP_PARENT}" \
        WT_CANONICAL_URL="file://${TMP_ROOT}" \
        "${SCRIPT}" worktree add source-check -b
    assert_success
    : > "${STUB_DIR}/docker.log"

    run env \
        PATH="${STUB_DIR}:${PATH}" \
        OPENEMR_ROOT="${TMP_ROOT}" \
        WORKTREE_PARENT="${TMP_PARENT}" \
        "${SCRIPT}" worktree up source-check
    assert_success

    local line
    line=$(grep -F -e "compose " "${STUB_DIR}/docker.log" | grep -F -e "-p openemr-source-check" | head -1)
    [[ -n "${line}" ]] || { cat "${STUB_DIR}/docker.log"; fail "no compose invocation"; }

    # Both -f args MUST reference the worktree dir...
    [[ "${line}" == *"-f ${wt_dir}/docker/development-easy/docker-compose.yml"* ]] \
        || fail "base compose not loaded from worktree dir: ${line}"
    [[ "${line}" == *"-f ${wt_dir}/docker/development-easy/docker-compose.override.yml"* ]] \
        || fail "override not loaded from worktree dir: ${line}"

    # ...and NEITHER may reference the primary repo's docker/development-easy.
    # This is the "don't run against untrusted branches" security note: if
    # the override ever shifted to loading the primary's compose, a
    # malicious branch's compose file would no longer be the one running.
    [[ "${line}" != *"-f ${TMP_ROOT}/docker/development-easy/docker-compose.yml"* ]] \
        || fail "compose was loaded from PRIMARY repo (not worktree): ${line}"
}
