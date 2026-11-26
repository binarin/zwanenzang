# Reading tickets

```sh
zz sync
zz show ZZ-42
zz list --status todo
zz query --tag example --title parser
zz doc get ZZ-42 plan
```

Read-only commands answer from the clone and do not fetch, so run `sync` first
when current state matters. `list` returns summaries; `query` takes more
filters and returns full tickets, as `show` does.

Ticket objects expose `depends_on` (prerequisites) and the reverse `blocks` as
stable ticket ids. `priority` is a native Org value or null; null uses the
tracker's default for ranking but stays unset, and `read` exposes the
configured range and default under `tracker.priority`. `scheduled` is the
ticket's Org SCHEDULED date, such as `2026-12-03` or `2026-12-03 10:00 +1w`,
or null; nothing filters or sorts by it. `activity` and
`tag_since` are event references for local activity age and the current
tag-membership interval age, not remote freshness.

`doc get` prints the current version's text together with its `version`, which
a later `doc set` names as its base.

Every field is described in `zz agent-hooks show-document cli-json`.
