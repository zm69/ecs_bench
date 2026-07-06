# Note:

These results are expected purely because of architectural differences: ODE_ECS uses a relational database-like approach (with tables for components and views), while moecs and odecs use archetype approaches.

All tests were generated automatically by Claude AI, and the conclusions below were also made by the AI without any human intervention.

ODE_ECS link: [https://github.com/odin-engine/ode_ecs](https://github.com/odin-engine/ode_ecs)

moecs link: [https://github.com/helioscout/moecs](https://github.com/helioscout/moecs)

odecs link: [https://github.com/NateTheGreatt/odecs](https://github.com/NateTheGreatt/odecs)

Features comparison is here: [features.md](https://github.com/zm69/ecs_bench/blob/main/features.md)

# Benchmark results: ODE_ECS vs moecs vs odecs (as of 7/5/2026)

Same machine, `-o:aggressive`, same tracking-allocator harness (`mem.Tracking_Allocator`,
`current_memory_allocated` after setup). moecs refetched from
https://github.com/helioscout/moecs (commit `8d50786`, latest upstream); odecs from
https://github.com/NateTheGreatt/odecs (commit `e3ca0a5`, latest upstream). Each library uses
its idiomatic fast path: ODE_ECS via direct table iteration or `View` + `Iterator`
(plus a `view_dense_slice` batch variant); moecs via an `ARCHETYPE` system driven by
`progress()`; odecs via a per-frame `query` + `get_table` batch loop over its archetype
columns (the pattern its own docs and bundled benchmarks use).

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
`ode_one`, `moecs_one`, `odecs_one` (scenario 0); `ode`, `ode_batch`, `moecs_bench`,
`odecs_bench` (scenario 1); `ode_many`, `moecs_many`, `odecs_many` (scenario 2);
`ode_churn`, `ode_churn_batch`, `moecs_churn`, `odecs_churn` (scenario 3);
`ode_relations`, `moecs_relations`, `odecs_relations` (scenario 4). All numbers are medians
of 3 runs, all three libraries alternating within each pass.

## Scenario 0 — Single component: pure table iteration (1M entities, 100 frames)

Each entity has one `Position{x,y:f64}`; per frame `pos.x += pos.y`. This isolates raw
iteration with no multi-component lookup at all — ODE_ECS iterates the `Table` directly
(`for &p in positions.rows`), moecs runs a one-component archetype system, odecs sweeps its
single archetype's `Position` column via `get_table`.

| Library | setup | iter/frame | ns/ent/frame | live mem |
|---------|-------|------------|--------------|----------|
| ODE_ECS (table)      | **15.2 ms** | 0.31 ms | 0.31     | 83 MB     |
| ODE_ECS (view+iter)  | —           | 0.29 ms | 0.29     | —         |
| moecs                | 707 ms      | 3.53 ms | 3.53     | 168 MB    |
| odecs                | 3,855 ms    | 0.23 ms | **0.23** | **51 MB** |

ODE_ECS iterates a single component ~12x faster than moecs and its `View`+`Iterator` costs
*nothing* over raw table iteration (the dense fast path reduces it to the same SoA sweep).
moecs pays per-entity `get_mut` (typeid lookup + chunk indexing) plus per-frame system
dispatch even in the simplest possible case. odecs actually posts the fastest sweep here
(0.23 ns) and the leanest footprint — its column is the same dense SoA array, and the small
delta vs ODE_ECS's own 0.31 ns table loop is loop/allocation codegen, not architecture (both
are at the read+write-16-bytes-per-entity memory floor). The catch is the other column:
odecs takes 3.9 *seconds* to create 1M entities (~250x ODE_ECS, ~5x moecs) — every
`add_entity` funnels components through a variadic `..any` path with per-call
temp-allocator bookkeeping and typeid→ComponentID map lookups.

## Scenario 1 — Movement, 2 component types (1M entities, 100 frames)

Each entity has `Position{x,y:f64}` + `Velocity{x,y:f64}`; per frame `pos += vel`.

| Library | setup | iter/frame | ns/ent/frame | live mem |
|---------|-------|------------|--------------|----------|
| ODE_ECS (iterator)          | 21.0 ms     | 0.59 ms | 0.59     | 122 MB    |
| ODE_ECS (`view_dense_slice`)| **20.7 ms** | 0.30 ms | **0.30** | 122 MB    |
| moecs                       | 741 ms      | 4.47 ms | 4.47     | 184 MB    |
| odecs                       | 7,147 ms    | 0.31 ms | 0.31     | **66 MB** |

ODE_ECS vs moecs: ~35x faster setup, ~7.6x faster iteration with the unchanged `Iterator`
API and ~15x with the batch API (which runs at the measured raw-SoA hardware floor), ~1.5x
leaner. odecs ties ODE_ECS's batch path at the hardware floor (0.31 vs 0.30 ns) with its
ordinary documented query loop — no special fast path needed, the archetype guarantees
alignment by construction — and is the leanest of the three (66 MB). Its setup cost balloons
to 7.1 s (~340x ODE_ECS, ~10x moecs): two components per entity doubles the per-`add_entity`
type-resolution work.

## Scenario 2 — Many component types: 32 types, all on every entity (250k entities, 100 frames)

Every entity has all 32 component types (identical 16-byte shape); movement still touches
only 2 of them.

| Library | setup | iter/frame | ns/ent/frame | live mem |
|---------|-------|------------|--------------|----------|
| ODE_ECS | **89.6 ms** | 0.15 ms | 0.58     | 259 MB     |
| moecs   | 106 ms      | 1.91 ms | 7.62     | 160 MB     |
| odecs   | 7,622 ms    | 0.08 ms | **0.31** | **131 MB** |

## Scenario 3 — Structural churn: 10% despawn+respawn/frame + movement (100k entities, 100 frames)

| Library | total | ms/frame | ns per churn-op | last-entity x |
|---------|-------|----------|-----------------|---------------|
| ODE_ECS (iterator) | 50 ms  | 0.50     | 25.1     | 10 |
| ODE_ECS (batch)    | 46 ms  | **0.46** | **23.0** | 10 |
| moecs              | 117 ms | 1.17     | 58.6     | 9  |
| odecs              | 181 ms | 1.81     | 90.6     | 10 |

## Scenario 4 — Entity relations: parent/child tree churn (100k entities, added 7/5/2026)

Exercises each library's entity-relations feature. 100k entities with a `Position` are linked
into a 10-ary forest (100 roots, depth ~4). Per frame (x100): 10k leaf re-parents, 10k
children-list reads, 10k ancestor walks to the root; then 50 depth-1 subtrees
(5,550 entities) are cascade-destroyed. ODE_ECS uses the new `Relations_Table`
(`set_parent` / `children_of` / `parent_of` / `destroy_entity(..., destroy_children=true)`);
moecs uses `ChildOf`/`ParentOf` relations (`unrelate`+`child_of` for a re-parent, `children`,
`parent`, `despawn` which cascades to single-parent children); odecs uses flecs-style
`ChildOf` *pairs* with the `Exclusive` trait (so one `add_pair` re-parents, auto-dropping the
old parent) and the `Cascade` trait (so `remove_entity` on a parent deletes descendants),
with `query({pair(ChildOf, parent)})` for children reads and `find_relation_target` for
ancestor hops. moecs runs its leanest valid configuration for this workload (`.ITERATION`
approach: despawn immediate like ODE_ECS, no archetype bookkeeping, no systems). All three
programs do identical logical work verified by an identical checksum (x=13120122).

| Library | setup | reparent ns/op | children ns/op | ancestor ns/hop | cascade destroy | live mem |
|---------|-------|----------------|----------------|-----------------|-----------------|----------|
| ODE_ECS | **1.8 ms** | **6.0** | 17.6    | **1.4** | **0.13 ms** | **11 MB** |
| moecs   | 13.7 ms    | 254     | **2.9** | 9.8     | 0.85 ms     | 16 MB     |
| odecs   | 108 ms     | 224     | 2,333   | 5.5     | 9.47 ms     | 19 MB     |

ODE_ECS re-parents ~40x faster than either archetype library and walks ancestor chains
4-7x faster: `Relations_Table` is flat intrusive arrays indexed by entity index (`parent`,
`first_child`, doubly-linked siblings), so every link/unlink is a handful of array writes.
moecs must linear-search the old parent's dynamic `targets` array to unlink
(`unordered_remove` after `linear_search`) and `slice.contains`-check the new parent's —
arrays that grow to hundreds of children under this churn. odecs pays a different price for
the same op: a re-parent is a *structural archetype move* (drop the old `(ChildOf, parent)`
pair component, add the new one — two archetype transitions under `Exclusive`), landing at
224 ns/op, on par with moecs. Cascade destroy is where the pair encoding hurts most: every
`remove_entity` in odecs linearly scans all archetype signatures (~10k of them here, one per
distinct parent) looking for cascade dependents, so destroying the 5,550-entity subtrees
costs 9.5 ms vs ODE_ECS's 0.13 ms (iterative deepest-first BFS over intrusive links) and
moecs's 0.85 ms. The honest counterpoints: moecs reads a children list ~6x faster than
ODE_ECS because `children()` returns a direct slice of its stored dynamic array, whereas
ODE_ECS's `children_of` walks the sibling linked list (cache-unfriendly) and copies ids into
a scratch buffer. odecs has no children accessor at all — enumerating children *is* a query
(term decode + context build + hash + cache lookup per call, ~10k distinct cached queries
here), which is why its children reads cost ~2.3 µs, ~130x ODE_ECS. Its 5.5 ns ancestor hop
(archetype-signature scan for the `ChildOf` pair) sits between ODE_ECS's 1.4 ns array read
and moecs's 9.8 ns. Also note the features are not equivalent: ODE_ECS pays for an always-on
cycle check on every `set_parent` (the others perform none — cycles are the user's problem)
but supports only single-parent parent/child, while moecs and odecs support multi-target and
typed relations with data (odecs additionally gets relational *queries* — "all children of X"
composes with any other term). In this run all five scenarios were measured back-to-back in
a single session, all three libraries alternating within each pass.

# What the scenarios reveal

**1. SoA iteration is flat vs component-type count; moecs degrades.** From 1 -> 2 -> 32
registered component types, ODE_ECS's per-entity cost through the same-API iterator moves
0.29 -> 0.59 -> 0.58 ns (the 1->2 step is just the extra Velocity stream; 2->32 is flat) — its
SoA layout means iterating `{Position, Velocity}` only ever touches those two dense arrays no
matter how many other component types exist. odecs holds flat the same way
(0.23 -> 0.31 -> 0.31): its archetype stores each component as a separate column, so the
movement sweep touches only 2 of the 32 columns. moecs goes 3.53 -> 4.47 -> 7.62 ns, a ~70%
slowdown from 2 to 32 types, because (a) each `get_mut` strides into a now-512-byte AoS
chunk, so the two fields you want share cache lines with 30 unused components, and (b) the
`component_index` typeid scan (`component.odin:38`) is now over 32 entries. The gap widens
from ~7.6x to ~13x exactly as the architecture predicts as a game grows more component types.

**2. The dense fast path makes View overhead disappear.** Before this optimization, ODE_ECS's
`Iterator` walked per-row records of `{entity_id, component pointers}` (~24 extra bytes streamed
per entity per frame). Now, whenever the view is dense-aligned — the common case, verified
incrementally with O(tables) work per structural change and a lazy early-abort rescan — the
iterator reads `table.rows[i]` directly. Scenario 0 shows the result: view iteration (0.29 ns)
is indistinguishable from raw table iteration (0.31 ns). `view_dense_slice` goes one step
further and hands the user the raw slices in view-row order; a plain loop over them is exactly
the 0.30 ns raw-SoA floor measured outside any ECS — and scenario 1 shows odecs's ordinary
query loop landing on the same floor (0.31 ns), because an archetype's columns are aligned by
construction. The difference is what happens off the fast path: when alignment genuinely
breaks in ODE_ECS (e.g. removing one component from an entity that keeps others), everything
transparently falls back to the pointer-record path — correctness is guarded by a randomized
fuzz test in the library's test suite that cross-checks iterator results against direct table
lookups. In odecs the equivalent event is an archetype *move*, which is where its costs
concentrate (see #4 and #5).

**3. Memory: the archetype libraries win when components are universal.** In the dense
scenarios odecs is the leanest of the three outright (51 / 66 / 131 MB in scenarios 0/1/2):
one archetype, each component a single packed column, no per-table index overhead. moecs
beats ODE_ECS only in scenario 2 (160 vs 259 MB). ODE_ECS creates a full `Table` per
component type and each carries `eid_to_ptr: []rawptr` + `rid_to_eid: []entity_id` sized to
full entity capacity (~4 MB x 32 = 128 MB of pure index overhead in scenario 2) on top of its
rows. Caveat both ways: if components were *sparse* (each entity has 2 of 32), ODE_ECS would
size the other 30 tables small or use `Compact_Table`/`Tiny_Table` (the README's explicit
guidance) and win memory handily; moecs would still reserve the full 512-byte chunk per
entity; and odecs would fragment entities across many archetypes (see the relations scenario,
where ~10k archetypes cost it real money on every structural operation).

**4. Churn: ODE_ECS is ~2.5x faster than moecs, ~4x faster than odecs.** moecs's
deferred-mutation model exists to make structural changes *safe* during iteration, not
necessarily *fast*. ODE_ECS's immediate tail-swap costs ~23 ns per despawn/respawn op vs
moecs's ~59 ns (deferred queue + `perform()` rebuild + per-frame `slice.filter` over
archetypes, `world.odin:755`) and odecs's ~91 ns. odecs's structural ops are immediate like
ODE_ECS's (its `x=10` confirms same-frame visibility) but each `remove_entity`
unconditionally scans every archetype signature for `Cascade` dependents — cheap here with 2
archetypes, ruinous with 10k (scenario 4) — and each respawn re-runs the variadic `..any`
component-resolution machinery. Notably, ODE_ECS's dense fast path *survives* this churn:
tables with identical membership perform identical tail-swaps and stay row-aligned, so the
batch variant (`ode_churn_batch`) still runs the movement pass as a raw SoA sweep,
re-verifying alignment with one linear scan per frame. The `x=10` vs `x=9` in the output is
not an error — it is moecs's 1-frame deferral made visible: ODE_ECS and odecs apply churn
immediately so the respawned entity is updated the same frame; moecs archetypes it at
end-of-frame, so it starts updating next frame. That deferral is the price and the feature
(you can safely despawn mid-system-iteration in moecs; in ODE_ECS you must follow the "don't
mutate while iterating" rule; odecs defers automatically only when you mutate *during* a
query iteration).

**5. Entity creation spans two orders of magnitude.** Setting up 1M two-component entities:
ODE_ECS 21 ms, moecs 741 ms, odecs 7,147 ms. ODE_ECS preallocates typed tables and an add is
a couple of array writes; moecs pays deferred-archetyping bookkeeping per entity; odecs
routes every `add_entity` through a variadic `..any` interface that builds a temp-allocator
component-ID array *and map* per call, resolves each component's typeid through map lookups,
and checks observers — per entity. odecs's own benchmark suite measures entity/component ops
in ops/sec and this is consistent with it; it is simply the cost of its very dynamic
creation API, and it is the single biggest number separating these libraries.

# Overall

odecs's arrival splits the story into two axes. On *iteration*, the SoA libraries are now
indistinguishable: odecs's plain documented query loop runs at the same raw-SoA hardware
floor as ODE_ECS's batch path (0.30-0.31 ns/ent/frame, scenario 1) and stays flat as
component-type count grows, leaving moecs ~13-15x behind at 32 types. ODE_ECS's dense fast
path earns its keep by delivering that floor *through a stable iterator API with a
transparent fallback*, rather than by construction-only guarantees. On *structural
operations*, ODE_ECS is decisively fastest across the board: ~35x (moecs) to ~340x (odecs)
faster setup, ~2.5-4x faster churn, ~40x faster re-parenting, ~7-70x faster cascade destroy.
odecs concentrates its costs exactly there — variadic per-entity creation, archetype moves
for every pair change, all-archetype scans on delete, and query-shaped children reads
(~2.3 µs vs 17.6 ns/2.9 ns) — while winning dense-memory footprint outright (51-131 MB, the
leanest in every dense scenario). moecs's wins remain feature-driven, not throughput-driven:
safe deferred structural changes, observers/scheduler, direct children slices, and typed
multi-target relations. If your bottleneck is raw component iteration *and* structural churn,
ODE_ECS is the only library here fast at both; odecs matches it on iteration if entity
creation and hierarchy churn are rare in your game; moecs trades throughput for its
deferred-safety programming model and batteries-included features.

## Method notes / caveats

- One machine, one run set (medians of 3 passes, all three libraries alternating within each
  pass, all 17 binaries in a single session); absolute numbers vary between sessions, but
  the ratios track the architectural differences and were stable across repeated runs.
- moecs is the latest upstream commit (`8d50786`) as of 7/5/2026. odecs is the latest
  upstream commit (`e3ca0a5`), fetched 7/5/2026. ODE_ECS is its latest upstream commit
  `59e134d` (7/5/2026) plus the local `Relations_Table` work, not yet pushed at measurement
  time. ODE_ECS numbers reproduced the previously published run within noise; moecs drifted
  up ~7-10% on the iteration scenarios and more on the noisy relations micro-ops (ancestor
  hop 6.7 -> 9.8 ns), which is why every table above was refreshed from this single
  back-to-back session rather than mixing sessions.
- All workloads verified correct via a checksum (`x` value) that also defeats dead-code
  elimination, identical across libraries per scenario. (`ode_one` reports x=400 because it
  runs the same 100 frames twice — once through the table, once through the view; `moecs_one`
  and `odecs_one` run them once, x=200. All three relations programs print x=13120122 and
  destroy exactly 5,550 entities.)
- ODE_ECS results are identical with `ECS_VALIDATIONS=false`; the validation asserts cost
  nothing on these hot paths.
- The raw-SoA floor (0.30 ns/ent/frame for scenario 1's access pattern on this machine) was
  measured with a standalone Odin program iterating two plain slices, outside any ECS.
  Scenario 0's access pattern (read+write one array) has a different, slightly lower floor,
  which is how odecs's 0.23 ns there is possible.
- The odecs benchmarks call `free_all(context.temp_allocator)` once per frame (outside the
  timed relations sections): odecs allocates per-call scratch (query terms, `add_entity`
  bookkeeping) from the temp allocator and expects the host loop to reset it, so this is its
  intended usage, not overhead added to it.
- Movement is ODE_ECS's home turf; moecs does more per-frame bookkeeping by design (deferred
  actions, archetype re-filtering) to support features not exercised here.
