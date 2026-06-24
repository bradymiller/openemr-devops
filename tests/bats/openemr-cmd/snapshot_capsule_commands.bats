# BATS: snapshot + capsule commands — bs / rs / gc / pc.
#
# These dispatch to either run_devtools_in_docker (bs, rs → /root/devtools
# backup|restore <name>) or docker cp directly (gc/pc copy capsule files
# in/out of /snapshots/ in the container). Each command has a no-arg
# usage hint with a specific exit code; this file pins both the dispatch
# shape and the usage-exit-code contract.
#
# All four functions originally had the same set-u bug as ensure-version
# (#829's ev fix): `local FOO="$1"` fired before the `$# != 1` check,
# crashing with "unbound variable" instead of showing the help. Fixed
# concurrently with this file; the no-arg tests pin the fix.

load '../test_helper/bats-support/load'
load '../test_helper/bats-assert/load'
load 'helpers'

setup() {
    SCRIPT="$(oc_script_path)"
    [[ -x "$SCRIPT" ]] || skip "openemr-cmd script not found"
    STUB_DIR=$(oc_make_docker_stub_dir)
    CONTAINER=fixed-snapshot-target
    export STUB_DIR CONTAINER
}

teardown() {
    [[ -n "${STUB_DIR:-}" ]] && rm -rf "${STUB_DIR}"
    return 0
}

oc_run() {
    env PATH="${STUB_DIR}:${PATH}" "${SCRIPT}" -d "${CONTAINER}" "$@"
}

# --- backup-snapshot / bs --------------------------------------------------

@test "bs <name>: dispatches to /root/devtools backup <name>" {
    run oc_run bs my-snapshot
    assert_success
    grep -Fq "/root/devtools backup my-snapshot" "${STUB_DIR}/docker.log" \
        || { cat "${STUB_DIR}/docker.log"; fail "expected '/root/devtools backup my-snapshot'"; }
    grep -Fq "${CONTAINER}" "${STUB_DIR}/docker.log" || fail "container id missing"
}

@test "bs (no args): prints usage hint and exits 20 (no 'unbound variable' crash)" {
    # Regression for the set-u bug that crashed with "unbound variable"
    # before the user saw the help.
    run oc_run bs
    [[ "${status}" -eq 20 ]] || fail "expected exit 20; got ${status}"
    assert_output --partial "Please provide a snapshot name"
    assert_output --partial "backup-snapshot|bs"
    refute_output --partial "unbound variable"
}

@test "bs: 'backup-snapshot' long form is equivalent to 'bs'" {
    run oc_run backup-snapshot another-snap
    assert_success
    grep -Fq "/root/devtools backup another-snap" "${STUB_DIR}/docker.log" || fail "long form did not dispatch"
}

# --- restore-snapshot / rs -------------------------------------------------

@test "rs <name>: dispatches to /root/devtools restore <name>" {
    run oc_run rs my-restore
    assert_success
    grep -Fq "/root/devtools restore my-restore" "${STUB_DIR}/docker.log" \
        || { cat "${STUB_DIR}/docker.log"; fail "expected '/root/devtools restore my-restore'"; }
}

@test "rs (no args): prints usage hint and exits 21 (no 'unbound variable' crash)" {
    run oc_run rs
    [[ "${status}" -eq 21 ]] || fail "expected exit 21; got ${status}"
    assert_output --partial "Please provide a restore snapshot name"
    assert_output --partial "restore-snapshot|rs"
    refute_output --partial "unbound variable"
}

@test "rs: 'restore-snapshot' long form is equivalent" {
    run oc_run restore-snapshot something
    assert_success
    grep -Fq "/root/devtools restore something" "${STUB_DIR}/docker.log" || fail "long form did not dispatch"
}

# --- get-capsule / gc ------------------------------------------------------

@test "gc <name>: 'docker cp <id>:/snapshots/<name> .'" {
    run oc_run gc example.tgz
    assert_success
    grep -Eq "cp ${CONTAINER}:/snapshots/example\.tgz \.\$" "${STUB_DIR}/docker.log" \
        || { cat "${STUB_DIR}/docker.log"; fail "expected 'docker cp <id>:/snapshots/example.tgz .'"; }
}

@test "gc <name> <host-dir>: 'docker cp <id>:/snapshots/<name> <host-dir>/'" {
    run oc_run gc example.tgz /path/to/save
    assert_success
    grep -Fq "cp ${CONTAINER}:/snapshots/example.tgz /path/to/save/" "${STUB_DIR}/docker.log" \
        || { cat "${STUB_DIR}/docker.log"; fail "expected 'docker cp <id>:/snapshots/example.tgz /path/to/save/'"; }
}

@test "gc (no args): prints usage hint and exits 19 (no 'unbound variable' crash)" {
    run oc_run gc
    [[ "${status}" -eq 19 ]] || fail "expected exit 19; got ${status}"
    assert_output --partial "Please provide the capsule name"
    assert_output --partial "get-capsule|gc"
    refute_output --partial "unbound variable"
}

@test "gc: too many args (3+) also surfaces usage hint" {
    run oc_run gc a b c
    [[ "${status}" -eq 19 ]] || fail "expected exit 19; got ${status}"
    assert_output --partial "Please provide the capsule name"
}

# --- put-capsule / pc ------------------------------------------------------

@test "pc <existing-file>: 'docker cp <file> <id>:/snapshots/'" {
    # pc checks that the file exists before docker cp. Create a real
    # file in the test's cwd so the existence check passes.
    local tmp_cap
    tmp_cap=$(mktemp -p "${BATS_TMPDIR:-/tmp}" pc-cap.XXXXXX.tgz)
    run oc_run pc "${tmp_cap}"
    rm -f "${tmp_cap}"
    assert_success
    # docker cp <file> <id>:/snapshots/
    grep -Fq "cp ${tmp_cap} ${CONTAINER}:/snapshots/" "${STUB_DIR}/docker.log" \
        || { cat "${STUB_DIR}/docker.log"; fail "expected docker cp <file> <id>:/snapshots/"; }
}

@test "pc (no args): prints usage hint and exits 18 (no 'unbound variable' crash)" {
    run oc_run pc
    [[ "${status}" -eq 18 ]] || fail "expected exit 18; got ${status}"
    assert_output --partial "Please provide the capsule file name"
    assert_output --partial "put-capsule|pc"
    refute_output --partial "unbound variable"
}

@test "pc <missing-file>: 'capsule file exists' error, exits 15" {
    run oc_run pc /nonexistent/capsule-bats-test.tgz
    [[ "${status}" -eq 15 ]] || fail "expected exit 15; got ${status}"
    assert_output --partial "Please check whether the capsule file exists or not"
    # And NO docker cp was issued.
    if grep -Fq "cp /nonexistent" "${STUB_DIR}/docker.log"; then
        cat "${STUB_DIR}/docker.log"
        fail "docker cp was issued for a nonexistent file"
    fi
}
