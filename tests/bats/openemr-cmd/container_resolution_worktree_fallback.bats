# BATS: container resolution — worktree-label fallback path.
#
# When neither INSANE_DEV_DOCKER (openemr-8-5[_\-]1) nor EASY_DEV_DOCKER
# (openemr[_\-]1) name filters match, the script falls back to a label-
# based query: `docker ps --filter label=com.docker.compose.service=openemr`,
# then greps for compose-project names starting with "openemr-" and picks
# the first matching container ID. The user sees a "Note: Targeting
# worktree container '<name>'" hint encouraging explicit -d.
#
# This is the path that lets `openemr-cmd <devtool>` work without -d when
# the only running openemr stack is a worktree-managed one (not the
# default 'openemr' or 'openemr-8-5' compose project).
#
# container_resolution.bats covered the auto-detect-found and not-found
# cases; this file fills in the middle case (auto-detect via label
# fallback succeeded).

load '../test_helper/bats-support/load'
load '../test_helper/bats-assert/load'
load 'helpers'

# Stub that branches on the filter args:
#   - --filter name=openemr-8-5... → empty
#   - --filter name=openemr[_\-]1  → empty
#   - --filter label=...service=openemr → "openemr-myworktree\twt-container-id"
#   - --filter id=wt-container-id → "openemr-myworktree-openemr-1" (container name)
#   - --filter name=mysql / couchdb → empty
#   - 'compose' (plugin probe) → 0
oc_make_docker_label_fallback_stub() {
    local d log
    d=$(oc_mktempdir)
    log="${d}/docker.log"
    : > "${log}"
    # Unquoted heredoc so ${log} expands at write time; escape \$@/\$*/\$1
    # so they stay literal in the stub script. Avoids needing `sed -i` later
    # (sed -i is non-portable: GNU accepts no extension arg, BSD/macOS
    # requires one).
    cat > "${d}/docker" <<STUB
#!/bin/sh
echo "\$@" >> "${log}"
args="\$*"
case "\${args}" in
    "compose")
        exit 0
        ;;
    *"--filter label=com.docker.compose.service=openemr"*)
        printf 'openemr-myworktree\twt-container-id\n'
        ;;
    *"--filter id=wt-container-id"*)
        printf 'openemr-myworktree-openemr-1\n'
        ;;
    *"--filter name=openemr-8-5"*|*"--filter name=openemr[_\\\\-]1"*|*"--filter name=couchdb"*|*"--filter name=mysql"*)
        # Empty (no match) — forces the label-fallback path to be exercised.
        ;;
    *)
        # Any other ps / inspect / etc.
        ;;
esac
exit 0
STUB
    chmod +x "${d}/docker"
    echo "${d}"
}

setup() {
    SCRIPT="$(oc_script_path)"
    [[ -x "$SCRIPT" ]] || skip "openemr-cmd script not found"
    STUB_DIR=$(oc_make_docker_label_fallback_stub)
    export STUB_DIR
}

teardown() {
    [[ -n "${STUB_DIR:-}" ]] && rm -rf "${STUB_DIR}"
    return 0
}

@test "worktree-label fallback: when INSANE + EASY name filters miss, the label query picks the worktree container" {
    # No -d. INSANE + EASY return empty. Label fallback returns
    # 'openemr-myworktree\twt-container-id'. Script picks wt-container-id
    # as CONTAINER_ID and prints the "Targeting worktree container" note.
    # Then we dispatch a devtool to confirm wt-container-id is the target.
    run env PATH="${STUB_DIR}:${PATH}" "${SCRIPT}" pst
    assert_success
    assert_output --partial "Note: Targeting worktree container"
    assert_output --partial "openemr-myworktree-openemr-1"
    assert_output --partial "Use -d to specify a different container"
    # The devtool dispatch should have routed to wt-container-id. Grep
    # for the EXEC line specifically — a plain "wt-container-id" match
    # would also hit the `docker ps --filter id=wt-container-id` lookup
    # the script does to fetch the container name for the user-facing
    # note, which doesn't prove the dispatch reached exec.
    grep -Eq 'exec .*wt-container-id.* /root/devtools phpstan' "${STUB_DIR}/docker.log" \
        || { cat "${STUB_DIR}/docker.log"; fail "expected 'exec ... wt-container-id ... /root/devtools phpstan'"; }
}

@test "worktree-label fallback: -d <id> overrides the label-detected container" {
    # Even when the label fallback would have picked wt-container-id, an
    # explicit -d wins. Pinning that the -d override has higher priority
    # than the label-based fallback.
    run env PATH="${STUB_DIR}:${PATH}" "${SCRIPT}" -d explicit-override pst
    assert_success
    # The "Targeting worktree container" note STILL fires (the label
    # fallback ran during initial CONTAINER_ID setup, before -d parsing).
    # But the actual devtool exec target is the -d value.
    grep -Fq "/root/devtools phpstan" "${STUB_DIR}/docker.log" \
        || fail "expected '/root/devtools phpstan'"
    grep -Fq "explicit-override" "${STUB_DIR}/docker.log" \
        || { cat "${STUB_DIR}/docker.log"; fail "expected exec into 'explicit-override'"; }
    # And wt-container-id should NOT appear in any exec line.
    if grep -E '^exec .*wt-container-id|\sexec\s.*wt-container-id' "${STUB_DIR}/docker.log" >/dev/null 2>&1; then
        cat "${STUB_DIR}/docker.log"
        fail "exec routed to label-fallback id despite -d override"
    fi
}
