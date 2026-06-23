# Golden artifacts for `openemr-cmd worktree add` tests

These files are checked-in snapshots of the artifacts that
`cmd_worktree_add` writes (`.env`, `docker-compose.override.yml`,
`.worktrees.json`). The tests in `../worktree_add_goldens.bats` generate
each artifact, mask runtime-variable paths, and diff against the
corresponding golden here. Any drift in the artifact's shape — whitespace,
ordering, header comments, line counts — fails the test.

## Layout

```
goldens/
  <env>/                     # easy | easy-light | easy-redis
    env                      # compose .env file at offset 1
    override.yml             # docker-compose.override.yml at offset 1
  easy/
    env-offset-2             # .env at offset 2 (port-arithmetic check)
  state/
    single-easy.json         # .worktrees.json after one `add`
```

The fixed branch names used by the tests (`golden-easy`,
`golden-easy-light`, `golden-easy-redis`, `golden-easy-offset2`,
`prior`) make the override files' branch-scoped volume + container names
deterministic.

## Masked paths

Anything matching `/tmp/openemr-cmd-XXXXXX` is rewritten to
`__TMP_PARENT__` before diff. Everything inside that prefix is stable
(`primary/.git`, `openemr-wt-<slug>/...`).

## Regenerating

After an intentional change to `wt_write_env` / `wt_write_override` /
`wt_state_set`, re-bless the goldens:

```sh
UPDATE_GOLDENS=1 bats tests/bats/openemr-cmd/worktree_add_goldens.bats
```

Inspect `git diff tests/bats/openemr-cmd/goldens/` before committing —
bless mode trusts whatever the script currently emits.
