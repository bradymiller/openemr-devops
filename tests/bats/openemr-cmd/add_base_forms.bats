# BATS: cmd_worktree_add --base form-by-form coverage of wt_resolve_base.
#
# wt_resolve_base recognizes URLs (http/git/ssh/file://) and forwards to
# wt_fetch_to_sha; everything else is treated as a local git ref and
# resolved via `git rev-parse --verify <arg>^{commit}`. The local path
# covers branches, tags, SHAs, and remote-tracking refs. The default
# canonical-fetch path (-b without --base) is covered in worktree_misc;
# this file pins the --base matrix end-to-end.

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

    # The fixture init creates ONE commit on master. Add a second commit
    # so we have at least two distinct SHAs to point --base at.
    echo "extra-content" > "${TMP_ROOT}/EXTRA.txt"
    git -C "${TMP_ROOT}" add EXTRA.txt
    git -C "${TMP_ROOT}" commit --quiet -m "second commit"
    MASTER_TIP=$(git -C "${TMP_ROOT}" rev-parse HEAD)
    MASTER_PREV=$(git -C "${TMP_ROOT}" rev-parse HEAD~1)
    # Tag the previous commit. -m + GIT_*_NAME/EMAIL avoid the "no tag
    # message" failure that hits when the local git config has
    # tag.gpgSign or tag.forceSignAnnotated set.
    GIT_AUTHOR_NAME=bats GIT_AUTHOR_EMAIL=bats@example.com \
    GIT_COMMITTER_NAME=bats GIT_COMMITTER_EMAIL=bats@example.com \
        git -C "${TMP_ROOT}" -c tag.gpgSign=false \
            tag -a -m "fixture tag" fixture-tag "${MASTER_PREV}"

    # Set up a second repo that the primary can fetch from as 'origin' or
    # via a file:// URL. Cloning preserves history.
    SECOND_ROOT="${TMP_PARENT}/second"
    git clone --quiet --no-local "${TMP_ROOT}" "${SECOND_ROOT}"
    # Give 'second' a uniquely-named branch so we can fetch it as
    # second/distinct-branch from primary.
    git -C "${SECOND_ROOT}" checkout --quiet -b distinct-branch
    echo "second-only" > "${SECOND_ROOT}/SECOND.txt"
    git -C "${SECOND_ROOT}" add SECOND.txt
    git -C "${SECOND_ROOT}" -c user.email=bats@e.com -c user.name=bats \
        -c commit.gpgsign=false commit --quiet -m "second-only commit"
    SECOND_DISTINCT_TIP=$(git -C "${SECOND_ROOT}" rev-parse HEAD)

    # Register 'second' as a remote of primary, and fetch so remote-tracking
    # refs (refs/remotes/second/*) exist locally for wt_resolve_base to find.
    git -C "${TMP_ROOT}" remote add second "${SECOND_ROOT}"
    git -C "${TMP_ROOT}" fetch --quiet second

    STUB_DIR=$(oc_make_docker_stub_dir)
    STATE_FILE="${TMP_ROOT}/.worktrees.json"
    export TMP_PARENT TMP_ROOT SECOND_ROOT STUB_DIR STATE_FILE \
           MASTER_TIP MASTER_PREV SECOND_DISTINCT_TIP
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
        WT_STATE_LOCK_TIMEOUT_S=5 \
        "${SCRIPT}" worktree add "$@"
}

# Assert the worktree's HEAD matches the expected SHA.
assert_worktree_head() {
    local branch=$1 expected=$2
    local wt_dir="${TMP_PARENT}/openemr-wt-${branch}"
    local actual
    actual=$(git -C "${wt_dir}" rev-parse HEAD)
    [[ "${actual}" = "${expected}" ]] \
        || fail "worktree '${branch}' HEAD is ${actual}, expected ${expected}"
}

# --- local refs (wt_resolve_base local-rev-parse branch) -------------------

@test "--base <local-branch>: works (resolves 'master' via rev-parse)" {
    oc_add base-local-branch -b --base master --env easy >/dev/null
    assert_worktree_head base-local-branch "${MASTER_TIP}"
}

@test "--base <tag>: works (resolves an annotated/lightweight tag via rev-parse)" {
    oc_add base-tag -b --base fixture-tag --env easy >/dev/null
    assert_worktree_head base-tag "${MASTER_PREV}"
}

@test "--base <SHA>: works (resolves a full SHA via rev-parse)" {
    oc_add base-sha -b --base "${MASTER_PREV}" --env easy >/dev/null
    assert_worktree_head base-sha "${MASTER_PREV}"
}

@test "--base <short-SHA>: works (rev-parse expands abbreviated SHAs)" {
    local short="${MASTER_PREV:0:8}"
    oc_add base-short-sha -b --base "${short}" --env easy >/dev/null
    assert_worktree_head base-short-sha "${MASTER_PREV}"
}

@test "--base <remote/branch>: works (resolves refs/remotes/<remote>/<branch>)" {
    oc_add base-remote -b --base second/distinct-branch --env easy >/dev/null
    assert_worktree_head base-remote "${SECOND_DISTINCT_TIP}"
}

# --- URL forms (wt_resolve_base URL branch → wt_fetch_to_sha) --------------

@test "--base file://<url> (no #ref): fetches master from the URL" {
    oc_add base-url-default -b --base "file://${SECOND_ROOT}" --env easy >/dev/null
    # 'second' has its own master branch (from the clone), which still
    # points at the primary's master tip pre-distinct-branch — i.e. the
    # second commit we made. distinct-branch is separate.
    local second_master
    second_master=$(git -C "${SECOND_ROOT}" rev-parse master)
    assert_worktree_head base-url-default "${second_master}"
}

@test "--base file://<url>#<branch>: fetches the named ref from the URL" {
    oc_add base-url-ref -b --base "file://${SECOND_ROOT}#distinct-branch" --env easy >/dev/null
    assert_worktree_head base-url-ref "${SECOND_DISTINCT_TIP}"
}

# --- error paths -----------------------------------------------------------

@test "--base <nonexistent-ref>: dies with a hint about using --base <URL>#<ref>" {
    run oc_add base-bogus -b --base no-such-ref-anywhere --env easy
    assert_failure
    assert_output --partial "does not resolve as a local git ref"
    assert_output --partial "to fetch"
    # No half-built state.
    if [[ -f "${STATE_FILE}" ]]; then
        [[ "$(jq -r 'has("base-bogus")' "${STATE_FILE}")" = "false" ]] \
            || fail "bogus-base branch was written to state"
    fi
    [[ ! -d "${TMP_PARENT}/openemr-wt-base-bogus" ]] \
        || fail "bogus-base worktree dir was created"
}

@test "--base requires a value (--base with no following arg dies)" {
    # --base must be last; otherwise the next arg gets consumed as the value.
    run oc_add base-empty -b --env easy --base
    assert_failure
    assert_output --partial "--base requires a value"
}

@test "--base only applies with -b (without -b, --base is rejected)" {
    run oc_add base-without-b --base master --env easy
    assert_failure
    assert_output --partial "--base only applies with -b"
}
