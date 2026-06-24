# BATS: prek-install / prek-uninstall dispatch.
#
# These commands manage host-side git hooks (.git/hooks/{pre-commit,
# commit-msg}) — they must NOT route through a container. The script
# has two arrangements that enforce this:
#
#   1. Early dispatch (line ~1761/1766) before the -d parsing: when
#      FIRST_ARG is 'pi'/'prek-install'/'pu'/'prek-uninstall', call
#      cmd_prek_install / cmd_prek_uninstall and exit. The short-circuit
#      bypasses container detection entirely.
#
#   2. Safeguard at the end (case at ~2290): if those subcommands somehow
#      reach the main dispatch (which only happens when invoked via
#      `-d <container> pi` — the -d parser shifts past `-d <id>` to set
#      FIRST_ARG=pi, so the early dispatch is skipped), abort with a
#      "host-only command" error. Also covers `worktree exec <branch> pi`,
#      which re-execs as `openemr-cmd -d <container_id> pi`.

load '../test_helper/bats-support/load'
load '../test_helper/bats-assert/load'
load 'helpers'

setup() {
    SCRIPT="$(oc_script_path)"
    [[ -x "$SCRIPT" ]] || skip "openemr-cmd script not found"
    STUB_DIR=$(oc_make_docker_stub_dir)
    TMP_REPO=$(oc_mktempdir)
    oc_init_repo "${TMP_REPO}"
    export STUB_DIR TMP_REPO
}

teardown() {
    [[ -n "${STUB_DIR:-}" ]] && rm -rf "${STUB_DIR}"
    [[ -n "${TMP_REPO:-}" ]] && rm -rf "${TMP_REPO}"
    return 0
}

# --- early-dispatch happy path: pi from inside a real git repo --------------

@test "prek-install: pi (short form) writes pre-commit + commit-msg hooks in .git/hooks/" {
    pushd "${TMP_REPO}" >/dev/null
    run env PATH="${STUB_DIR}:${PATH}" "${SCRIPT}" pi
    local rc=$?
    popd >/dev/null
    [[ "${rc}" -eq 0 ]] || { echo "${output}"; fail "pi exited ${rc}"; }
    [[ "$status" -eq 0 ]] || fail "expected success"
    [[ -f "${TMP_REPO}/.git/hooks/pre-commit" ]] || fail "pre-commit hook not written"
    [[ -f "${TMP_REPO}/.git/hooks/commit-msg" ]] || fail "commit-msg hook not written"
    # Hook contents reference openemr-cmd (the absolute path the install resolved).
    grep -Fq "openemr-cmd" "${TMP_REPO}/.git/hooks/pre-commit" \
        || { cat "${TMP_REPO}/.git/hooks/pre-commit"; fail "pre-commit hook does not invoke openemr-cmd"; }
    assert_output --partial "Installed openemr-cmd-managed git hooks"
}

@test "prek-install: prek-install (long form) is equivalent to pi" {
    pushd "${TMP_REPO}" >/dev/null
    run env PATH="${STUB_DIR}:${PATH}" "${SCRIPT}" prek-install
    popd >/dev/null
    assert_success
    [[ -f "${TMP_REPO}/.git/hooks/pre-commit" ]] || fail "pre-commit hook not written"
    [[ -f "${TMP_REPO}/.git/hooks/commit-msg" ]] || fail "commit-msg hook not written"
}

# --- early-dispatch outside a git repo ------------------------------------

@test "prek-install: outside a git repo, fails with 'not in a git repository'" {
    local non_repo
    non_repo=$(oc_mktempdir)
    pushd "${non_repo}" >/dev/null
    run env PATH="${STUB_DIR}:${PATH}" "${SCRIPT}" pi
    popd >/dev/null
    rm -rf "${non_repo}"
    assert_failure
    assert_output --partial "not in a git repository"
}

# --- safeguard: pi via -d (host-only refusal) -----------------------------

@test "prek-install safeguard: 'openemr-cmd -d <id> pi' refuses with host-only error" {
    # The early dispatch is bypassed (FIRST_ARG='-d', not 'pi'), so we
    # reach the case at ~2290. Exits 1 with the host-only message.
    run env PATH="${STUB_DIR}:${PATH}" "${SCRIPT}" -d some-container pi
    assert_failure
    assert_output --partial "host-only command"
    assert_output --partial "writes git hooks to host filesystem"
    assert_output --partial "Run directly on the host"
    # And critically: no docker exec was issued (would route a host-only
    # cmd into a container).
    if grep -Eq '^exec |\sexec\s' "${STUB_DIR}/docker.log" 2>/dev/null; then
        cat "${STUB_DIR}/docker.log"
        fail "safeguard fired but a docker exec was still issued"
    fi
}

@test "prek-install safeguard: long form 'prek-install' via -d also refuses" {
    run env PATH="${STUB_DIR}:${PATH}" "${SCRIPT}" -d some-container prek-install
    assert_failure
    assert_output --partial "host-only command"
}

@test "prek-uninstall safeguard: 'openemr-cmd -d <id> pu' refuses with host-only error" {
    run env PATH="${STUB_DIR}:${PATH}" "${SCRIPT}" -d some-container pu
    assert_failure
    assert_output --partial "host-only command"
}

@test "prek-uninstall safeguard: long form 'prek-uninstall' via -d also refuses" {
    run env PATH="${STUB_DIR}:${PATH}" "${SCRIPT}" -d some-container prek-uninstall
    assert_failure
    assert_output --partial "host-only command"
}

# --- prek-uninstall happy path (clean teardown) ---------------------------

@test "prek-uninstall: removes hooks that pi installed; safe when no hooks exist" {
    pushd "${TMP_REPO}" >/dev/null
    env PATH="${STUB_DIR}:${PATH}" "${SCRIPT}" pi >/dev/null
    [[ -f "${TMP_REPO}/.git/hooks/pre-commit" ]] || fail "fixture install failed"
    run env PATH="${STUB_DIR}:${PATH}" "${SCRIPT}" pu
    popd >/dev/null
    assert_success
    # Hooks gone after uninstall.
    [[ ! -f "${TMP_REPO}/.git/hooks/pre-commit" ]] || fail "pre-commit hook not removed"
    [[ ! -f "${TMP_REPO}/.git/hooks/commit-msg" ]] || fail "commit-msg hook not removed"
    # Idempotent: a second uninstall succeeds (nothing to remove).
    pushd "${TMP_REPO}" >/dev/null
    run env PATH="${STUB_DIR}:${PATH}" "${SCRIPT}" pu
    popd >/dev/null
    assert_success
}
