# Note:

These results are expected purely because of architectural differences: ODE_ECS uses a relational database-like approach (with tables for components and views), while moecs and odecs use archetype approaches.

All tests were generated automatically by Claude AI, and the conclusions below were also made by the AI without any human intervention.

ODE_ECS link: [https://github.com/odin-engine/ode_ecs](https://github.com/odin-engine/ode_ecs)

moecs link: [https://github.com/helioscout/moecs](https://github.com/helioscout/moecs)

odecs link: [https://github.com/NateTheGreatt/odecs](https://github.com/NateTheGreatt/odecs)

Features comparison is here: [features.md](https://github.com/zm69/ecs_bench/blob/main/features.md)

# Benchmark results: ODE_ECS vs moecs vs odecs (as of July 24, 2026)

Same machine, `-o:aggressive`, same tracking-allocator harness (`mem.Tracking_Allocator`,
`current_memory_allocated` after setup). moecs re-fetched from
https://github.com/helioscout/moecs (commit `ccd00f2`, up from `8d50786`; the new commits are
README-only, no source changed); odecs re-fetched from https://github.com/NateTheGreatt/odecs
(commit `e3ca0a5`, unchanged since 7/5/2026). ODE_ECS re-fetched from
https://github.com/odin-engine/ode_ecs (commit `2e8268c`, up from `978f2e5`/`6d96b39` — see
Method notes for what changed). Each library uses its idiomatic fast path: ODE_ECS via direct
table iteration, `View` + `Iterator`, `view_dense_slice`, or an owned `Group` +
`group_dense_slice`; moecs via an `ARCHETYPE` system driven by `progress()`; odecs via a
per-frame `query` + `get_table` batch loop over its archetype columns (the pattern its own
docs and bundled benchmarks use).

ODE_ECS includes the *dense (aligned) view fast path* added on 7/2/2026: when view row `i`
corresponds to row `i` in every `Table` of the view (true whenever components are added per
entity in the same order, and preserved under despawn/respawn churn), the `Iterator` reads
components directly from the tables' dense arrays instead of going through the view's per-row
pointer records, falling back transparently otherwise. `view_dense_slice` additionally exposes
raw component slices in view-row order, which compiles to a pure SoA sweep. In a quieter prior
session, a standalone `pos[i] += vel[i]` loop over two raw arrays measured 0.30 ns/ent/frame on
this machine; this session's batch/group paths land at 0.34-0.38 ns (see Method notes on
session-to-session drift — every library, including the functionally-unchanged odecs, drifted
upward by a similar proportion this run, so this reads as machine noise, not a regression).

ODE_ECS's `Group` (an EnTT-style *full-owning group*, added 7/9/2026) is carried forward this
run, not new. Where a `View` *detects* dense alignment and falls back when it breaks, a `Group`
takes exclusive ownership of a set of `Table`s and *enforces* alignment — every `add_component`
that completes group membership swaps the entity's rows into a contiguous prefix
`[0, group_len)` shared by every owned table, and every `remove_component`/`destroy_entity` that
breaks membership swaps it back out. `group_dense_slice` is therefore always valid — no
alignment check, no fallback path, ever — at the cost of paying O(owned tables) row swaps on
every membership change, and a table can be owned by at most one group. It's exercised in the
three scenarios where every entity keeps a stable component set (movement, many-types, churn)
as `ode_group`, `ode_many_group`, `ode_churn_group`.

Benchmark sources live under `G:\odin\ecs_bench\`:
`ode_one`, `moecs_one`, `odecs_one` (scenario 0); `ode`, `ode_batch`, `ode_group`,
`moecs_bench`, `odecs_bench` (scenario 1); `ode_many`, `ode_many_group`, `moecs_many`,
`odecs_many` (scenario 2); `ode_churn`, `ode_churn_batch`, `ode_churn_group`, `moecs_churn`,
`odecs_churn` (scenario 3); `ode_relations`, `moecs_relations`, `odecs_relations`
(scenario 4). All numbers are medians of 3 runs, all binaries alternating within each pass.

## Scenario 0 — Single component: pure table iteration (1M entities, 100 frames)

Each entity has one `Position{x,y:f64}`; per frame `pos.x += pos.y`. This isolates raw
iteration with no multi-component lookup at all — ODE_ECS iterates the `Table` directly
(`for &p in positions.rows`), moecs runs a one-component archetype system, odecs sweeps its
single archetype's `Position` column via `get_table`.

| Library | setup | iter/frame | ns/ent/frame | live mem |
|---------|-------|------------|--------------|----------|
| ODE_ECS (table)      | **15.5 ms** | 0.32 ms | 0.32     | 76 MB     |
| ODE_ECS (view+iter)  | —           | 0.31 ms | 0.31     | —         |
| moecs                | 704.9 ms    | 3.26 ms | 3.26     | 168 MB    |
| odecs                | 3,584.7 ms  | 0.29 ms | **0.29** | **51 MB** |

ODE_ECS iterates a single component ~10x faster than moecs and its `View`+`Iterator` costs
*nothing* over raw table iteration (the dense fast path reduces it to the same SoA sweep). A
single-table `Group` would add nothing here either — with one component there is no
"membership" to enforce, the table already is the aligned set — so this scenario has no
group variant. moecs pays per-entity `get_mut` (typeid lookup + chunk indexing) plus
per-frame system dispatch even in the simplest possible case. odecs actually posts the
fastest sweep here (0.29 ns) and the leanest footprint — its column is the same dense SoA
array, and the small delta vs ODE_ECS's own 0.32 ns table loop is loop/allocation codegen, not
architecture (both are at the read+write-16-bytes-per-entity memory floor). The catch is the
other column: odecs takes 3.6 *seconds* to create 1M entities (~230x ODE_ECS, ~5x moecs) —
every `add_entity` funnels components through a variadic `..any` path with per-call
temp-allocator bookkeeping and typeid→ComponentID map lookups.

## Scenario 1 — Movement, 2 component types (1M entities, 100 frames)

Each entity has `Position{x,y:f64}` + `Velocity{x,y:f64}`; per frame `pos += vel`.

| Library | setup | iter/frame | ns/ent/frame | live mem |
|---------|-------|------------|--------------|----------|
| ODE_ECS (iterator)          | 19.4 ms     | 0.60 ms | 0.60     | 103 MB    |
| ODE_ECS (`view_dense_slice`)| 19.1 ms     | 0.36 ms | 0.36     | 103 MB    |
| ODE_ECS (`group_dense_slice`)| **17.6 ms**| 0.36 ms | **0.36** | **83 MB** |
| moecs                       | 728.0 ms    | 4.25 ms | 4.25     | 184 MB    |
| odecs                       | 6,661.7 ms  | 0.41 ms | 0.41     | 66 MB     |

ODE_ECS vs moecs: ~38x faster setup, ~7x faster iteration with the unchanged `Iterator`
API and ~12x with the batch/group APIs (all three run near the measured raw-SoA hardware
floor), 1.8-2.2x leaner. odecs lands close to ODE_ECS's batch/group paths this session (0.41
vs 0.36 ns) with its ordinary documented query loop — no special fast path needed, the
archetype guarantees alignment by construction; the exact ordering has shifted a few percent
in ODE_ECS's favor vs prior sessions, within the run-to-run noise band (see Method notes).
odecs's setup cost balloons to 6.7 s (~340x ODE_ECS, ~9x moecs): two components per entity
doubles the per-`add_entity` type-resolution work.

The `Group` row remains the cheapest *and* the leanest of the three ODE_ECS variants, not just
tied for fastest to iterate. Setup is ~10% faster than plain `View`+`Iterator` and memory sits
at 83 MB against the `View` paths' 103 MB — the View's per-row pointer-record bookkeeping
(`view__add_record` on every `add_component`, sized to entity capacity) simply doesn't exist
for a `Group`: a membership-completing add only pays a bit-subset check plus, since these
entities are created in the same order in both tables, a swap that's already a no-op (the row
is already at the prefix position). That is precisely the case group.md recommends: a set
whose membership never changes after setup, iterated every frame — pay the (here, ~free) swap
cost once, get the enforced floor forever with no per-row fallback structure to maintain.

## Scenario 2 — Many component types: 32 types, all on every entity (250k entities, 100 frames)

Every entity has all 32 component types (identical 16-byte shape); movement still touches
only 2 of them.

| Library | setup | iter/frame | ns/ent/frame | live mem |
|---------|-------|------------|--------------|----------|
| ODE_ECS (view)        | 38.8 ms     | 0.15 ms | 0.60     | 226 MB     |
| ODE_ECS (group, 2/32) | **36.9 ms** | 0.08 ms | **0.31** | 221 MB     |
| moecs                 | 102.6 ms    | 1.84 ms | 7.36     | 160 MB     |
| odecs                 | 7,319.4 ms  | 0.08 ms | 0.33     | **131 MB** |

The group row owns only the 2 tables the movement pass touches (`Position`, `Velocity`) out of
the 32 registered — the other 30 stay ordinary `Table`s the group never looks at. Setup cost
is a wash against the plain view (both pay for all 32 `add_component` calls per entity; only 2
of them touch group/view bookkeeping at all), but iteration nearly halves again vs the
already-fast view path (0.60 -> 0.31 ns), landing ODE_ECS below odecs's archetype-column sweep
in this scenario too.

**Flag for the maintainer:** setup here (both view and group) is ~2x what it was in the
7/9/2026 run (19.6-19.7 ms then vs 36.9-38.8 ms now) — unlike everything else in this session's
drift, this one doesn't wash out. It's not a `VALIDATIONS` artifact (rebuilt both binaries with
`-define:ECS_VALIDATIONS=false` and setup was still ~35-40 ms). Scenario 0 and scenario 1
setup are flat or improved over the same period, so the cost scales specifically with
component-type count (32 `add_component` calls/entity here vs 1-2 elsewhere) — consistent with
something added to the per-`add_component` path since 7/9 (Command_Buffer, relations, or
serialization hooks are the likeliest candidates given the commit list in Method notes) rather
than a one-off measurement fluke. Iteration cost is unaffected either way. Worth a profiler
pass if setup latency at high component counts matters for your use case.

## Scenario 3 — Structural churn: 10% despawn+respawn/frame + movement (100k entities, 100 frames)

| Library | total | ms/frame | ns per churn-op | last-entity x |
|---------|-------|----------|-----------------|---------------|
| ODE_ECS (iterator) | 56.5 ms | 0.57     | 28.3     | 10 |
| ODE_ECS (batch)    | 53.3 ms | 0.53     | 26.7     | 10 |
| ODE_ECS (group)    | **50.0 ms** | **0.50** | **25.0** | 10 |
| moecs              | 113.3 ms | 1.13    | 56.7     | 9  |
| odecs              | 180.2 ms | 1.80    | 90.1     | 10 |

The group variant is the fastest here too, ~6% ahead of the batch view this session (a smaller
edge than the ~10% seen 7/9/2026, within normal run-to-run variance for a gap this small).
Membership never actually toggles in this workload (every despawned entity is immediately
respawned with both components), so the group pays exactly one swap per create/destroy — the
same row movement the table's own tail-swap already performs — but skips the view's separate
per-row pointer-record maintenance and its per-frame alignment re-check entirely, since
`group_dense_slice` needs neither.

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
| ODE_ECS | **1.5 ms** | **6.5** | 17.1    | **1.3** | **0.14 ms** | **10 MB** |
| moecs   | 13.7 ms    | 254.3   | **2.9** | 7.0     | 0.64 ms     | 16 MB     |
| odecs   | 105.9 ms   | 204.3   | 2,295.4 | 5.3     | 9.42 ms     | 19 MB     |

`Group` doesn't apply to this scenario: it owns plain `Table`s to enforce component-set
alignment, while parent/child links live in ODE_ECS's separate `Relations_Table` structure —
a different mechanism entirely, with its own intrusive-array design (see the discussion
above the table).

ODE_ECS re-parents ~31-39x faster than either archetype library and walks ancestor chains
~4-5x faster: `Relations_Table` is flat intrusive arrays indexed by entity index (`parent`,
`first_child`, doubly-linked siblings), so every link/unlink is a handful of array writes.
moecs must linear-search the old parent's dynamic `targets` array to unlink
(`unordered_remove` after `linear_search`) and `slice.contains`-check the new parent's —
arrays that grow to hundreds of children under this churn. odecs pays a different price for
the same op: a re-parent is a *structural archetype move* (drop the old `(ChildOf, parent)`
pair component, add the new one — two archetype transitions under `Exclusive`), landing at
204 ns/op, noticeably faster than moecs's 254 ns but still the same order of magnitude, both
well above ODE_ECS's array-write cost. Cascade destroy is where the pair encoding hurts most:
every `remove_entity` in odecs linearly scans all archetype signatures (~10k of them here, one
per distinct parent) looking for cascade dependents, so destroying the 5,550-entity subtrees
costs 9.4 ms vs ODE_ECS's 0.14 ms (iterative deepest-first BFS over intrusive links) and
moecs's 0.64 ms. The honest counterpoints: moecs reads a children list ~6x faster than
ODE_ECS because `children()` returns a direct slice of its stored dynamic array, whereas
ODE_ECS's `children_of` walks the sibling linked list (cache-unfriendly) and copies ids into
a scratch buffer. odecs has no children accessor at all — enumerating children *is* a query
(term decode + context build + hash + cache lookup per call, ~10k distinct cached queries
here), which is why its children reads cost ~2.3 µs, ~134x ODE_ECS. Its 5.3 ns ancestor hop
(archetype-signature scan for the `ChildOf` pair) sits between ODE_ECS's 1.3 ns array read
and moecs's 7.0 ns. Also note the features are not equivalent: ODE_ECS pays for an always-on
cycle check on every `set_parent` (the others perform none — cycles are the user's problem)
but supports only single-parent parent/child, while moecs and odecs support multi-target and
typed relations with data (odecs additionally gets relational *queries* — "all children of X"
composes with any other term). In this run all five scenarios were measured back-to-back in
a single session, all three libraries alternating within each pass.

# What the scenarios reveal

**1. SoA iteration is flat vs component-type count; moecs degrades.** From 1 -> 2 -> 32
registered component types, ODE_ECS's per-entity cost through the same-API iterator moves
0.31 -> 0.60 -> 0.60 ns (the 1->2 step is just the extra Velocity stream; 2->32 is flat) — its
SoA layout means iterating `{Position, Velocity}` only ever touches those two dense arrays no
matter how many other component types exist. The `Group`/`group_dense_slice` path stays near
that same floor, 0.36 -> 0.31 ns, because it carries no per-row fallback machinery to begin
with (see point 6) — this session's numbers put it slightly *below* the view path at 32 types
but roughly level with it at 2, within the drift described in Method notes. odecs is noisier
this session than architecture alone predicts (0.29 -> 0.41 -> 0.33), but every value sits in
the same sub-nanosecond band regardless of type count: its archetype stores each component as
a separate column, so the movement sweep touches only 2 of the 32 columns no matter how many
exist. moecs goes 3.26 -> 4.25 -> 7.36 ns, a ~73% slowdown from 2 to 32 types, because (a) each
`get_mut` strides into a now-512-byte AoS chunk, so the two fields you want share cache lines
with 30 unused components, and (b) the `component_index` typeid scan (`component.odin:38`) is
now over 32 entries. The gap widens from ~7x to ~12x (or, group vs moecs, ~12x to ~24x)
exactly as the architecture predicts as a game grows more component types.

**2. The dense fast path makes View overhead disappear — Group removes the check itself.**
Before the 7/2/2026 optimization, ODE_ECS's `Iterator` walked per-row records of
`{entity_id, component pointers}` (~24 extra bytes streamed per entity per frame). Now,
whenever the view is dense-aligned — the common case, verified incrementally with O(tables)
work per structural change and a lazy early-abort rescan — the iterator reads `table.rows[i]`
directly. Scenario 0 shows the result: view iteration (0.31 ns) is indistinguishable from raw
table iteration (0.32 ns). `view_dense_slice` goes one step further and hands the user the raw
slices in view-row order; a plain loop over them measured 0.30 ns in a quieter prior session
(0.36 ns this one — see Method notes on drift), close to the standalone raw-SoA floor measured
outside any ECS — and scenario 1 shows odecs's ordinary query loop in the same neighborhood
(0.41 ns this session), because an archetype's columns are aligned by construction even though
the exact numbers moved around more than usual this run. `Group` goes one step
further still: there is no alignment *detection* at all, dense or otherwise, because a group
never allows misalignment to occur — `group_dense_slice` is either the current prefix slice or
`nil` (dirty), full stop. The difference is what happens off the fast path: when alignment
genuinely breaks under a plain `View` (e.g. removing one component from an entity that keeps
others), everything transparently falls back to the pointer-record path — correctness is
guarded by a randomized fuzz test in the library's test suite that cross-checks iterator
results against direct table lookups. A `Group`'s owned tables can't reach that state at all
(that's the whole point of ownership); in odecs the equivalent event is an archetype *move*,
which is where its costs concentrate (see #4 and #5).

**3. Memory: the archetype libraries win when components are universal — except a Group
closes much of the gap.** In the dense scenarios odecs is the leanest of the three outright
via `View` (51 / 66 / 131 MB in scenarios 0/1/2): one archetype, each component a single
packed column, no per-table index overhead. moecs beats ODE_ECS via `View` only in scenario 2
(160 vs 226 MB). But `Group` carries no per-entity bookkeeping at all — `group__memory_usage`
is just the owned-tables list — so it inherits only the plain `Table` rows plus each table's
own `eid_to_ptr`/`rid_to_eid` index arrays, none of a `View`'s subscriber records. In scenario
1 that drops ODE_ECS from 103 MB (view) to 83 MB (group), closing much of the distance to
odecs's 66 MB (both `View` numbers dropped from the 114 MB measured 7/9/2026 — the base
`Table`/database structures themselves got leaner somewhere in the intervening commits, see
Method notes — while `Group`'s 83 MB is unchanged, since it never carried that overhead to
begin with); in scenario 2, owning only the 2 tables actually iterated drops 226 MB to
221 MB (the other 30 `Table`s' index overhead — `eid_to_ptr` + `rid_to_eid` sized to full
entity capacity, ~4 MB x 30 = 120 MB — dominates regardless of view or group, since it's a
property of the tables themselves, not the query mechanism over them). Caveat both ways: if
components were *sparse* (each entity has 2 of 32), ODE_ECS would size the other 30 tables
small or use `Compact_Table`/`Tiny_Table` (the README's explicit guidance, though note groups
can only own the plain `Table` type) and win memory handily; moecs would still reserve the
full 512-byte chunk per entity; and odecs would fragment entities across many archetypes (see
the relations scenario, where ~10k archetypes cost it real money on every structural
operation).

**4. Churn: ODE_ECS is ~2x faster than moecs, ~3x faster than odecs — and Group shaves off
another ~6%.** moecs's deferred-mutation model exists to make structural changes *safe*
during iteration, not necessarily *fast*. ODE_ECS's immediate tail-swap costs ~28 ns per
despawn/respawn op (iterator), ~25 ns with a `Group` owning the tables, vs moecs's ~57 ns
(deferred queue + `perform()` rebuild + per-frame `slice.filter` over archetypes,
`world.odin:755`) and odecs's ~90 ns. odecs's structural ops are immediate like ODE_ECS's (its
`x=10` confirms same-frame visibility) but each `remove_entity` unconditionally scans every
archetype signature for `Cascade` dependents — cheap here with 2 archetypes, ruinous with 10k
(scenario 4) — and each respawn re-runs the variadic `..any` component-resolution machinery.
Notably, ODE_ECS's dense fast path *survives* this churn regardless of which mechanism keeps
it aligned: tables with identical membership perform identical tail-swaps and stay
row-aligned, so the batch variant (`ode_churn_batch`) still runs the movement pass as a raw
SoA sweep, re-verifying alignment with one linear scan per frame; the group variant
(`ode_churn_group`) needs no re-verification at all, since membership here never actually
changes (every despawned entity is immediately respawned with both components) — the group
just pays its usual one-swap-per-membership-change cost, which coincides with the tail-swap
the table would have paid anyway, and comes out ~6% ahead of the batch view by skipping the
view's separate bookkeeping. The `x=10` vs `x=9` in the output is not an error — it is moecs's
1-frame deferral made visible: ODE_ECS and odecs apply churn immediately so the respawned
entity is updated the same frame; moecs archetypes it at end-of-frame, so it starts updating
next frame. That deferral is the price and the feature (you can safely despawn
mid-system-iteration in moecs; in ODE_ECS you must follow the "don't mutate while iterating"
rule, or use `pause_tail_swap` which also defers group maintenance; odecs defers automatically
only when you mutate *during* a query iteration).

**5. Entity creation spans two orders of magnitude.** Setting up 1M two-component entities:
ODE_ECS 17.6-19.4 ms depending on variant, moecs 728 ms, odecs 6,662 ms. ODE_ECS preallocates
typed tables and an add is a couple of array writes (or, owned by a group, a bit-subset check
plus a swap that's a no-op when insertion order already matches); moecs pays
deferred-archetyping bookkeeping per entity; odecs routes every `add_entity` through a
variadic `..any` interface that builds a temp-allocator component-ID array *and map* per call,
resolves each component's typeid through map lookups, and checks observers — per entity.
odecs's own benchmark suite measures entity/component ops in ops/sec and this is consistent
with it; it is simply the cost of its very dynamic creation API, and it is the single biggest
number separating these libraries.

**6. Groups: enforce what views merely detect, and it's cheaper than it sounds.** The
textbook expectation for a full-owning group (EnTT's design, which `Group` adapts) is a
trade: pay more on structural change to get a guaranteed-flat iteration floor with zero
runtime checks. That trade shows up nowhere as a *cost* in these three scenarios — group setup
(scenario 1: 17.6 ms) undercuts plain `View` setup (19.4 ms), and group churn (scenario 3:
25.0 ns/op) undercuts batch-view churn (26.7 ns/op) — because in all three, a `View` isn't
free either: every `add_component` that matches a subscribed view still calls
`view__add_record` to maintain its pointer-record fallback path, win or lose. A `Group`
skips that path's existence entirely, paying only a bit-subset check plus a row swap that
collapses to a length increment whenever the entity is already sitting where the group wants
it (true here, since components are always added in the same order). The honest place the
textbook trade would bite: an entity set whose owned-component membership toggles on and off
across many frames relative to how often it's swept (e.g. a `Stunned` tag table that gets
added/removed constantly on a small fraction of entities each frame) — every toggle there
pays a real O(owned-tables) swap that a `View` would pay too (to update its own records) but a
`Group` pays *in addition to* the cost of moving the row physically, whereas a `View`'s
pointer-record update never moves component data. None of scenarios 1-3 exercise that case
(component sets are stable per entity outside of whole-entity destroy/create), which is
exactly the "hot set, stable membership" niche `Group` is documented for — pick it there, keep
`View` for churn-heavy or filtered sets.

# Overall

odecs's arrival splits the story into two axes. On *iteration*, the SoA libraries remain close:
odecs's plain documented query loop runs in the same neighborhood as ODE_ECS's batch and group
paths (0.31-0.41 ns/ent/frame this session, scenario 1 — noisier than the 0.29-0.31 ns tie
measured 7/9/2026, see Method notes) and stays flat as component-type count grows, leaving
moecs ~12-24x behind at 32 types depending on which ODE_ECS variant you compare. ODE_ECS's
dense fast path earns its keep by delivering that floor *through a stable iterator API with a
transparent fallback*, rather than by construction-only guarantees; `Group` delivers the same
floor with *no* fallback machinery at all, and in these scenarios that turns out to cost
nothing extra on churn and only shows up as a real setup cost in the 32-type scenario (see the
flag under scenario 2) — it's still a strict improvement over `View` whenever membership is
stable, which scenarios 1-3 all are. On *structural operations*, ODE_ECS is decisively fastest
across the board: ~38x (moecs) to ~340x (odecs) faster setup in the 2-component scenario,
~2-3x faster churn (a bit more with `Group`), ~31-39x faster re-parenting, ~5-67x faster
cascade destroy. odecs concentrates its costs exactly there — variadic per-entity creation,
archetype moves for every pair change, all-archetype scans on delete, and query-shaped children
reads (~2.3 µs vs 17.1 ns/2.9 ns) — while winning dense-memory footprint outright in scenarios
0 and 2 (odecs's `View`-based numbers are leanest there; ODE_ECS's `Group` closes much of the
gap in scenario 1, see point 3). moecs's wins
remain feature-driven, not throughput-driven: safe deferred structural changes,
observers/scheduler, direct children slices, and typed multi-target relations. If your
bottleneck is raw component iteration *and* structural churn, ODE_ECS is the only library here
fast at both, and its `Group` is the one to reach for when a hot set's membership is stable;
odecs matches it on iteration if entity creation and hierarchy churn are rare in your game;
moecs trades throughput for its deferred-safety programming model and batteries-included
features.

## Method notes / caveats

- One machine, one run set (medians of 3 passes, all 20 binaries alternating within each
  pass in a single session); absolute numbers vary between sessions, but the ratios track
  the architectural differences and were stable across repeated runs.
- moecs is at commit `ccd00f2` (up from `8d50786`); the four new commits since 7/9/2026 are
  README-only (`git log HEAD..origin/master --oneline` showed only "Readme." commits), no
  source changed. odecs is unchanged at `e3ca0a5` since 7/5/2026 (`git fetch` pulled nothing
  new). ODE_ECS is at commit `2e8268c` (up from `978f2e5`/`6d96b39`, last benchmarked
  7/9/2026); the intervening commits are, newest first: "Improve snapshot validations and
  optimize view", "Bug fixes, performance, polish & tests" (this one also deleted ~1,300 lines
  of unused legacy map code, `Key_Map`/`RH_Map`, from `ode_core/maps`), "Add iterator sugar",
  "Test edge-cases", "Overbase serialization", "Micro optimizations", "Overbase feature",
  "Structural-op speed pack", "Deferred relations ops (cmd_set_parent / cmd_remove_parent)",
  plus a longer tail of docs/README/Command_Buffer/serialization/pause_packing work going back
  toward 7/9. Numbers this session drifted upward by a similar proportion across *all three*
  libraries — including the functionally-unchanged odecs — relative to 7/9/2026, which reads
  as machine noise rather than a regression anywhere; every table above was refreshed from this
  single back-to-back session rather than mixing sessions. The one exception that did **not**
  wash out as noise: ODE_ECS's scenario 2 setup roughly doubled (19.6-19.7 ms -> 36.9-38.8 ms)
  and reproduced with `ECS_VALIDATIONS=false` too — see the flag under scenario 2.
- No new binaries this run; the `Group` variants (`ode_group`, `ode_many_group`,
  `ode_churn_group`) were added 7/9/2026 and are carried forward unchanged. `Group` needs no
  counterpart in moecs or odecs — it's an ODE_ECS-specific mechanism for enforcing (not just
  detecting) dense alignment over a fixed set of owned tables; the other two libraries'
  archetype/chunk storage gets the equivalent guarantee by construction, which is exactly why
  their numbers already sit at the same floor without a comparable API.
- All workloads verified correct via a checksum (`x` value) that also defeats dead-code
  elimination, identical across libraries per scenario. (`ode_one` reports x=400 because it
  runs the same 100 frames twice — once through the table, once through the view; `moecs_one`
  and `odecs_one` run them once, x=200. All three relations programs print x=13120122 and
  destroy exactly 5,550 entities.)
- ODE_ECS results are identical with `ECS_VALIDATIONS=false` on the iteration and churn paths —
  re-verified this session on scenario 1 (iterator/batch/group all within noise of the
  validated build). This no longer holds unconditionally for setup cost in general: scenario
  2's setup regression (above) reproduces with validations off, so it isn't a validation
  artifact, but it also means "validations cost nothing" should be read as "on these hot loops
  specifically," not as a blanket guarantee for every structural path.
- The raw-SoA floor (0.30 ns/ent/frame for scenario 1's access pattern on this machine) was
  measured in a prior, quieter session with a standalone Odin program iterating two plain
  slices, outside any ECS; it was not re-measured this session. Scenario 0's access pattern
  (read+write one array) has a different, slightly lower floor, which is how odecs's 0.29 ns
  there is possible.
- The odecs benchmarks call `free_all(context.temp_allocator)` once per frame (outside the
  timed relations sections): odecs allocates per-call scratch (query terms, `add_entity`
  bookkeeping) from the temp allocator and expects the host loop to reset it, so this is its
  intended usage, not overhead added to it.
- Movement is ODE_ECS's home turf; moecs does more per-frame bookkeeping by design (deferred
  actions, archetype re-filtering) to support features not exercised here.
