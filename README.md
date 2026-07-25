# Note:

These results are expected purely because of architectural differences: moecs and odecs use
pure archetype (one SoA table per unique component signature) storage, while ODE_ECS is
primarily a relational-database-style engine — independent per-component `Table`s plus `View`s
that join them — which as of July 2026 also offers an opt-in true-archetype table, `Arch_Table`,
for component sets that always travel together on the same entities.

All tests were generated automatically by Claude AI, and the conclusions below were also made by the AI without any human intervention.

ODE_ECS link: [https://github.com/odin-engine/ode_ecs](https://github.com/odin-engine/ode_ecs)

moecs link: [https://github.com/helioscout/moecs](https://github.com/helioscout/moecs)

odecs link: [https://github.com/NateTheGreatt/odecs](https://github.com/NateTheGreatt/odecs)

Features comparison is here: [features.md](https://github.com/zm69/ecs_bench/blob/main/features.md)

# Benchmark results: ODE_ECS vs moecs vs odecs (as of July 25, 2026, Arch_Table added)

Same machine, `-o:aggressive`, same tracking-allocator harness (`mem.Tracking_Allocator`,
`current_memory_allocated` after setup). ODE_ECS moved from
https://github.com/odin-engine/ode_ecs commit `5c5671c` to `df5a975` — the headline addition is
`Arch_Table`, a true-SoA archetype table (see below); moecs (`ccd00f2`) and odecs (`e3ca0a5`)
were re-checked and are unchanged upstream since the last run, so their binaries were reused
as-is, but every binary, including theirs, was rerun fresh this session (medians of 3 passes,
all binaries alternating
within each pass) rather than reusing older numbers, since absolute timings drift between
sessions (see Method notes) and mixing passes would misattribute noise as a real delta. Each
library uses its idiomatic fast path: ODE_ECS via direct table iteration, `View` + `Iterator`,
`view_dense_slice`, an owned `Group` + `group_dense_slice`, or (new) `Arch_Table` +
`arch_table__dense_slice`; moecs via an `ARCHETYPE` system driven by `progress()`; odecs via a
per-frame `query` + `get_table` batch loop over its archetype columns (the pattern its own
docs and bundled benchmarks use).

## What's new: `Arch_Table`

`Arch_Table` is ODE_ECS's own true-archetype table: N component columns sharing **one** shared
row index (`eid_to_rid`/`rid_to_eid`), so a row's every column is added, removed, and swapped as
a single unit — one `arch_table__swap_rows` call moves the whole row's bytes across every
column in one pass, instead of a `Group`-of-plain-`Table`s' N separate
`table_raw__swap_rows` calls (one per owned table) for the same entity transition. Iteration
goes through `Arch_Iterator` (`ecs.next(&it, T1, ..., T7)`, column indices resolved once and
cached) or, when every column is wanted as a flat slice, `arch_table__dense_slice` — always
valid, no alignment check, since an archetype's own rows are packed by construction.

The trade is the one the library's own docs are explicit about: **membership is whole-row,
all-or-nothing** — there is no `add_component`/`remove_component` for one column of an
`Arch_Table`, only `arch_table__add_entity`/`arch_table__remove_entity` for the entire row.
That makes it a strict upgrade over a `Table`-only `Group` wherever a fixed component set is
static per entity (added once, removed only by destroying the whole entity), and a poor fit
wherever entities gain/lose *individual* components from that set while alive — the workload
scenario 5 exercises. Per the task that produced this run: **use an `Arch_Table` + plain
`Table` mix where appropriate** — bundle the components that always travel together into one
archetype row, and leave components with independent lifetimes as ordinary `Table`s, exactly as
scenario 2's `ode_many_arch` does (`Position`+`Velocity` as one `Arch_Table` row, the other 30
types as 30 separate `Table`s the archetype never touches).

Three new binaries exercise it: `ode_arch` (scenario 1, a pure 2-column archetype — no `Table`
needed at all, since both components are always present), `ode_many_arch` (scenario 2, the
`Arch_Table`+`Table` mix above), and `ode_churn_arch` (scenario 3, whole-entity despawn/respawn
churn — `Arch_Table` handles this natively since each churn op destroys/creates the *entire*
row, never toggles one column on a live entity). It is **not** used in scenario 0 (single
component — an archetype of one column is identical to a plain `Table`, same reasoning
Group's docs give for skipping that scenario), scenario 4 (relations track only `Position`,
same single-column reasoning, and parent/child links live in a separate `Relations_Table`
mechanism entirely orthogonal to component storage), or scenario 5 (every entity's component
set is randomly assembled *and* mutated component-by-component via live
`add_component`/`remove_component` churn — precisely the pattern a fixed-column archetype
cannot represent without a distinct archetype per combination and automatic migration between
them, which `Arch_Table` does not provide).

ODE_ECS's `Group` (added 7/9/2026) and the dense-view fast path (added 7/2/2026) are both
carried forward unchanged this run — see the earlier sections of this README's history for
their design; this session re-measures them fresh alongside the new `Arch_Table` variants.

Benchmark sources live under `G:\odin\ecs_bench\`:
`ode_one`, `moecs_one`, `odecs_one` (scenario 0); `ode`, `ode_batch`, `ode_group`, `ode_arch`,
`moecs_bench`, `odecs_bench` (scenario 1); `ode_many`, `ode_many_group`, `ode_many_arch`,
`moecs_many`, `odecs_many` (scenario 2); `ode_churn`, `ode_churn_batch`, `ode_churn_group`,
`ode_churn_arch`, `moecs_churn`, `odecs_churn` (scenario 3); `ode_relations`,
`moecs_relations`, `odecs_relations` (scenario 4); `ode_mixed`, `ode_mixed_group`,
`moecs_mixed`, `odecs_mixed`, plus the shared `scenario5_gen` schedule generator (scenario 5).
All numbers are medians of 3 runs, all binaries alternating within each pass.

## Scenario 0 — Single component: pure table iteration (1M entities, 100 frames)

Each entity has one `Position{x,y:f64}`; per frame `pos.x += pos.y`. This isolates raw
iteration with no multi-component lookup at all — ODE_ECS iterates the `Table` directly via
`ecs.table_dense_slice(&positions)` (see fix note below), moecs runs a one-component archetype
system, odecs sweeps its single archetype's `Position` column via `get_table`. No `Arch_Table`
variant: an archetype with one column is the same layout as a plain `Table`.

| Library | setup | iter/frame | ns/ent/frame | live mem |
|---------|-------|------------|--------------|----------|
| ODE_ECS (table)      | **14.9 ms** | **0.22 ms** | **0.22** | 76 MB     |
| ODE_ECS (view+iter)  | —           | 0.28 ms | 0.28     | —     |
| moecs                | 699.3 ms    | 3.17 ms | 3.17     | 168 MB    |
| odecs                | 3,372.9 ms  | 0.23 ms | 0.23     | **51 MB** |

**Fix landed this session: raw `Table` iteration is now the fastest single-component path,
not the slowest.** An earlier pass of this README (same day) measured ODE_ECS's raw `Table`
iteration at 0.31 ns/ent/frame — *slower* than both its own `View`+`Iterator` (0.28 ns) and
odecs (0.23 ns), which was surprising enough to investigate. The cause turned out to be a real,
reproducible compiler-codegen issue, not noise (confirmed 20/20 across repeated passes): the
benchmark's loop read `positions.rows` — a **field access on a live struct** — directly inside
`for &p in positions.rows { p.x += p.y }`. The optimizer cannot prove a write through the
loop's element pointer `&p` doesn't alias `positions` itself, so it conservatively reloads the
`rows` slice pointer from the `Table` struct after *every* store, verified directly in the
compiled assembly (`-build-mode:asm`): a redundant `movq <offset>(%rcx), %r11` before each of
the loop's two unrolled elements, on every iteration. odecs's equivalent loop iterates a local
slice variable returned by `get_table` (not a field access), so LLVM keeps the pointer in a
register for the whole loop — no reload, no aliasing ambiguity. The library now exposes
`table__dense_slice`/`ecs.table_dense_slice` (mirroring `view_dense_slice`/`group_dense_slice`/
`arch_table__dense_slice` for the other three table types) — it returns `rows` by value from a
call, giving the caller a fresh local slice with no aliasing back to the `Table`, which is
enough on its own (even `#force_inline`d) to eliminate the reload. `ode_one`'s hot loop was
updated to use it; the fix requires no user-facing behavior change, only 12 new lines of
library code (`table.odin`/`ecs.odin`), and all 182 existing library tests still pass. Verified
with a 20-pass A/B before landing the fix (20/20 odecs-faster) and a 10-pass rerun after
(ODE_ECS table median 0.220 ns vs odecs's noisier-this-run 0.245 ns median, 0.22-0.42 range).

ODE_ECS now iterates a single component ~14x faster than moecs (previously ~10x) and ties or
slightly beats odecs outright, while both remain at the same read+write-16-bytes-per-entity
memory floor; odecs keeps the leanest footprint (51 MB). moecs pays per-entity `get_mut`
(typeid lookup + chunk indexing) plus per-frame system dispatch even in the simplest possible
case. The catch on odecs's side is the other column: it takes 3.4 *seconds* to create 1M
entities (~226x ODE_ECS, ~4.8x moecs) — every `add_entity` funnels components through a
variadic `..any` path with per-call temp-allocator bookkeeping and typeid→ComponentID map
lookups.

## Scenario 1 — Movement, 2 component types (1M entities, 100 frames)

Each entity has `Position{x,y:f64}` + `Velocity{x,y:f64}`; per frame `pos += vel`.

| Library | setup | iter/frame | ns/ent/frame | live mem |
|---------|-------|------------|--------------|----------|
| ODE_ECS (iterator)             | 17.3 ms     | 0.59 ms | 0.59     | 103 MB    |
| ODE_ECS (`view_dense_slice`)   | 16.7 ms     | 0.30 ms | 0.30     | 103 MB    |
| ODE_ECS (`group_dense_slice`)  | 15.3 ms     | 0.31 ms | 0.31     | 83 MB     |
| ODE_ECS (`arch_table__dense_slice`) | **13.6 ms** | **0.29 ms** | **0.29** | **72 MB** |
| moecs                          | 722.9 ms    | 4.19 ms | 4.19     | 184 MB    |
| odecs                          | 6,260.8 ms  | 0.30 ms | 0.30     | 66 MB     |

`Arch_Table` is the new leader on every column here, and by construction rather than by
enforcement. There is nothing to detect or maintain: `Position` and `Velocity` are two columns
of one archetype row from the moment the entity is created, so `arch_table__dense_slice` is
just "read the two columns" — no view subscriber records (`View`), no owned-table bit-subset
check (`Group`), not even a second index array (`Group` still keeps `positions.eid_to_ptr` and
`velocities.eid_to_ptr` as two separate `Table`s; `Arch_Table` keeps one `eid_to_rid`/
`rid_to_eid` pair shared by both columns). That's also the whole memory story: 72 MB vs the
`Group`'s 83 MB is exactly one fewer index-array pair over 1M entities. Setup is fastest too —
`arch_table__create_entity` is one call that zero-initializes both columns' row at once, versus
two separate `add_component` calls (plus, for `Group`, a bit-subset check and swap on the
second one). ODE_ECS vs moecs: ~53x faster setup, ~14x faster iteration on the fast paths;
odecs's ordinary documented query loop (0.30 ns) ties `Arch_Table` on iteration this session
but still costs 6.3 *seconds* to set up 1M entities (~460x `Arch_Table`'s 13.6 ms) — two
components per entity doubles its per-`add_entity` type-resolution work.

## Scenario 2 — Many component types: 32 types, all on every entity (250k entities, 100 frames)

Every entity has all 32 component types (identical 16-byte shape); movement still touches
only 2 of them.

| Library | setup | iter/frame | ns/ent/frame | live mem |
|---------|-------|------------|--------------|----------|
| ODE_ECS (view)                    | 19.4 ms     | 0.15 ms | 0.58     | 226 MB     |
| ODE_ECS (group, 2/32)             | 20.4 ms     | 0.08 ms | 0.30     | 221 MB     |
| ODE_ECS (arch, 2 arch + 30 table) | 19.7 ms     | 0.08 ms | 0.31     | **218 MB** |
| moecs                             | 98.0 ms     | 1.77 ms | 7.07     | 160 MB     |
| odecs                             | 7,010.0 ms  | 0.08 ms | 0.31     | 131 MB     |

`ode_many_arch` is the `Arch_Table`+`Table` mix the maintainer asked this run to demonstrate:
`Position`+`Velocity` live together in one `Arch_Table` row, and the other 30 (functionally
inert here) types stay as 30 separate `Table`s the archetype never looks at — direct analogue
of `ode_many_group`'s "own only 2 of 32 tables" split, but the 2 hot columns are now physically
interleaved into one archetype row rather than kept in lockstep across two independently-swapped
`Table`s. Iteration comes out essentially tied with `Group` (0.30 vs 0.31 ns — within this
session's noise) since both read exactly two dense arrays regardless of the other 30 types;
memory is slightly leaner (218 vs 221 MB — one shared index pair for the 2 hot columns instead
of two independent ones). Setup is a wash against both `View` and `Group` here: all three pay
for the same 32 per-entity structural calls (30 plain `add_component`s either way), only the
first 2 differ in mechanism. The real `Arch_Table` win in this scenario would show up in a
setup-only variant where the archetype holds *all* 32 columns (one `arch_table__create_entity`
call instead of 32 `add_component` calls) rather than only the 2 iterated ones — not measured
here since the point of this mix is to mirror `Group`'s "own only what you iterate" pattern,
not to re-litigate scenario 0/1's entity-creation story at a larger column count.

## Scenario 3 — Structural churn: 10% despawn+respawn/frame + movement (100k entities, 100 frames)

| Library | total | ms/frame | ns per churn-op | last-entity x |
|---------|-------|----------|-----------------|---------------|
| ODE_ECS (iterator) | 54.0 ms | 0.540    | 27.0     | 10 |
| ODE_ECS (batch)    | 51.9 ms | 0.519    | 26.0     | 10 |
| ODE_ECS (group)    | 48.7 ms | 0.487    | 24.3     | 10 |
| ODE_ECS (arch)     | **28.8 ms** | **0.288** | **14.4** | 10 |
| moecs              | 114.9 ms | 1.149   | 57.5     | 9  |
| odecs              | 177.6 ms | 1.776   | 88.8     | 10 |

This is where `Arch_Table` earns the biggest single margin in the whole suite: **~1.7x faster
than `Group`, ~1.8x faster than the batch `View`**, on a workload — whole-entity
despawn+immediate-respawn — that both alternatives already handle about as well as ODE_ECS's
sparse-dense design gets. Every churn op here destroys an entity's *entire* row and creates a
fresh one, never toggles a single component on a live entity, so `Arch_Table` (whole-row
add/remove is its native operation) pays no penalty for its all-or-nothing membership rule.
What it *saves* relative to `Group`: a `Group` owning `positions`+`velocities` still pays two
separate `table_raw__swap_rows` calls (one per owned `Table`) for every membership transition
plus a bit-subset membership check; `arch_table__remove_entity`/`arch_table__add_entity` move
both columns' bytes in **one** `arch_table__swap_rows` pass over a single shared index, and —
since no `View` is subscribed to a standalone `Arch_Table` in this benchmark — there is no
per-row pointer-record notification path to maintain either, the cost the batch `View` variant
still carries. ODE_ECS's `Arch_Table` churns ~4x faster than moecs and ~6.2x faster than odecs;
even the *slowest* ODE_ECS variant here (the plain iterator, 27.0 ns/op) already beats both.

## Scenario 4 — Entity relations: parent/child tree churn (100k entities)

Exercises each library's entity-relations feature. 100k entities with a `Position` are linked
into a 10-ary forest (100 roots, depth ~4). Per frame (x100): 10k leaf re-parents, 10k
children-list reads, 10k ancestor walks to the root; then 50 depth-1 subtrees
(5,550 entities) are cascade-destroyed. ODE_ECS uses `Relations_Table`
(`set_parent` / `children_of` / `parent_of` / `destroy_entity(..., destroy_children=true)`);
moecs uses `ChildOf`/`ParentOf` relations (`unrelate`+`child_of` for a re-parent, `children`,
`parent`, `despawn` which cascades to single-parent children); odecs uses flecs-style
`ChildOf` *pairs* with the `Exclusive` trait (so one `add_pair` re-parents, auto-dropping the
old parent) and the `Cascade` trait (so `remove_entity` on a parent deletes descendants). All
three programs do identical logical work verified by an identical checksum (x=13120122). No
`Arch_Table` variant: this scenario tracks a single component (`Position`), the same
one-column-equals-plain-`Table` reasoning scenario 0 gives, and the relations themselves live
in ODE_ECS's separate `Relations_Table` structure, entirely orthogonal to which table type
backs `Position`.

| Library | setup | reparent ns/op | children ns/op | ancestor ns/hop | cascade destroy | live mem |
|---------|-------|----------------|----------------|-----------------|-----------------|----------|
| ODE_ECS | **1.5 ms** | **6.2** | 17.1    | **1.3** | **0.12 ms** | **10 MB** |
| moecs   | 13.5 ms    | 249.6   | **2.8** | 6.7     | 0.67 ms     | 16 MB     |
| odecs   | 102.5 ms   | 197.3   | 2,268.8 | 5.3     | 9.66 ms     | 19 MB     |

ODE_ECS re-parents ~32-40x faster than either archetype library and walks ancestor chains
~4-5x faster: `Relations_Table` is flat intrusive arrays indexed by entity index, so every
link/unlink is a handful of array writes. moecs must linear-search the old parent's dynamic
`targets` array to unlink and `slice.contains`-check the new parent's. odecs pays a different
price: a re-parent is a *structural archetype move* under `Exclusive` (drop the old
`(ChildOf, parent)` pair component, add the new one), landing at 197 ns/op — faster than
moecs's 250 ns but still the same order of magnitude, well above ODE_ECS's array-write cost.
Cascade destroy is where the pair encoding hurts most: every `remove_entity` in odecs linearly
scans all archetype signatures for cascade dependents, costing 9.66 ms vs ODE_ECS's 0.12 ms
and moecs's 0.67 ms. The honest counterpoint: moecs reads a children list ~6x faster than
ODE_ECS because `children()` returns a direct slice of its stored dynamic array, whereas
ODE_ECS's `children_of` walks the sibling linked list and copies ids into a scratch buffer;
odecs has no direct children accessor at all — enumerating children *is* a query, which is why
its children reads cost ~2.3 µs, ~133x ODE_ECS's.

## Scenario 5 — Random mixed-component churn: 5 component sizes, sparse membership (100k entities)

Five component types with deliberately uneven sizes — `C0` 32B, `C1` 64B, `C2` 196B, `C3` 386B,
`C4` 500B. 100k entities are created, each independently getting a random 1-5 of the 5 types;
10k random entities then get one random missing component added, 10k random entities get 1-5
random components removed, and 10k random entities are destroyed. The final benchmark queries
entities that have *at least* `C2`, `C3`, `C4` (24,917 of the 90k survivors match) and runs a
3-component combine for 100 frames. All four programs (ODE_ECS View, ODE_ECS Group, moecs,
odecs) import a shared `scenario5_gen` package that precomputes the entire schedule once from a
fixed seed, so every program executes byte-identical work; all four report the same
`x=317613314` checksum. **No `Arch_Table` variant**: this is precisely the workload `Arch_Table`
cannot represent — each entity's component set is not just heterogeneous but *mutated
component-by-component* on live entities (an add or remove here touches one of the 5 types
independently, not the whole row), and `Arch_Table` has no per-column `add_component`/
`remove_component` at all, only whole-row `arch_table__add_entity`/`remove_entity`. A real
archetype-migration engine (what moecs and odecs already are) handles this by moving the
entity to a different archetype on every add/remove; ODE_ECS's `Arch_Table` is a single fixed
archetype and does not auto-migrate between archetypes, so mixing it in here would need a
distinct `Arch_Table` per one of the 31 possible non-empty subsets of 5 types plus manual
migration logic on every add/remove — out of scope for what "use Arch_Table + Table mix where
appropriate" is asking for; the appropriate answer for this scenario is "don't."

| Library | setup | add ns/op | remove ns/op | destroy (10k) | iter/frame | ns/ent/frame | matched | live mem |
|---------|-------|-----------|--------------|---------------|------------|--------------|---------|----------|
| ODE_ECS (view)  | **4.3 ms** | 24.9    | 99.8    | 1.74 ms | 9.0 ms  | 3.59     | 24,917 | 124 MB    |
| ODE_ECS (group) | 5.5 ms     | 36.2    | 116.1   | 1.66 ms | **3.8 ms** | **1.52** | 24,917 | **121 MB** |
| moecs           | 24.2 ms    | 46.7    | **65.2**| **0.20 ms** | 27.3 ms | 10.96 | 24,917 | 128 MB    |
| odecs           | 2,369.0 ms | 9,920.7 | 414.4   | 2.23 ms | 4.0 ms  | 1.61     | 24,917 | **72 MB**  |

odecs's add-phase remains the headline number: ~9.9 *microseconds* per op, ~213-398x the other
three variants (24.9-46.7 ns) — every `add_component`/`remove_component` in odecs is an
archetype move (copy every existing component the entity has, up to ~1.2 KB worst case, into a
newly-indexed archetype), and this is the only scenario where that copy cost scales with real
(non-uniform) component sizes rather than a flat 16 bytes. ODE_ECS's `View` vs `Group`
trade-off reproduces scenarios 1-3's pattern, just sharper here: `Group` costs ~1.4-1.5x more
per structural op (every membership-affecting mutation swaps across three tables whose rows
run up to 500 bytes) but iterates ~2.4x faster, since `group_dense_slice` never re-verifies
alignment.

# What the scenarios reveal

**1. SoA iteration is flat vs component-type count; moecs degrades.** From 1 -> 2 -> 32
registered component types, ODE_ECS's per-entity cost through the same-API iterator moves
0.28 -> 0.59 -> 0.58 ns — its SoA layout means iterating `{Position, Velocity}` only ever
touches those two dense arrays no matter how many other component types exist. The
`Group`/`Arch_Table` fast paths stay right at that same ~0.30 ns floor across both scenarios
they're measured in. odecs's plain query loop sits in the same sub-nanosecond band regardless
of type count (0.23 -> 0.30 -> 0.31 ns) for the identical reason — its archetype stores each
component as a separate column. moecs goes 3.17 -> 4.19 -> 7.07 ns, a ~69% slowdown from 2 to
32 types: each `get_mut` strides into an increasingly crowded AoS chunk, and the
`component_index` typeid scan grows with registered-type count.

**2. Two ways to make View/Group overhead disappear: detect it away, or never let it exist.**
The dense-view fast path (7/2/2026) makes a `View`'s per-row pointer bookkeeping vanish *when*
alignment happens to hold, closing most of the gap to a raw sweep — scenario 0's `View`+
`Iterator` path (0.28 ns) sits close to raw `Table` iteration (0.22 ns; see the fix note above
for why that number, not the codegen quirk it used to carry, is the real floor). A `Group` goes
further: it *enforces* alignment so there's nothing to detect, dense or otherwise. `Arch_Table`
goes further still: there is no separate index to align in the first place, because both
columns already share one. The three sit in a strict
cost hierarchy on every axis measured here (scenario 1: iteration 0.59 -> 0.30 -> 0.31 -> 0.29
ns; memory 103 -> 103 -> 83 -> 72 MB) — not because later designs try harder, but because each
one removes an entire category of bookkeeping the previous one still had to maintain: `View`
removes per-row pointer chasing when dense; `Group` removes the alignment check entirely by
owning the tables; `Arch_Table` removes the *second table* entirely by never having separately
allocated columns to keep in lockstep.

**3. Memory: the archetype libraries win when components are universal — `Arch_Table` and
`Group` both close most of the gap.** In the dense scenarios odecs is the leanest of the three
outright (51 / 66 / 131 MB in scenarios 0/1/2). moecs beats ODE_ECS's `View` only in scenario 2
(160 vs 226 MB). But both `Group` and `Arch_Table` carry no per-entity view-subscriber
bookkeeping — in scenario 1 that drops ODE_ECS from 103 MB (view) to 83 MB (group) to 72 MB
(arch, one shared index pair instead of two independent ones), closing most of the distance to
odecs's 66 MB while still being the fastest of the four to set up and iterate. In scenario 2,
owning/archiving only the 2 tables actually iterated drops 226 MB to 221 MB (group) / 218 MB
(arch) — the other 30 `Table`s' own index overhead dominates regardless of which mechanism
queries the 2 hot ones, since it's a property of the 30 untouched tables, not the query
mechanism.

**4. Churn: `Arch_Table` is now the fastest structural-change path ODE_ECS has, by a wide
margin.** moecs's deferred-mutation model exists to make structural changes *safe* during
iteration, not fast. ODE_ECS's immediate tail-swap already beat moecs/odecs before
`Arch_Table` existed (27.0-24.3 ns/op vs moecs's 57.5 and odecs's 88.8); `Arch_Table` cuts
that further to 14.4 ns/op — one row swap across a shared index instead of `Group`'s two swaps
across two independently-indexed tables, with none of `View`'s per-row notification cost since
no `View` subscribes to it. The catch, restated from the scenario 5 discussion: this only
works because scenario 3's churn is whole-entity destroy/recreate. A workload that toggles one
of an archetype's columns on a *live* entity (impossible by construction — `Arch_Table` has no
such operation) would have to fall back to a `Table`+`View`/`Group` design, which is exactly
what scenario 5 does and exactly why it has no `Arch_Table` variant.

**5. Entity creation spans two-and-a-half orders of magnitude.** Setting up 1M two-component
entities: `Arch_Table` 13.6 ms, `Group`/`View` 15.3-17.3 ms, moecs 723 ms, odecs 6,261 ms.
`Arch_Table`'s one-call whole-row creation (`arch_table__create_entity`, one zero-init pass
over both columns) edges out even `Group`'s already-cheap "bit-subset check plus a swap that's
usually a no-op" path, because there's only one index to update instead of two. odecs routes
every `add_entity` through a variadic `..any` interface that builds a temp-allocator
component-ID array *and map* per call — the single biggest number separating these libraries,
consistent with odecs's own benchmark suite measuring entity/component ops in ops/sec rather
than a per-frame cost.

**6. Groups and Arch_Tables both enforce what Views merely detect — Arch_Table is cheaper
still when the owned set doesn't need to coexist with unrelated columns.** The textbook
EnTT-style full-owning-group trade (pay more on structural change for a flat, check-free
iteration floor) shows up as a real *win*, not a cost, in every ODE_ECS scenario measured:
group setup and churn both undercut plain `View`, because a `View` isn't free either — every
`add_component` matching a subscribed view still maintains its pointer-record fallback path,
win or lose. `Arch_Table` takes the same idea one step further by removing the *second
Table* a `Group` still has to coordinate: where `Group` enforces alignment between two
separately-allocated arrays via bit-subset checks and paired swaps, `Arch_Table` was never two
arrays to begin with. The place this ordering would reverse: an entity set whose owned-column
membership toggles on and off far more often than it's swept, where a plain `View`'s
non-moving pointer-record update would beat both `Group`'s and `Arch_Table`'s physical row
swap — none of scenarios 1-3 exercise that (component sets are stable outside whole-entity
destroy/create), and scenario 5 is precisely the case where individual-column churn is common
enough that neither `Group` nor `Arch_Table` is even offered as a candidate.

# Overall

`Arch_Table`'s arrival sharpens a story odecs's arrival already started: on *iteration*, the
SoA-layout libraries (odecs, and now ODE_ECS's `Group`/`Arch_Table` paths) converge on the same
sub-nanosecond floor regardless of registered component-type count, while moecs's AoS chunk
degrades as more types accumulate. On *structural operations*, ODE_ECS was already decisively
fastest — `Arch_Table` widens that lead further for the one workload shape it targets (a fixed
component set with no independent per-column lifetime): ~53x faster setup and ~4-6x faster
churn than moecs/odecs in scenario 1/3, cutting even ODE_ECS's own previous best (`Group`) by
roughly another third to a half. The trade is architectural, not incidental: `Arch_Table`'s
whole-row-only membership model is exactly what buys that speed, and exactly what makes it the
wrong tool for scenario 5's per-column random churn — where ODE_ECS's `View`/`Group` design
(independent `Table`s, no migration needed) and the archetype-migration libraries (moecs,
odecs — this is their home turf) remain the only real options. The practical guidance from this
run: reach for `Arch_Table` when a component set is fixed for an entity's whole lifetime and
you iterate it every frame (movement components, render-visible components, anything that
"is" the entity rather than something bolted on and off); keep sparse-dense `Table`s + `View`
or `Group` for anything with independent per-component add/remove churn; and mix the two, as
`ode_many_arch` does, when a database has both kinds of components at once.

## Method notes / caveats

- One machine, one run set (medians of 3 passes, all 27 binaries alternating within each
  pass in a single session); absolute numbers vary between sessions, but the ratios track
  the architectural differences and were stable across repeated runs.
- ODE_ECS moved from commit `5c5671c` to `df5a975` for the Arch_Table work (four commits:
  `ca30d76` "Add Arch_Table, improve API" — the substantive change, adding
  `arch_table.odin`/`arch_iterator.odin` and the Group/Command_Buffer/serialization integration
  for it — followed by three comment/formatting/text-only commits), then to `acfe11c` "Add
  table__dense_slice / ecs.table_dense_slice" for the scenario-0 codegen fix documented above,
  found and fixed later the same session. moecs (`ccd00f2`) and odecs (`e3ca0a5`) were checked
  and are unchanged upstream since the previous run; their binaries were reused as-is (not
  rebuilt) but rerun fresh this session, same as ODE_ECS's, so every number in every table above
  comes from this session's own back-to-back run.
- The scenario-0 investigation (see that section) was verified with real tooling, not just
  reasoning: `odin build -build-mode:asm` to inspect the actual compiled loop, a 20-pass A/B
  before concluding it wasn't noise (0/20 for ODE_ECS's raw `Table` path vs odecs), and a
  from-scratch isolated reproduction (a standalone `#force_no_inline` procedure with a local
  slice variable) that confirmed the fix before it was implemented as a real library API. The
  fix is purely additive — no existing API's behavior changed, and `ode_ecs/docs/tables.md`'s
  iteration example was updated to use it.
- Three new binaries this run: `ode_arch` (scenario 1), `ode_many_arch` (scenario 2, the
  `Arch_Table`+`Table` mix), `ode_churn_arch` (scenario 3) — all under `G:\odin\ecs_bench\`,
  built the same way as every other binary here (`odin build <dir> -out:<dir>/<name>.exe
  -o:aggressive`). Scenarios 0, 4, and 5 deliberately have no `Arch_Table` variant; see each
  scenario's section above for the specific architectural reason (single-column tables,
  relations being orthogonal to component storage, and per-column live churn respectively) —
  these are not gaps to fill in a future session, they're workload shapes `Arch_Table`
  structurally cannot represent any better than (or, in scenario 0/4's case, any differently
  from) a plain `Table`.
- All workloads verified correct via a checksum (`x` value) that also defeats dead-code
  elimination, identical across libraries per scenario. (`ode_one` reports x=400 because it
  runs the same 100 frames twice — once through the table, once through the view; `moecs_one`
  and `odecs_one` run them once, x=200. All three relations programs print x=13120122 and
  destroy exactly 5,550 entities. `ode_churn`/`ode_churn_batch`/`ode_churn_group`/
  `ode_churn_arch` and `odecs_churn` all report x=10; moecs_churn reports x=9 — its 1-frame
  deferral, not a bug: ODE_ECS and odecs apply churn immediately so the respawned entity is
  updated the same frame, while moecs archetypes it at end-of-frame, so it starts updating next
  frame.)
- The odecs benchmarks call `free_all(context.temp_allocator)` once per frame (outside the
  timed relations sections): odecs allocates per-call scratch (query terms, `add_entity`
  bookkeeping) from the temp allocator and expects the host loop to reset it, so this is its
  intended usage, not overhead added to it.
- Movement is ODE_ECS's home turf; moecs does more per-frame bookkeeping by design (deferred
  actions, archetype re-filtering) to support features not exercised here.
- `features.md` was not updated this session — it compares ODE_ECS vs moecs only (odecs was
  deliberately left out of it in an earlier session) and does not yet mention `Arch_Table`;
  flag for a future session if a features-doc refresh is wanted.
