# BATS: maria-shell (ms) — opens a shell in the mariadb container, NOT
# the openemr container. This is one of the few subcommands that uses
# MARIADB_CONTAINER_ID instead of CONTAINER_ID, so it exercises the
# multi-container resolution path.
#
# MARIADB resolution (script lines ~1983-1995):
#   1. Label-based via `docker ps --filter label=com.docker.compose.project=<X>
#      --filter label=com.docker.compose.service=mysql` (when CONTAINER_ID
#      is set, attempt project-scoped lookup first)
#   2. Fallback: `docker ps --filter name=${MARIADB_DOCKER}` (mysql[_\-]1)
#
# Our docker stub treats all `ps --filter name=...` queries the same
# (returning DOCKER_PS_OUTPUT), which is sufficient to exercise the
# fallback path. The label-based path is skipped because our stub
# doesn't implement `docker inspect --format ...` (returns empty).

load '../test_helper/bats-support/load'
load '../test_helper/bats-assert/load'
load 'helpers'

setup() {
    SCRIPT="$(oc_script_path)"
    [[ -x "$SCRIPT" ]] || skip "openemr-cmd script not found"
    STUB_DIR=$(oc_make_docker_stub_dir)
    export STUB_DIR
}

teardown() {
    [[ -n "${STUB_DIR:-}" ]] && rm -rf "${STUB_DIR}"
    return 0
}

@test "ms: invokes 'docker exec -it <MARIADB_CONTAINER_ID> /bin/bash'" {
    run env \
        PATH="${STUB_DIR}:${PATH}" \
        DOCKER_PS_OUTPUT="mariadb-resolved-id" \
        "${SCRIPT}" -d openemr-target ms
    assert_success
    # The exec target uses the mariadb id (from DOCKER_PS_OUTPUT), not the -d
    # openemr-target. Pinning that ms uses MARIADB_CONTAINER_ID, not
    # CONTAINER_ID.
    grep -Eq 'exec -it mariadb-resolved-id /bin/bash' "${STUB_DIR}/docker.log" \
        || { cat "${STUB_DIR}/docker.log"; fail "expected 'exec -it mariadb-resolved-id /bin/bash'"; }
}

@test "ms: 'maria-shell' long form is equivalent" {
    run env \
        PATH="${STUB_DIR}:${PATH}" \
        DOCKER_PS_OUTPUT="mariadb-id" \
        "${SCRIPT}" -d openemr-target maria-shell
    assert_success
    grep -Eq 'exec -it mariadb-id /bin/bash' "${STUB_DIR}/docker.log" \
        || fail "long form did not invoke 'docker exec -it mariadb-id /bin/bash'"
}

@test "ms: docker ps --filter for mariadb name pattern is issued during resolution" {
    # Confirm the mariadb-specific resolution actually runs (proves the
    # script isn't accidentally re-using the openemr CONTAINER_ID).
    run env \
        PATH="${STUB_DIR}:${PATH}" \
        DOCKER_PS_OUTPUT="ignored-here" \
        "${SCRIPT}" -d openemr-target ms
    assert_success
    grep -Eq 'ps --filter name=mysql' "${STUB_DIR}/docker.log" \
        || { cat "${STUB_DIR}/docker.log"; fail "expected 'ps --filter name=mysql...' query"; }
}
