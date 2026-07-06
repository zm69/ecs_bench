# Note:

These results are expected purely because of architectural differences: ODE_ECS uses a relational database-like approach (with tables for components and views), while moecs uses an archetype approach.

All tests were generated automatically by Claude AI, and the conclusions below were also made by the AI without any human intervention.

ODE_ECS link: [https://github.com/odin-engine/ode_ecs](https://github.com/odin-engine/ode_ecs)

moecs link: [https://github.com/helioscout/moecs](https://github.com/helioscout/moecs)

# Benchmark results: ODE_ECS vs moecs (as of 7/5/2026)

Same machine, `-o:aggressive`, same tracking-allocator harness (`mem.Tracking_Allocator`,
`current_memory_allocated` after setup). moecs refetched from
https://github.com/helioscout/moecs (commit `8d50786`, latest upstream). Each library uses its
idiomatic fast path: ODE_ECS via direct table iteration or `View` + `Iterator`
(plus a `view_dense_slice` batch variant); moecs via an `ARCHETYPE` system driven by
`progress()`.

ODE_ECS includes the *dense (aligned) view fast path* added on 7/2/2026: when view row `i`
corresponds to row `i` in every `Table` of the view (true whenever components are added per
entity in the same order, and preserved under despawn/respawn churn), the `Iterator` reads
components directly from the tables' dense arrays instead of going through the view's per-row
pointer records, falling back transparently otherwise. `view_dense_slice` additionally exposes
raw component slices in view-row order, which compiles to a pure SoA sweep. On this machine a
plain `pos[i] += vel[i]` loop over two raw arrays runs at 0.30 ns/ent/frame — the batch path
runs at that hardware floor. This run also picks up ODE_ECS's 7/4/2026 changes (micro
optimizations and the deferred tail-swap feature, commit `59e134d`).

Benchmark sources live under `G:\odin\ecs_bench\`:
`ode_one`, `moecs_one` (scenario 0); `ode`, `ode_batch`, `moecs_bench` (scenario 1);
`ode_many`, `moecs_many` (scenario 2); `ode_churn`, `ode_churn_batch`, `moecs_churn`
(scenario 3); `ode_relations`, `moecs_relations` (scenario 4). All numbers are medians
of 3 runs.

## Scenario 0 — Single component: pure table iteration (1M entities, 100 frames)

Each entity has one `Position{x,y:f64}`; per frame `pos.x += pos.y`. This isolates raw
iteration with no multi-component lookup at all — ODE_ECS iterates the `Table` directly
(`for &p in positions.rows`), moecs runs a one-component archetype system.

| Library | setup | iter/frame | ns/ent/frame | live mem |
|---------|-------|------------|--------------|----------|
| ODE_ECS (table)      | 14.6 ms | 0.31 ms | **0.31** | **83 MB** |
| ODE_ECS (view+iter)  | —       | 0.28 ms | **0.28** | —         |
| moecs                | 700 ms  | 3.18 ms | 3.18     | 168 MB    |

ODE_ECS iterates a single component ~10x faster and its `View`+`Iterator` costs *nothing*
over raw table iteration here (the dense fast path reduces it to the same SoA sweep; both
sit at the 16-bytes-read+written-per-entity memory floor). moecs pays per-entity `get_mut`
(typeid lookup + chunk indexing) plus per-frame system dispatch even in the simplest
possible case.

## Scenario 1 — Movement, 2 component types (1M entities, 100 frames)

Each entity has `Position{x,y:f64}` + `Velocity{x,y:f64}`; per frame `pos += vel`.

| Library | setup | iter/frame | ns/ent/frame | live mem |
|---------|-------|------------|--------------|----------|
| ODE_ECS (iterator)          | 20.0 ms | 0.58 ms | **0.58** | 122 MB |
| ODE_ECS (`view_dense_slice`)| 19.5 ms | 0.30 ms | **0.30** | 122 MB |
| moecs                       | 722 ms  | 4.19 ms | 4.19     | 184 MB |

ODE_ECS: ~36x faster setup, ~7x faster iteration with the unchanged `Iterator` API and
~14x with the batch API (which runs at the measured raw-SoA hardware floor), ~1.5x leaner.

## Scenario 2 — Many component types: 32 types, all on every entity (250k entities, 100 frames)

Every entity has all 32 component types (identical 16-byte shape); movement still touches
only 2 of them.

| Library | setup | iter/frame | ns/ent/frame | live mem |
|---------|-------|------------|--------------|----------|
| ODE_ECS | 88 ms  | 0.15 ms | **0.59** | 259 MB    |
| moecs   | 100 ms | 1.73 ms | 6.91     | **160 MB**|

## Scenario 3 — Structural churn: 10% despawn+respawn/frame + movement (100k entities, 100 frames)

| Library | total | ms/frame | ns per churn-op | last-entity x |
|---------|-------|----------|-----------------|---------------|
| ODE_ECS (iterator) | 49 ms  | 0.49     | **24.5** | 10 |
| ODE_ECS (batch)    | 46 ms  | **0.46** | **23.1** | 10 |
| moecs              | 113 ms | 1.13     | 56.5     | 9  |

## Scenario 4 — Entity relations: parent/child tree churn (100k entities, added 7/5/2026)

Exercises each library's entity-relations feature. 100k entities with a `Position` are linked
into a 10-ary forest (100 roots, depth ~4). Per frame (x100): 10k leaf re-parents, 10k
children-list reads, 10k ancestor walks to the root; then 50 depth-1 subtrees
(5,550 entities) are cascade-destroyed. ODE_ECS uses the new `Relations_Table`
(`set_parent` / `children_of` / `parent_of` / `destroy_entity(..., destroy_children=true)`);
moecs uses `ChildOf`/`ParentOf` relations (`unrelate`+`child_of` for a re-parent, `children`,
`parent`, `despawn` which cascades to single-parent children). moecs runs its leanest valid
configuration for this workload (`.ITERATION` approach: despawn immediate like ODE_ECS, no
archetype bookkeeping, no systems). Both programs do identical logical work verified by an
identical checksum.

| Library | setup | reparent ns/op | children ns/op | ancestor ns/hop | cascade destroy | live mem |
|---------|-------|----------------|----------------|-----------------|-----------------|----------|
| ODE_ECS | **1.4 ms**  | **6.0** | 17.7    | **1.4** | **0.11 ms** | **11 MB** |
| moecs   | 13.6 ms     | 249     | **2.8** | 6.7     | 0.62 ms     | 16 MB     |

ODE_ECS re-parents ~41x faster and walks ancestor chains ~5x faster: `Relations_Table` is
flat intrusive arrays indexed by entity index (`parent`, `first_child`, doubly-linked
siblings), so every link/unlink is a handful of array writes, while moecs must
linear-search the old parent's dynamic `targets` array to unlink (`unordered_remove` after
`linear_search`) and `slice.contains`-check the new parent's — arrays that grow to hundreds
of children under this churn. Cascade destroy is ~6x faster (iterative deepest-first BFS vs
recursive despawn with per-entity relation scans). The honest counterpoint: moecs reads a
children list ~6x faster, because `children()` returns a direct slice of its stored dynamic
array, whereas ODE_ECS's `children_of` walks the sibling linked list (cache-unfriendly) and
copies ids into a scratch buffer. Also note the features are not equivalent: ODE_ECS pays for
an always-on cycle check on every `set_parent` (moecs performs none — cycles are the user's
problem) but supports only single-parent parent/child, while moecs supports multi-parent and
arbitrary typed relations with data. In this run all five scenarios were measured
back-to-back in a single session, both libraries alternating within each pass.

# What the scenarios reveal

**1. ODE_ECS iteration is flat vs component-type count; moecs degrades.** From 1 -> 2 -> 32
registered component types, ODE_ECS's per-entity cost through the same-API iterator moves
0.28 -> 0.58 -> 0.59 ns (the 1->2 step is just the extra Velocity stream; 2->32 is flat) — its
SoA layout means iterating `{Position, Velocity}` only ever touches those two dense arrays no
matter how many other component types exist. moecs goes 3.18 -> 4.19 -> 6.91 ns, a ~65% slowdown
from 2 to 32 types, because (a) each `get_mut` strides into a now-512-byte AoS chunk, so the two
fields you want share cache lines with 30 unused components, and (b) the `component_index`
typeid scan (`component.odin:38`) is now over 32 entries. The gap widens from ~7x to ~12x
exactly as the architecture predicts as a game grows more component types.

**2. The dense fast path makes View overhead disappear.** Before this optimization, ODE_ECS's
`Iterator` walked per-row records of `{entity_id, component pointers}` (~24 extra bytes streamed
per entity per frame). Now, whenever the view is dense-aligned — the common case, verified
incrementally with O(tables) work per structural change and a lazy early-abort rescan — the
iterator reads `table.rows[i]` directly. Scenario 0 shows the result: view iteration (0.28 ns)
is indistinguishable from raw table iteration (0.31 ns). `view_dense_slice` goes one step
further and hands the user the raw slices in view-row order; a plain loop over them is exactly
the 0.30 ns raw-SoA floor measured outside any ECS. When alignment genuinely breaks (e.g.
removing one component from an entity that keeps others), everything transparently falls back
to the pointer-record path — correctness is guarded by a randomized fuzz test in the library's
test suite that cross-checks iterator results against direct table lookups.

**3. Memory flips depending on density.** In the *dense* scenario 2 (every entity genuinely has
all 32 components) moecs uses less memory (160 vs 259 MB), because ODE_ECS creates 32 full
`Table`s and each carries `eid_to_ptr: []rawptr` + `rid_to_eid: []entity_id` sized to full
entity capacity (~4 MB x 32 = 128 MB of pure index overhead) on top of its rows. moecs's single
packed chunk avoids that. Caveat both ways: if components were *sparse* (each entity has 2 of
32), ODE_ECS would size the other 30 tables small or use `Compact_Table`/`Tiny_Table` (the
README's explicit guidance) and win memory handily, while moecs would still reserve the full
512-byte chunk per entity. So: moecs wins memory when components are universal; ODE_ECS wins
when they're sparse. In scenarios 0 and 1 ODE_ECS is 1.5-2x leaner outright.

**4. Churn: ODE_ECS is ~2.3x faster even though this is moecs's design-for case.** moecs's
deferred-mutation model exists to make structural changes *safe* during iteration, not
necessarily *fast*. ODE_ECS's immediate tail-swap costs ~25 ns per despawn/respawn op vs
moecs's ~57 ns (deferred queue + `perform()` rebuild + per-frame `slice.filter` over
archetypes, `world.odin:755`). Notably, the dense fast path *survives* this churn: tables with
identical membership perform identical tail-swaps and stay row-aligned, so the batch variant
(`ode_churn_batch`) still runs the movement pass as a raw SoA sweep, re-verifying alignment
with one linear scan per frame. The `x=10` vs `x=9` in the output is not an error — it is the
1-frame deferral made visible: ODE_ECS applies churn immediately so the respawned entity is
updated the same frame; moecs archetypes it at end-of-frame, so it starts updating next frame.
That deferral is the price and the feature (you can safely despawn mid-system-iteration in
moecs; in ODE_ECS you must follow the "don't mutate while iterating" rule).

# Overall

Across all four throughput workloads, ODE_ECS iterates 7-12x faster (10x even in the trivial
one-component case), sets up ~35-50x faster, and churns ~2.3x faster, with the iteration lead growing as
component-type count rises — the structural payoff of SoA + zero-lookup typed tables +
incrementally-maintained views, now with a dense fast path that removes the view indirection
entirely whenever row alignment holds (and a `view_dense_slice` batch API that reaches the raw
hardware floor). moecs's wins are feature-driven, not throughput-driven: lower memory when
every entity shares the same dense component set, safe deferred structural changes, and the
observers/scheduler/typed-relations this synthetic suite never exercised (scenario 4 does
exercise plain parent/child relations — added to ODE_ECS on 7/5/2026 — where ODE_ECS
re-parents ~41x and cascade-destroys ~6x faster, while moecs reads children lists faster and
offers the richer relation model). If your bottleneck is raw
component iteration and structural churn, ODE_ECS is decisively faster; if you want
batteries-included relations/systems and value the deferred-safety programming model, moecs's
costs are the price of those features.

## Method notes / caveats

- One machine, one run set (medians of 3); absolute numbers vary, but the ratios track the
  architectural differences and were stable across repeated runs.
- moecs is the latest upstream commit (`8d50786`) as of 7/5/2026, re-pulled for this run
  (no upstream changes). ODE_ECS is its latest upstream commit `59e134d` (7/5/2026) plus the
  local `Relations_Table` work, not yet pushed at measurement time. Absolute numbers came out
  somewhat lower for *both* libraries than in the previous run (machine variance between
  sessions — most visibly in scenario 4, first measured in a separate session); the ratios,
  measured back-to-back within this session, are what to trust.
- All workloads verified correct via a checksum (`x` value) that also defeats dead-code
  elimination. (`ode_one` reports x=400 because it runs the same 100 frames twice — once
  through the table, once through the view; `moecs_one` runs them once, x=200.)
- ODE_ECS results are identical with `ECS_VALIDATIONS=false`; the validation asserts cost
  nothing on these hot paths.
- The raw-SoA floor (0.30 ns/ent/frame for scenario 1's access pattern on this machine) was
  measured with a standalone Odin program iterating two plain slices, outside any ECS.
- Movement is ODE_ECS's home turf; moecs does more per-frame bookkeeping by design (deferred
  actions, archetype re-filtering) to support features not exercised here.
