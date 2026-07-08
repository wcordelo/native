# Changelog fragments

Agents and feature branches do not edit `CHANGELOG.md` directly — concurrent work would conflict on every merge. Instead, each change lands with a small fragment in this directory, and `scripts/changelog-merge.sh` folds all fragments into the `## Unreleased` section of `CHANGELOG.md` (typically during release prep, see RELEASING.md).

## Writing a fragment

Add `changelog.d/<slug>.md`, where `<slug>` names your change (e.g. `gpu-dashboard-smoke-budget.md`). The file holds a bullet or two for one changelog section:

- The first line starts with a section tag: `feature:`, `improvement:`, or `fix:`, followed by the first bullet's text.
- Any further lines are additional bullets (start them with `- `; bare lines get `- ` prefixed for you).
- One tag per fragment. A change that touches multiple sections ships multiple fragments.
- Match the CHANGELOG voice: bold lead-in, then the story. One line per bullet — never hard-wrap.

Example (`changelog.d/faster-frobnication.md`):

```
improvement: **Faster frobnication**: the frobnicator now memoizes per-frame, cutting rebuild time ~40% on the kanban example.
- **Frobnication telemetry**: automation snapshots report `frob_cache_hits=`.
```

Tags map to sections: `feature:` → `### New Features`, `improvement:` → `### Improvements`, `fix:` → `### Bug Fixes`.

## Merging

```sh
scripts/changelog-merge.sh
```

appends every fragment's bullets to the end of its section under `## Unreleased` (creating the section — or the whole `## Unreleased` block — when missing), then deletes the merged fragments. This `README.md` is never merged or deleted. The script refuses unknown tags loudly instead of guessing.
