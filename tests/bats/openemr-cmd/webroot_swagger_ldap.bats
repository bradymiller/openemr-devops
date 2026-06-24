# BATS: webroot + multisite-swagger + LDAP toggle commands.
#
# cwb / cwo (change-webroot-blank / -openemr): set-webroot runs an in-container
# sed against /etc/apache2/conf.d/openemr.conf, then `docker restart <id>`.
# swtm (set-swagger-to-multisite): passes positional args to
# /root/devtools set-swagger-to-multisite via run_devtools_in_docker.
# el / dld (enable-ldap / disable-ldap): plain devtools passthroughs to
# /root/devtools enable-ldap / disable-ldap.

load '../test_helper/bats-support/load'
load '../test_helper/bats-assert/load'
load 'helpers'

setup() {
    SCRIPT="$(oc_script_path)"
    [[ -x "$SCRIPT" ]] || skip "openemr-cmd script not found"
    STUB_DIR=$(oc_make_docker_stub_dir)
    CONTAINER=fixed-webroot-target
    export STUB_DIR CONTAINER
}

teardown() {
    [[ -n "${STUB_DIR:-}" ]] && rm -rf "${STUB_DIR}"
    return 0
}

oc_run() {
    env PATH="${STUB_DIR}:${PATH}" "${SCRIPT}" -d "${CONTAINER}" "$@"
}

# --- webroot: cwb / cwo ----------------------------------------------------
# Both invoke set-webroot, which (1) runs an in-container sed via
# run_shell_command_in_docker (docker exec -i <id> sh -c "<sed ...>")
# and then (2) docker restart <id>. The sed target string differs by
# direction (blank vs openemr).

@test "cwb (change-webroot-blank): sed to point apache at openemr/, then restart container" {
    run oc_run cwb
    assert_success
    assert_output --partial "changing webroot to blank"
    assert_output --partial "restarting openemr docker"
    # Sed runs inside the container via 'exec -i <id> sh -c ...'.
    grep -Fq "exec -i ${CONTAINER}" "${STUB_DIR}/docker.log" \
        || { cat "${STUB_DIR}/docker.log"; fail "expected 'docker exec -i ${CONTAINER}' invocation"; }
    grep -Fq "DocumentRoot /var/www/localhost/htdocs/openemr" "${STUB_DIR}/docker.log" \
        || { cat "${STUB_DIR}/docker.log"; fail "expected sed to set DocumentRoot to .../openemr"; }
    # docker restart <id> is the final step.
    grep -Fq "restart ${CONTAINER}" "${STUB_DIR}/docker.log" \
        || fail "expected 'docker restart ${CONTAINER}'"
}

@test "cwb: 'change-webroot-blank' long form is equivalent" {
    run oc_run change-webroot-blank
    assert_success
    assert_output --partial "changing webroot to blank"
    grep -Fq "restart ${CONTAINER}" "${STUB_DIR}/docker.log" || fail "long form did not restart"
}

@test "cwo (change-webroot-openemr): sed to set apache root to .../htdocs (blank webroot), then restart" {
    run oc_run cwo
    assert_success
    assert_output --partial "changing webroot to openemr"
    assert_output --partial "restarting openemr docker"
    # The 'openemr' direction strips the /openemr suffix from DocumentRoot.
    grep -Eq 'DocumentRoot /var/www/localhost/htdocs[^/]' "${STUB_DIR}/docker.log" \
        || { cat "${STUB_DIR}/docker.log"; fail "expected sed to set DocumentRoot WITHOUT /openemr suffix"; }
    grep -Fq "restart ${CONTAINER}" "${STUB_DIR}/docker.log" || fail "expected 'docker restart'"
}

@test "cwo: 'change-webroot-openemr' long form is equivalent" {
    run oc_run change-webroot-openemr
    assert_success
    assert_output --partial "changing webroot to openemr"
}

# --- swtm / set-swagger-to-multisite --------------------------------------

@test "swtm <multisite-name>: dispatches to /root/devtools set-swagger-to-multisite <name>" {
    run oc_run swtm my-multisite
    assert_success
    grep -Fq "/root/devtools set-swagger-to-multisite my-multisite" "${STUB_DIR}/docker.log" \
        || { cat "${STUB_DIR}/docker.log"; fail "expected swtm devtool dispatch with arg"; }
}

@test "swtm: 'set-swagger-to-multisite' long form is equivalent" {
    run oc_run set-swagger-to-multisite another-site
    assert_success
    grep -Fq "/root/devtools set-swagger-to-multisite another-site" "${STUB_DIR}/docker.log" \
        || fail "long form did not dispatch"
}

# --- el / dld (enable / disable LDAP) -------------------------------------

@test "el: dispatches to /root/devtools enable-ldap" {
    run oc_run el
    assert_success
    grep -Fq "/root/devtools enable-ldap" "${STUB_DIR}/docker.log" \
        || { cat "${STUB_DIR}/docker.log"; fail "expected '/root/devtools enable-ldap'"; }
    grep -Fq "${CONTAINER}" "${STUB_DIR}/docker.log" || fail "container id missing"
}

@test "dld: dispatches to /root/devtools disable-ldap" {
    run oc_run dld
    assert_success
    grep -Fq "/root/devtools disable-ldap" "${STUB_DIR}/docker.log" \
        || { cat "${STUB_DIR}/docker.log"; fail "expected '/root/devtools disable-ldap'"; }
}
