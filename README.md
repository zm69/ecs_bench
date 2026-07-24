# Note:

These results are expected purely because of architectural differences: ODE_ECS uses a relational database-like approach (with tables for components and views), while moecs and odecs use archetype approaches.

All tests were generated automatically by Claude AI, and the conclusions below were also made by the AI without any human intervention.

ODE_ECS link: [https://github.com/odin-engine/ode_ecs](https://github.com/odin-engine/ode_ecs)

moecs link: [https://github.com/helioscout/moecs](https://github.com/helioscout/moecs)

odecs link: [https://github.com/NateTheGreatt/odecs](https://github.com/NateTheGreatt/odecs)

Features comparison is here: [features.md](https://github.com/zm69/ecs_bench/blob/main/features.md)

# Benchmark results: ODE_ECS vs moecs vs odecs (as of July 24, 2026, post-fix re-run)

Same machine, `-o:aggressive`, same tracking-allocator harness (`mem.Tracking_Allocator`,
`current_memory_allocated` after setup). This is a same-day follow-up to the earlier 7/24 run,
after the maintainer pushed a fix for the scenario 2 setup regression flagged in that run (see
below). moecs (`ccd00f2`) and odecs (`e3ca0a5`) were not re-fetched — only ODE_ECS changed — but
every binary, including theirs, was rerun fresh this session (medians of 3 passes, all binaries
alternating within each pass) rather than reusing the earlier pass's numbers, since absolute
timings drift between sessions and mixing passes would understate or hide real deltas. ODE_ECS
moved from https://github.com/odin-engine/ode_ecs commit `2e8268c` to `5c5671c` ("Churn
optimization" — see Method notes for what the commit actually changed, which is not what its
message suggests). Each library uses its idiomatic fast path: ODE_ECS via direct
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
this machine; this session's batch/group paths land at 0.30 ns, matching that floor almost
exactly (see Method notes on session-to-session drift for why this number moves around between
runs).

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
(scenario 4); `ode_mixed`, `ode_mixed_group`, `moecs_mixed`, `odecs_mixed`, plus the shared
`scenario5_gen` schedule generator (scenario 5). All numbers are medians of 3 runs, all
binaries alternating within each pass.

## Scenario 0 — Single component: pure table iteration (1M entities, 100 frames)

Each entity has one `Position{x,y:f64}`; per frame `pos.x += pos.y`. This isolates raw
iteration with no multi-component lookup at all — ODE_ECS iterates the `Table` directly
(`for &p in positions.rows`), moecs runs a one-component archetype system, odecs sweeps its
single archetype's `Position` column via `get_table`.

| Library | setup | iter/frame | ns/ent/frame | live mem |
|---------|-------|------------|--------------|----------|
| ODE_ECS (table)      | **14.7 ms** | 0.30 ms | 0.30     | 76 MB     |
| ODE_ECS (view+iter)  | —           | **0.29 ms** | **0.29** | —     |
| moecs                | 702.8 ms    | 3.33 ms | 3.33     | 168 MB    |
| odecs                | 3,403.8 ms  | 0.33 ms | 0.33     | **51 MB** |

ODE_ECS iterates a single component ~11x faster than moecs and its `View`+`Iterator` costs
*nothing* over raw table iteration (the dense fast path reduces it to the same SoA sweep). A
single-table `Group` would add nothing here either — with one component there is no
"membership" to enforce, the table already is the aligned set — so this scenario has no
group variant. moecs pays per-entity `get_mut` (typeid lookup + chunk indexing) plus
per-frame system dispatch even in the simplest possible case. This session, ODE_ECS's `View`
edges out odecs on iteration (0.29 vs 0.33 ns) — the reverse of the earlier 7/24 pass (0.31 vs
0.29) — but odecs's iteration numbers bounced around more than ODE_ECS's across this run's
three passes (0.22-0.38 ns), so read the ordering here as within noise rather than a real
swap; both remain at the same read+write-16-bytes-per-entity memory floor, and odecs keeps the
leanest footprint (51 MB). The catch is the other column: odecs takes 3.4 *seconds* to create
1M entities (~230x ODE_ECS, ~5x moecs) — every `add_entity` funnels components through a
variadic `..any` path with per-call temp-allocator bookkeeping and typeid→ComponentID map
lookups.

## Scenario 1 — Movement, 2 component types (1M entities, 100 frames)

Each entity has `Position{x,y:f64}` + `Velocity{x,y:f64}`; per frame `pos += vel`.

| Library | setup | iter/frame | ns/ent/frame | live mem |
|---------|-------|------------|--------------|----------|
| ODE_ECS (iterator)          | 17.3 ms     | 0.61 ms | 0.61     | 103 MB    |
| ODE_ECS (`view_dense_slice`)| 17.1 ms     | **0.30 ms** | **0.30** | 103 MB |
| ODE_ECS (`group_dense_slice`)| **15.3 ms**| **0.30 ms** | **0.30** | **83 MB** |
| moecs                       | 734.5 ms    | 4.31 ms | 4.31     | 184 MB    |
| odecs                       | 6,335.1 ms  | 0.50 ms | 0.50     | 66 MB     |

ODE_ECS vs moecs: ~43-48x faster setup, ~7x faster iteration with the unchanged `Iterator`
API and ~14x with the batch/group APIs (both run right at the measured raw-SoA hardware
floor), 1.8-2.2x leaner. odecs's ordinary documented query loop (0.50 ns) sits between
ODE_ECS's plain `Iterator` and its batch/group paths this session — the exact ordering moves
around a few tenths of a nanosecond between runs (see Method notes), but odecs's numbers are
consistently the noisiest of the three across scenarios 0-2. odecs's setup cost balloons to
6.3 s (~370x ODE_ECS, ~9x moecs): two components per entity doubles the per-`add_entity`
type-resolution work.

The `Group` row remains the cheapest of the three ODE_ECS variants and the leanest, not just
tied for fastest to iterate. Setup is ~11% faster than plain `View`+`Iterator` and memory sits
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
| ODE_ECS (view)        | 20.6 ms     | 0.15 ms | 0.58     | 226 MB     |
| ODE_ECS (group, 2/32) | **19.8 ms** | 0.08 ms | **0.30** | 221 MB     |
| moecs                 | 99.7 ms     | 1.80 ms | 7.22     | 160 MB     |
| odecs                 | 7,050.6 ms  | 0.10 ms | 0.40     | **131 MB** |

The group row owns only the 2 tables the movement pass touches (`Position`, `Velocity`) out of
the 32 registered — the other 30 stay ordinary `Table`s the group never looks at. Setup cost
is a wash against the plain view (both pay for all 32 `add_component` calls per entity; only 2
of them touch group/view bookkeeping at all), but iteration nearly halves again vs the
already-fast view path (0.58 -> 0.30 ns), landing ODE_ECS below odecs's archetype-column sweep
in this scenario too.

**Fixed since the last run:** the earlier 7/24/2026 pass flagged setup here (both view and
group) at roughly 2x the 7/9/2026 baseline (19.6-19.7 ms then vs 36.9-38.8 ms that run). The
maintainer traced it and pushed commit `5c5671c` ("Churn optimization") the same day: three
of `Table`'s hot per-row functions —
`add_component`/`remove_component`/`pack` — read `self.type_info.size` off the `Table_Raw`
struct on every call to compute a row pointer, which a runtime field load defeats the
Odin/LLVM optimizer's ability to fold `rid * elem_size` into a shift even though every
generic-typed caller (`table__add_component(self: ^Table(T), ...)`) actually knows `size_of(T)`
at compile time. The fix splits each into a `_sized` variant taking `elem_size` as an explicit
`#force_inline` parameter — the typed API now passes the compile-time `size_of(T)` constant and
gets it folded in, while the handful of type-erased callers (`Command_Buffer` replay, `Group`,
database-wide sweeps) keep passing `self.type_info.size` and get byte-identical behavior to
before. Since scenario 2 is the only scenario here that calls `add_component` many times per
entity (32 calls vs 1-2 elsewhere), it was also the only one where the runtime multiply showed
up as measurable cost. Re-run back-to-back against a binary built from the pre-fix commit
(`2e8268c`) on this same machine in this same session: setup dropped from 40.7/40.4/41.2 ms to
21.3/20.4/20.7 ms (view) and 39.5/39.6/40.2 ms to 19.7/21.3/20.0 ms (group) across three
alternating passes — back in line with the 7/9/2026 baseline, confirming the fix and ruling out
machine noise as the explanation for either the original regression or the recovery. Iteration
cost is unaffected either way, as expected — the hot loop never called `add_component`.

## Scenario 3 — Structural churn: 10% despawn+respawn/frame + movement (100k entities, 100 frames)

| Library | total | ms/frame | ns per churn-op | last-entity x |
|---------|-------|----------|-----------------|---------------|
| ODE_ECS (iterator) | 55.0 ms | 0.55     | 27.5     | 10 |
| ODE_ECS (batch)    | 51.0 ms | 0.51     | 25.5     | 10 |
| ODE_ECS (group)    | **50.5 ms** | **0.51** | **25.2** | 10 |
| moecs              | 116.1 ms | 1.16    | 58.1     | 9  |
| odecs              | 180.2 ms | 1.80    | 90.1     | 10 |

The group variant remains the fastest here, though this session it's essentially tied with the
batch view (~1% apart, down from the ~6-10% edge seen in the 7/9 and earlier 7/24 runs) — within
normal run-to-run variance for a gap this small; nothing about the fix commit touches this hot
path (churn calls `remove_component`/`add_component` once per op either way, and `size_of(T)`
folding helps a fixed-size call site regardless of variant). Membership never actually toggles
in this workload (every despawned entity is immediately respawned with both components), so the
group pays exactly one swap per create/destroy — the same row movement the table's own
tail-swap already performs — but skips the view's separate per-row pointer-record maintenance
and its per-frame alignment re-check entirely, since `group_dense_slice` needs neither.

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
| ODE_ECS | **1.5 ms** | **6.3** | 16.1    | **1.3** | **0.13 ms** | **10 MB** |
| moecs   | 13.4 ms    | 251.4   | **2.9** | 7.0     | 0.80 ms     | 16 MB     |
| odecs   | 105.0 ms   | 206.0   | 2,327.2 | 5.4     | 9.56 ms     | 19 MB     |

`Group` doesn't apply to this scenario: it owns plain `Table`s to enforce component-set
alignment, while parent/child links live in ODE_ECS's separate `Relations_Table` structure —
a different mechanism entirely, with its own intrusive-array design (see the discussion
above the table).

ODE_ECS re-parents ~33-40x faster than either archetype library and walks ancestor chains
~4-5x faster: `Relations_Table` is flat intrusive arrays indexed by entity index (`parent`,
`first_child`, doubly-linked siblings), so every link/unlink is a handful of array writes.
moecs must linear-search the old parent's dynamic `targets` array to unlink
(`unordered_remove` after `linear_search`) and `slice.contains`-check the new parent's —
arrays that grow to hundreds of children under this churn. odecs pays a different price for
the same op: a re-parent is a *structural archetype move* (drop the old `(ChildOf, parent)`
pair component, add the new one — two archetype transitions under `Exclusive`), landing at
206 ns/op, noticeably faster than moecs's 251 ns but still the same order of magnitude, both
well above ODE_ECS's array-write cost. Cascade destroy is where the pair encoding hurts most:
every `remove_entity` in odecs linearly scans all archetype signatures (~10k of them here, one
per distinct parent) looking for cascade dependents, so destroying the 5,550-entity subtrees
costs 9.56 ms vs ODE_ECS's 0.13 ms (iterative deepest-first BFS over intrusive links) and
moecs's 0.80 ms. The honest counterpoints: moecs reads a children list ~6x faster than
ODE_ECS because `children()` returns a direct slice of its stored dynamic array, whereas
ODE_ECS's `children_of` walks the sibling linked list (cache-unfriendly) and copies ids into
a scratch buffer. odecs has no children accessor at all — enumerating children *is* a query
(term decode + context build + hash + cache lookup per call, ~10k distinct cached queries
here), which is why its children reads cost ~2.3 µs, ~145x ODE_ECS. Its 5.4 ns ancestor hop
(archetype-signature scan for the `ChildOf` pair) sits between ODE_ECS's 1.3 ns array read
and moecs's 7.0 ns. Also note the features are not equivalent: ODE_ECS pays for an always-on
cycle check on every `set_parent` (the others perform none — cycles are the user's problem)
but supports only single-parent parent/child, while moecs and odecs support multi-target and
typed relations with data (odecs additionally gets relational *queries* — "all children of X"
composes with any other term). In this run all five scenarios were measured back-to-back in
a single session, all three libraries alternating within each pass.

## Scenario 5 — Random mixed-component churn: 5 component sizes, sparse membership (100k entities, added 7/24/2026)

Five component types with deliberately uneven sizes — `C0` 32B, `C1` 64B, `C2` 196B, `C3` 386B,
`C4` 500B — instead of the uniform 16-byte structs every earlier scenario uses. 100k entities
are created, each independently getting a random 1-5 of the 5 types (not a fixed combination);
10k random entities then get one random missing component added, 10k random entities get 1-5
random components removed (a no-op per component they didn't have), and 10k random entities
are destroyed. The final benchmark queries entities that have *at least* `C2`, `C3`, `C4`
(24,917 of the 90k survivors match) and runs a 3-component combine (`C3 += C2; C3 += C4`) for
100 frames. This is the first scenario with genuinely heterogeneous per-entity membership and
the first random (rather than hand-arranged) workload in this repo — fairness across the four
programs (ODE_ECS View, ODE_ECS Group, moecs, odecs) is structural, not incidental: all four
import a shared `scenario5_gen` package that precomputes the entire schedule (every entity's
starting components, every add/remove/destroy target) once from a fixed seed, so every program
executes byte-identical work. All four report the same `x=317613314` checksum, confirming it.

| Library | setup | add ns/op | remove ns/op | destroy (10k) | iter/frame | ns/ent/frame | matched | live mem |
|---------|-------|-----------|--------------|---------------|------------|--------------|---------|----------|
| ODE_ECS (view)  | **5.0 ms** | 31.0    | 108.9   | 1.96 ms | 9.2 ms  | 3.71     | 24,917 | 124 MB    |
| ODE_ECS (group) | 5.7 ms     | 47.7    | 150.5   | 2.13 ms | **3.8 ms** | **1.51** | 24,917 | **121 MB** |
| moecs           | 25.5 ms    | 53.8    | **75.0**| **0.29 ms** | 28.8 ms | 11.56 | 24,917 | 128 MB    |
| odecs           | 2,587.5 ms | 9,893.8 | 406.7   | 2.27 ms | 4.1 ms  | 1.65     | 24,917 | **72 MB**  |

The headline number is odecs's add-phase: 9.9 *microseconds* per op, ~185-320x the other three
variants (31.0-53.8 ns).
Scenario 5 is the first workload where a single structural change can migrate an entity across
components as large as 500 bytes — every `add_component`/`remove_component` in odecs is an
archetype move (copy every existing component the entity has, up to ~1.2 KB worst case, into a
newly-indexed archetype table), and unlike scenarios 0-3's uniform 16-byte payloads, that copy
cost now scales with the actual component sizes involved. Its setup cost (2.6 s for 100k
entities) is proportionally the worst this repo has measured, consistent with the same cause:
every entity's initial 1-5 components are added one at a time, each a fresh archetype move.
ODE_ECS and moecs don't pay this because neither relocates existing component data on a
structural change — ODE_ECS's `Table`s are independent per-type arrays (an add/remove is one
row in the affected table only) and moecs's per-entity chunk already reserves room for every
registered component regardless of which are populated.

ODE_ECS's `View` vs `Group` trade-off reproduces exactly as scenarios 1-3 predict, just sharper:
`Group` costs ~1.5x more per add and ~1.4x more per remove (every membership-affecting
mutation now pays a swap across three tables whose rows are up to 500 bytes each, not the
16-byte payloads of earlier scenarios), but iterates ~2.5x faster (1.51 vs 3.71 ns/ent/frame)
since `group_dense_slice` never re-verifies alignment — this is the first scenario where the
`Group`'s owned set is a genuine minority of a randomly-membershipped population rather than
"every entity, always," and the trade still holds. moecs sits in the middle on structural ops
(53.8 / 75.0 ns, cheaper than ODE_ECS's Group and pricier than its View — its deferred
`perform()` rebuild doesn't care about payload size the way an immediate archetype-copying
move does) but its iteration cost (11.56 ns/ent/frame) is the highest of the three, in line
with scenario 2's finding that its AoS chunk layout degrades as registered-but-unused component
types accumulate around the ones actually read.

# What the scenarios reveal

**1. SoA iteration is flat vs component-type count; moecs degrades.** From 1 -> 2 -> 32
registered component types, ODE_ECS's per-entity cost through the same-API iterator moves
0.29 -> 0.61 -> 0.58 ns (the 1->2 step is just the extra Velocity stream; 2->32 is flat) — its
SoA layout means iterating `{Position, Velocity}` only ever touches those two dense arrays no
matter how many other component types exist. The `Group`/`group_dense_slice` path stays right
at that same floor, 0.30 -> 0.30 ns, because it carries no per-row fallback machinery to begin
with (see point 6) — this session it lands essentially level across both scenarios it's
measured in. odecs is noisier this session than architecture alone predicts (0.33 -> 0.50 ->
0.40), but every value sits in the same sub-nanosecond band regardless of type count: its
archetype stores each component as a separate column, so the movement sweep touches only 2 of
the 32 columns no matter how many exist. moecs goes 3.33 -> 4.31 -> 7.22 ns, a ~68% slowdown
from 2 to 32 types, because (a) each `get_mut` strides into a now-512-byte AoS chunk, so the
two fields you want share cache lines with 30 unused components, and (b) the `component_index`
typeid scan (`component.odin:38`) is now over 32 entries. The gap widens from ~7x to ~12x (or,
group vs moecs, ~14x to ~24x) exactly as the architecture predicts as a game grows more
component types.

**2. The dense fast path makes View overhead disappear — Group removes the check itself.**
Before the 7/2/2026 optimization, ODE_ECS's `Iterator` walked per-row records of
`{entity_id, component pointers}` (~24 extra bytes streamed per entity per frame). Now,
whenever the view is dense-aligned — the common case, verified incrementally with O(tables)
work per structural change and a lazy early-abort rescan — the iterator reads `table.rows[i]`
directly. Scenario 0 shows the result: view iteration (0.29 ns) is indistinguishable from raw
table iteration (0.30 ns). `view_dense_slice` goes one step further and hands the user the raw
slices in view-row order; a plain loop over them measured 0.30 ns in a quieter prior session
and lands at the same 0.30 ns this run — see Method notes on drift for why that match is itself
partly luck — close to the standalone raw-SoA floor measured outside any ECS — and scenario 1
shows odecs's ordinary query loop in the same neighborhood (0.50 ns this session), because an
archetype's columns are aligned by construction even though the exact numbers moved around
more than usual this run. `Group` goes one step
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

**4. Churn: ODE_ECS is ~2x faster than moecs, ~3x faster than odecs — Group ties the batch
view this session.** moecs's deferred-mutation model exists to make structural changes *safe*
during iteration, not necessarily *fast*. ODE_ECS's immediate tail-swap costs ~28 ns per
despawn/respawn op (iterator), ~25 ns with a `Group` owning the tables, vs moecs's ~58 ns
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
the table would have paid anyway, and comes out roughly tied with the batch view this session
(both skip most of the view's separate bookkeeping cost differently — see scenario 3). The
`x=10` vs `x=9` in the output is not an error — it is moecs's
1-frame deferral made visible: ODE_ECS and odecs apply churn immediately so the respawned
entity is updated the same frame; moecs archetypes it at end-of-frame, so it starts updating
next frame. That deferral is the price and the feature (you can safely despawn
mid-system-iteration in moecs; in ODE_ECS you must follow the "don't mutate while iterating"
rule, or use `pause_tail_swap` which also defers group maintenance; odecs defers automatically
only when you mutate *during* a query iteration).

**5. Entity creation spans two orders of magnitude.** Setting up 1M two-component entities:
ODE_ECS 15.3-17.3 ms depending on variant, moecs 735 ms, odecs 6,335 ms. ODE_ECS preallocates
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
(scenario 1: 15.3 ms) undercuts plain `View` setup (17.3 ms), and group churn (scenario 3:
25.2 ns/op) is essentially tied with batch-view churn (25.5 ns/op) this session — because in
all three, a `View` isn't
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
paths (0.30-0.50 ns/ent/frame this session, scenario 1 — noisier than the 0.29-0.31 ns tie
measured 7/9/2026, see Method notes) and stays flat as component-type count grows, leaving
moecs ~12-24x behind at 32 types depending on which ODE_ECS variant you compare. ODE_ECS's
dense fast path earns its keep by delivering that floor *through a stable iterator API with a
transparent fallback*, rather than by construction-only guarantees; `Group` delivers the same
floor with *no* fallback machinery at all, and in these scenarios that turns out to cost
nothing extra on churn or setup any more — the 32-type setup cost flagged in the earlier 7/24
pass was a compiler-codegen issue in `add_component`'s row-pointer arithmetic, now fixed (see
scenario 2) — so `Group` is now a strict improvement over `View` on every axis measured here
whenever membership is stable, which scenarios 1-3 all are. On *structural operations*, ODE_ECS
is decisively fastest across the board: ~48x (moecs) to ~410x (odecs) faster setup in the
2-component scenario, ~2-3x faster churn (roughly tied with `Group` this session), ~33-40x
faster re-parenting, ~6-74x faster cascade destroy. odecs concentrates its costs exactly there —
variadic per-entity creation, archetype moves for every pair change, all-archetype scans on
delete, and query-shaped children reads (~2.3 µs vs 16.1 ns/2.9 ns) — while winning
dense-memory footprint outright in scenarios 0 and 2 (odecs's `View`-based numbers are leanest
there; ODE_ECS's `Group` closes much of the gap in scenario 1, see point 3). moecs's wins
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
- This is a **same-day follow-up run**, not a fresh multi-session comparison: moecs
  (`ccd00f2`) and odecs (`e3ca0a5`) were not re-fetched or rebuilt — they're unchanged from the
  earlier 7/24/2026 pass — but every binary (including theirs) was rerun fresh this session
  rather than reusing that pass's numbers, since absolute timings drift between sessions (see
  below) and mixing an old pass with a new one would misattribute noise as a real delta. Only
  ODE_ECS's binaries were rebuilt, from the new commit.
- **The scenario 2 setup regression flagged in the earlier 7/24/2026 pass is fixed.** That run
  found ODE_ECS's scenario 2 (32 component types) setup had roughly doubled since 7/9/2026
  (19.6-19.7 ms -> 36.9-38.8 ms), reproduced with `ECS_VALIDATIONS=false`, and flagged it for
  the maintainer to profile. The maintainer bisected it to `table_raw__rid_to_ptr` reading
  `self.type_info.size` off the `Table_Raw` struct on every `add_component`/`remove_component`/
  `pack` call — a runtime field load that blocks the row-pointer multiply from being folded to
  a shift, even for generic-typed callers where `size_of(T)` is a compile-time constant — and
  pushed a fix in commit `5c5671c` ("Churn optimization") the same day: an explicit
  `elem_size` parameter on `_sized` variants of those functions, with the typed API passing the
  compile-time constant and type-erased callers (`Command_Buffer`, `Group`) still passing the
  runtime field, unchanged. Verified by building both the pre-fix (`2e8268c`) and post-fix
  (`5c5671c`) commits into separate binaries and running them back-to-back, three alternating
  passes, in this same session: scenario 2 setup dropped from 39.5-41.2 ms to 19.4-21.3 ms
  across both the `View` and `Group` variants, recovering the 7/9/2026 baseline. Nothing else
  in `add_component`'s behavior changed — iteration cost, memory, and every other scenario were
  unaffected, as expected for a change confined to pointer arithmetic.
- moecs is at commit `ccd00f2` (up from `8d50786` as of 7/9/2026; the four commits since are
  README-only, no source changed). odecs is unchanged at `e3ca0a5` since 7/5/2026. Numbers in
  the earlier 7/24/2026 pass drifted upward by a similar proportion across *all three*
  libraries relative to 7/9/2026, which read as machine noise rather than a regression anywhere
  except the scenario 2 case above; this pass's numbers are, again, not directly comparable to
  either prior session's — every table above was refreshed from this session's own back-to-back
  run.
- No new binaries this run besides ODE_ECS's; the `Group` variants (`ode_group`,
  `ode_many_group`, `ode_churn_group`) were added 7/9/2026 and are carried forward, rebuilt
  against the new commit. `Group` needs no
  counterpart in moecs or odecs — it's an ODE_ECS-specific mechanism for enforcing (not just
  detecting) dense alignment over a fixed set of owned tables; the other two libraries'
  archetype/chunk storage gets the equivalent guarantee by construction, which is exactly why
  their numbers already sit at the same floor without a comparable API.
- All workloads verified correct via a checksum (`x` value) that also defeats dead-code
  elimination, identical across libraries per scenario. (`ode_one` reports x=400 because it
  runs the same 100 frames twice — once through the table, once through the view; `moecs_one`
  and `odecs_one` run them once, x=200. All three relations programs print x=13120122 and
  destroy exactly 5,550 entities.)
- ODE_ECS results were previously confirmed identical with `ECS_VALIDATIONS=false` on the
  iteration and churn paths (scenario 1, prior session), and the scenario 2 setup regression
  fixed this session was itself confirmed to reproduce with validations off before being
  bisected to the pointer-arithmetic issue above — so "validations cost nothing" should be read
  as "on these hot loops specifically," not as a blanket guarantee for every structural path.
  Not re-checked with validations off this session.
- The raw-SoA floor (0.30 ns/ent/frame for scenario 1's access pattern on this machine) was
  measured in a prior, quieter session with a standalone Odin program iterating two plain
  slices, outside any ECS; it was not re-measured this session. Scenario 0's access pattern
  (read+write one array) has a different, slightly lower floor, which is how ODE_ECS's `View`
  path posting 0.29 ns there (faster than the 0.30 ns raw-SoA figure quoted for scenario 1's
  two-array pattern) is possible.
- The odecs benchmarks call `free_all(context.temp_allocator)` once per frame (outside the
  timed relations sections): odecs allocates per-call scratch (query terms, `add_entity`
  bookkeeping) from the temp allocator and expects the host loop to reset it, so this is its
  intended usage, not overhead added to it.
- Movement is ODE_ECS's home turf; moecs does more per-frame bookkeeping by design (deferred
  actions, archetype re-filtering) to support features not exercised here.
