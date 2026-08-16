# ECS feature comparisons

Three ECS libraries written in Odin, compared feature-by-feature against ODE_ECS
([github.com/odin-engine/ode_ecs](https://github.com/odin-engine/ode_ecs)), which takes a
relational-database approach — typed component tables plus incrementally-maintained views (and,
as of July 2026, ownership-based `Group`s). moecs
([github.com/helioscout/moecs](https://github.com/helioscout/moecs)) and odecs
([github.com/NateTheGreatt/odecs](https://github.com/NateTheGreatt/odecs)) both take an
archetype approach but differ sharply in scope: moecs is a batteries-included framework
(scheduler, observers, resources, typed relations); odecs is a minimal, flecs-inspired core
(archetypes, observers, relationships-as-pairs, query terms) with no scheduler or resources.
For measured performance numbers see [README.md](README.md).

As of August 16, 2026: ODE_ECS at commit `575d8c4` (since the August 15 `cafc8b8` snapshot: added
production-hardened many-to-many relations via `Pair_Table(T)` — `View` integration through an
embedded `presence` `Tag_Table`, `Command_Buffer` and binary-serialization support, and O(1)
automatic cleanup when either side of a pair is destroyed — plus a new opt-in `Observer` feature:
structural-change callbacks for entity create/destroy, component/tag/pair add/remove,
enable/disable, and parent set/remove, off by default and **compile-time zero-cost** when
disabled (`-define:ECS_OBSERVERS_ENABLED=true` to opt in); see below), moecs at commit `ccd00f2`
(source unchanged since `8d50786` — the newer commits are README-only), odecs at commit `e3ca0a5`
(unchanged since 7/5/2026).

# ODE_ECS vs moecs

ODE_ECS shipped a large batch of features in July 2026 not covered by earlier versions of this
doc: `Group`, `Arch_Table`, `Command_Buffer`, `Relations_Table`, `Overbase`, binary serialization,
and view `excludes`/`refilter` — all included below.

## At a glance

| Feature | ODE_ECS | moecs |
|---|---|---|
| Architecture | Relational: dense SoA `Table` per component type + `View`s/`Group`s, plus an opt-in true-archetype `Arch_Table` for fixed component sets | Archetype: AoS chunks per entity in memory blocks |
| License | zlib | MIT |
| Multiple worlds | Yes — any number of independent `Database`s | Yes — any number of `World`s in one space |
| Shared entity ID space | `Overbase` — attach several `Database`s to one shared id space; destroying an entity through any attached Database removes its components everywhere | None — `World`s are independent id spaces |
| Entity identity | `entity_id` = index + generation (stale-handle detection via `is_entity_expired`) | `^Entity` pointer; `despawning()` / `deleted()` state checks |
| Memory model | Everything preallocated up front; **no hidden allocations** during the game loop | Block/chunk allocation; new blocks allocated as the world grows |
| Custom allocators | Yes, per `Database` (propagates to tables/views/groups) | No explicit allocator API |
| Entity count | Fixed `entities_cap` chosen at init | Unlimited (grows by blocks) |
| Component storage | 100% dense per-type arrays (SoA), tail-swap on remove; opt-in `Arch_Table` bundles N columns under one shared row index for sets that always travel together | Per-entity chunk holding all its components (AoS), bit flags for presence |
| Component type limit | 128 default, unlimited via `ECS_TABLES_MULT` config | `MAX_COMPONENTS_COUNT` constant (128 default, edit manually) |
| Memory-lean table variants | `Compact_Table`, `Tiny_Table` for sparse component types (both support pause/resume packing like `Table`) | — (one chunk layout; sparse entities still reserve full chunk row) |
| Tags | `Tag_Table` (dense entity list, composable into views; supports pause/resume packing) | Bit-flag tags — set/unset is just a bit write, no storage |
| Component enable/disable | `disable_component`/`enable_component`/`is_component_disabled` — flips a flag without a structural move or losing the stored value (View-matching only; a `Group`'s dense prefix and `Command_Buffer`/serialization don't see it) | None — use `add_component`/`remove_component` (structural) or a separate bit-flag tag |
| Queries | `View` over N tables (`includes` AND, `excludes` NOT, `any_of` OR, optional `filter` proc, `refilter()`/`rebuild()`), incrementally maintained on add/remove; `Group` for a fixed owned-table set with enforced alignment; `Arch_Table` + `Arch_Iterator`/`arch_table__dense_slice` for a true-archetype subset | System match queries: components + tags + relations, plus `without` exclusion |
| Iteration API | Direct table loop, `Iterator` over views (automatic dense fast path, `for v1, v2 in ecs.iterate(&it, &t1, &t2)` sugar), `dense_slice` raw-SoA batch APIs | System callbacks driven by `progress()`; `each()` for all entities |
| Systems / scheduler | None — you write plain loops and call them yourself | Built-in: `mount` with phases (START / PRE_UPDATE / UPDATE / POST_UPDATE / MANUAL), named systems, `enable` / `disable` / `execute` |
| Structural changes | Immediate (tail-swap, O(1)) by default; opt into deferred via `pause_packing`/`Command_Buffer` (below) | Deferred to end of progress step (`perform` stage) |
| Mutation while iterating | Three opt-in mechanisms: manual rule ("don't mutate while iterating"); `pause_packing`/`resume_packing`/`pack`, scoped to a `Database`, `Table`, or `Group`; or a `Command_Buffer` that records `destroy_entity`/add/remove-component/tag/`set_parent` and applies them later with `replay` (also composes with `pause_packing`) | Safe by design and always-on — despawns and archetype moves are deferred automatically, no opt-in needed |
| Observers / events | `Observer` — 14 structural-change kinds (entity create/destroy, component/tag/pair add/remove, enable/disable, parent set/remove) via one database-wide registry with per-observer `interested_in` filtering; fires identically for immediate calls and `Command_Buffer` replay; off by default and **compile-time zero-cost** when disabled (`-define:ECS_OBSERVERS_ENABLED=true` to opt in) — the notify code doesn't exist in the binary, not just a skipped branch | 9 event types (SPAWNED, DESPAWNED, ADDED, REMOVED, SET, TAGGED, UNTAGGED, RELATED, UNRELATED), per-type on/off |
| Entity relations | Parent/child via `Relations_Table` (one parent per child): O(1) set/remove/reparent, always-on cycle check, orphan-on-destroy or cascading `destroy_children`, deferrable via `Command_Buffer`'s `cmd_set_parent`/`cmd_remove_parent`; **plus** many-to-many via `Pair_Table(T)` — any holder can point at any number of targets with typed payload data, participates in `View` matching via an embedded `presence` `Tag_Table`, O(1) auto-cleanup when either side is destroyed, `Command_Buffer` (`cmd_pair_add`/`cmd_pair_remove`) and serialization support | One-to-one and one-to-many, with relationship data; built-in `ChildOf` / `ParentOf` / `RelationOf`, multi-parent, cascade despawn of orphaned children |
| Resources (singletons) | None (use plain Odin globals/structs) | First-class registered resources with `set` / `get` / `get_mut` |
| Entity lifetimes | One kind | `DYNAMIC` and `STATIC` (never-despawned) entities in separate blocks |
| Serialization | Binary snapshot of a whole `Database` (`serialize`/`deserialize`, `save_to_file`/`load_from_file`); requires POD components; views/groups are derived and rebuilt on load, not stored; `Overbase`-aware (shared id-space databases snapshot only their own tables) | None |
| Parallelism support | Designed-in batching: `iterator_init(start_row, end_row)`; one `Database` per thread (or one `Command_Buffer` per thread, single-threaded `replay`); phase-separation guidance | Not addressed; deferred model implies single-threaded `progress()` |
| Validation / safety checks | `ECS_VALIDATIONS` asserts (zero cost on the iteration/churn hot paths; see [README.md](README.md) for a caveat on setup-path cost) | Runtime checks in API procs |
| Docs & examples | README, wiki, docs/ (database, tables, view, group, relations, command_buffer, overbase, serialization, FAQ), 13+ samples, test suite incl. randomized fuzz test | Extensive README, design diagrams, example game (mouniverse) |

## What only ODE_ECS has

- **Predictable memory:** everything is preallocated at init with an optional custom
  allocator; nothing allocates, frees, or moves during the game loop.
- **Generational entity IDs** — a saved `entity_id` can be safely checked for staleness
  after the slot is reused.
- **Dense fast path + `dense_slice`:** when view rows align with table rows (the common
  case), iteration reads dense arrays directly and the batch API compiles to a raw SoA sweep
  at the hardware memory floor.
- **`Group`:** exclusive ownership of a fixed set of tables that *enforces* (not just detects)
  dense alignment — no per-row fallback structure at all, at the cost of a row swap on every
  membership change. See [README.md](README.md) for when it beats a `View`.
- **`Arch_Table`:** opt-in true-archetype storage — bundle a component set that always travels
  together (e.g. `Position`+`Velocity`) into one archetype row with a single shared index,
  rather than moecs's unconditional per-entity chunk storage for *everything*. Lets a database
  mix archetype-style locality where it pays off with plain `Table`s where components have
  independent lifetimes, instead of committing the whole entity model to one storage shape.
  Whole-row membership only — no per-column add/remove, so it isn't a fit for components that
  toggle independently on a live entity.
- **Table variants for sparse data** (`Compact_Table`, `Tiny_Table`) to keep memory
  proportional to actual component counts.
- **Two independent deferred-mutation mechanisms**, usable together or apart:
  `pause_packing`/`resume_packing`/`pack` (scoped to a `Database`, `Table`, or `Group`) keeps
  row pointers stable through a mutate-while-iterating window; `Command_Buffer` instead
  records the structural calls themselves (destroy, add/remove component, tag/untag,
  set/remove parent) and applies them later with `replay` — closer to moecs's always-on
  deferral, but opt-in and explicit about the sync point.
- **`Overbase`:** a shareable entity ID space so two or more `Database`s (e.g. a gameplay world
  and a render world) can refer to the same logical entities without merging their component
  tables.
- **Binary serialization:** snapshot a whole `Database` (or a shared `Overbase`) to a buffer or
  file and restore it, with schema/capacity validation before anything is mutated.
- **Explicit parallelism hooks:** ranged iterators for data-parallel batches and share-nothing
  multiple databases.
- **Cycle-safe relations:** `set_parent` always rejects cycles (`Relation_Cycle`), so cascade
  destroy can never recurse forever; moecs performs no cycle check when relating entities.
- **Component enable/disable:** `disable_component`/`enable_component` soft-toggle a component
  out of/into `View` matching without touching its stored data or moving the row — moecs has no
  component-granularity equivalent (its `enable`/`disable` is a scheduler-level system switch).
- **Many-to-many relations with O(1) target-destroy cleanup:** `Pair_Table(T)` walks only the
  destroyed entity's own pair rows (via a target-side doubly-linked list) when either side of a
  pair is destroyed, not the whole table — the universal `destroy_entity` hot path stays cheap
  for entities that never appear in any `Pair_Table`.
- **Compile-time zero-cost `Observer` gating:** off by default, and disabling it removes the
  notify code from the binary entirely (`when OBSERVERS_ENABLED` at every hook site) rather than
  a runtime toggle — empirically verified against the churn benchmarks to add no measurable
  overhead when unused. moecs's observers have no equivalent all-or-nothing compile-time switch.

## What only moecs has

- **Systems with a scheduler:** phased pipeline, named systems, enable/disable, manual
  execution, task systems (no query).
- **Query language:** match on components + tags + relations with a `without` exclusion list.
- **Component-value-mutation events (`SET`) and runtime per-type on/off:** moecs's observers
  also fire when a component's stored *value* changes, not just when it's added/removed, and
  each event type can be toggled at runtime. ODE_ECS's `Observer` covers structural changes only
  (no value-mutation event) and is gated by one compile-time switch for the whole feature —
  per-observer filtering via `interested_in` only narrows which kinds *that* observer sees once
  the feature itself is compiled in.
- **A queryable reverse relation index (`RelationOf`)** built into the query language itself.
  (ODE_ECS's `Pair_Table(T)` now covers typed many-to-many relation data — closing most of this
  gap — but exposes only `targets_of(holder)`, not a symmetric `holders_of(target)` query, and
  `Relations_Table` itself remains parent/child-only with no attached data.)
- **Resources:** registered singletons with typed accessors.
- **Deferred safety is always on, not opt-in:** despawn or re-archetype freely from inside any
  system with no setup — changes apply automatically at the end of the frame. (ODE_ECS now has
  two ways to get comparable safety — `pause_packing` or `Command_Buffer`, see above — but both
  require the caller to opt in and pick a sync point.)
- **Free tags** (pure bit flags — no per-tag storage) and **static entity lifetime** for
  things that never despawn.
- **Unlimited entity count** — the world grows block by block, no capacity chosen up front.

## Bottom line

ODE_ECS is a lean iteration engine that has grown a deliberate, opt-in set of extras: fewer
core concepts (database, table, view, group, relations), immediate O(1) structural changes by
default, zero hidden allocations, the fastest iteration paths, plus `Command_Buffer`/
`pause_packing` when you do need deferred safety, `Overbase` when you need a shared id space,
`Arch_Table` when a component set benefits from true-archetype locality, `Pair_Table` when you
need many-to-many relations with typed data, `Observer` when you need structural-change
callbacks, and binary snapshots when you need save/load — all still opt-in, so the zero-cost
default path is untouched if you don't reach for them. Its relations now span both a minimal
parent/child tree (`Relations_Table`) and typed many-to-many links (`Pair_Table`), still without
moecs's reverse-index query integration or component-value-mutation events. moecs is a
framework: scheduler, queries, observers, typed relations, and resources out of the box, with
always-on deferred-safety as the default rather than an opt-in, paid for with per-entity chunk
storage that iterates slower (see the benchmarks). Pick ODE_ECS when raw throughput and memory
predictability dominate and you want deferred-safety/persistence as opt-in tools rather than
defaults; pick moecs when you want the full framework and its always-on deferred-safety model
out of the box.

# ODE_ECS vs odecs

odecs ([github.com/NateTheGreatt/odecs](https://github.com/NateTheGreatt/odecs)) is a minimal,
flecs-inspired archetype ECS — its API and pair/relationship model are close ports of Flecs
(C) and its sibling library bitECS (TypeScript). It has no scheduler and no resources; its
scope is entities, components, archetypes, queries (with flecs-style term builders), pairs,
and observers.

## At a glance

| Feature | ODE_ECS | odecs |
|---|---|---|
| Architecture | Relational: dense SoA `Table` per component type + `View`s/`Group`s, plus an opt-in true-archetype `Arch_Table` for fixed component sets | Archetype: one dense SoA column per component per archetype |
| License | zlib | MIT |
| Multiple worlds | Yes — any number of independent `Database`s | Yes — any number of independent `World`s (`create_world`) |
| Shared entity ID space | `Overbase` — attach several `Database`s to one shared id space | None — each `World` is its own id space |
| Entity identity | `entity_id` = 56-bit index + 8-bit generation packed into one `i64` (`ix_gen`); stale-handle detection via `is_entity_expired` | `EntityID` = 48-bit index + 16-bit generation packed into one `u64`; `entity_alive` for stale-handle checks |
| Memory model | Everything preallocated up front; **no hidden allocations** during the game loop | Archetypes/columns grow dynamically; `add_entity`'s variadic `..any` path allocates temp-allocator scratch per call (see [README.md](README.md)) |
| Custom allocators | Yes, per `Database` (propagates to tables/views/groups) | Yes, per `World` — a separate `cache_allocator` for the query cache (e.g. so it can survive an arena snapshot/rollback for rollback netcode) |
| Entity count | Fixed `entities_cap` chosen at init | Unlimited (archetypes/columns grow as needed) |
| Component storage | 100% dense per-type arrays (SoA) across the whole `Database`, tail-swap on remove; opt-in `Arch_Table` gives a fixed component set its own true-archetype row (one shared index across its columns), scoped to just that set rather than the whole database | Dense per-type arrays (SoA) *within each archetype*; an entity's components live in whichever archetype matches its exact component set — adding/removing a component moves the whole row to a different archetype |
| Component type limit | 128 default, unlimited via `ECS_TABLES_MULT` config | No fixed limit (component ids are dynamically assigned) |
| Memory-lean table variants | `Compact_Table`, `Tiny_Table` for sparse component types | — (sparse component combinations instead create more, smaller archetypes) |
| Tags | `Tag_Table` (dense entity list, composable into views) | Zero-sized tag structs — a tag is just a component type with no fields, stored as its own archetype-defining bit like any other component |
| Component enable/disable | `disable_component`/`enable_component`/`is_component_disabled` — flips a flag without a structural move or losing the stored value; View-matching only (a `Group`'s dense prefix, `Command_Buffer`, and serialization don't see it) | `disable_component`/`enable_component`/`is_component_disabled` — flips a flag without a structural move or losing the stored value |
| Queries | `View` over N tables (`includes` AND, `excludes` NOT, `any_of` OR, optional `filter`, `refilter()`/`rebuild()`), incrementally maintained; `Group` for enforced-alignment iteration; `Arch_Table` + `Arch_Iterator`/`arch_table__dense_slice` for a single fixed archetype | `query(world, {...})` term list per call, auto-cached (invalidated only when a new archetype appears); term builders `all`/`and`, `or`/`some`, `not`/`none`, `pair`, `hierarchy`/`cascade` for depth-ordered relation iteration |
| Iteration API | Direct table loop, `Iterator` over views (dense fast path, `for v1, v2 in ecs.iterate(&it, &t1, &t2)` sugar), `dense_slice` raw-SoA batch APIs | `for arch in query(...) { get_table(world, arch, T) }` — a raw column slice per matched archetype per component type |
| Systems / scheduler | None — you write plain loops and call them yourself | None — "systems" are just plain procs that call `query`; no phases or scheduling |
| Structural changes | Immediate (tail-swap, O(1)) by default; opt into deferred via `pause_packing`/`Command_Buffer` | Immediate outside iteration; **automatically deferred** while inside a `query` (and nested queries), flushing when the enclosing scope exits or the next `query()` call runs |
| Mutation while iterating | Three opt-in mechanisms: manual rule, `pause_packing`/`resume_packing`/`pack` (scoped to Database/Table/Group), or `Command_Buffer` + `replay` | Always-on for query iteration specifically (`@(deferred_in)` on `query`) — no opt-in needed, but the deferral window is the query's lexical scope, not a frame boundary |
| Observers / events | `Observer` — 14 structural-change kinds via one database-wide registry, per-observer `interested_in` filtering, fires identically for immediate calls and `Command_Buffer` replay; off by default, **compile-time zero-cost** when disabled (`-define:ECS_OBSERVERS_ENABLED=true` to opt in) | `observe(world, on_add(...)/on_remove(...), callback)` — fires on archetype entry/exit (component gained/lost, including via relation-trait side effects); explicitly documented as side-effect-only, not for game logic |
| Entity relations | Parent/child via `Relations_Table` (one parent per child, cycle-checked, deferrable via `Command_Buffer`); **plus** many-to-many via `Pair_Table(T)` — typed payload data, `View`-integrated through an embedded `presence` `Tag_Table`, O(1) auto-cleanup on either side's destroy, `Command_Buffer`/serialization support | Flecs-style *pairs* (`pair(Relation, Target)`) — general many-to-many relationships, not just parent/child, can carry data (`add_pair(world, e, Contains{50}, gold)`), queryable with `Wildcard` targets; `Exclusive` trait (single-target, auto-replaces) and `Cascade` trait (deleting the target deletes dependents) opt a relation type into parent/child-like semantics; no cycle check |
| Resources (singletons) | None (use plain Odin globals/structs) | None (use plain Odin globals/structs) |
| Entity lifetimes | One kind | One kind |
| Serialization | Binary snapshot of a whole `Database` (`serialize`/`deserialize`, `save_to_file`/`load_from_file`), `Overbase`-aware | None |
| Parallelism support | Designed-in batching: `iterator_init(start_row, end_row)`; one `Database` per thread | Not addressed in docs; the two-allocator `create_world` design (separate `cache_allocator`) targets frame-based snapshot/rollback (e.g. GGPO-style netcode) rather than multi-threading |
| Validation / safety checks | `ECS_VALIDATIONS` asserts (zero cost on the iteration/churn hot paths; setup-path caveat in [README.md](README.md)) | Not documented as a separate compile-time switch |
| Docs & examples | README, wiki, docs/ (database, tables, view, group, relations, command_buffer, overbase, serialization, FAQ), 13+ samples, test suite incl. randomized fuzz test | README, docs/ (core-api, queries, relationships, observers, deferred-changes), bundled benchmark suite with its own SVG chart |

## What only ODE_ECS has (vs odecs)

- **Predictable, preallocated memory:** everything is sized at init with an optional custom
  allocator; nothing allocates, frees, or moves during the game loop. odecs's archetype storage
  grows dynamically, and its `add_entity` specifically allocates per-call scratch from the temp
  allocator for its variadic `..any` component list (see the benchmarks in
  [README.md](README.md) for what this costs at 1M entities).
- **Fixed, capacity-checked entity/component limits** known up front, vs odecs's dynamically
  growing archetypes and component-id space.
- **Dense fast path + `dense_slice`:** iteration reads dense arrays
  directly with zero per-row indirection once alignment holds/is enforced; odecs's per-archetype
  columns are also dense SoA, but a component move between archetypes is a real data copy, not
  just a bit flip.
- **`Group`:** exclusive table ownership that *enforces* dense alignment; odecs's archetypes
  give the equivalent guarantee by construction for any one archetype, but an entity whose
  component set doesn't yet match one exact archetype gets no such guarantee until it's created.
- **`Arch_Table`:** a true-archetype table matching odecs's own per-archetype dense-column
  storage for one fixed component set, without adopting odecs's whole-database archetype model
  — the rest of the `Database` stays plain `Table`s. The trade is the opposite of odecs's:
  `Arch_Table` is a *single* fixed archetype with no automatic migration between archetypes, so
  it only fits component sets that are static per entity (odecs instead auto-migrates an entity
  to a new archetype on every add/remove, at the cost of a structural copy each time — see
  scenario 5 in [README.md](README.md), where odecs's per-column churn model is the only one of
  the two that can represent the workload at all).
- **Table variants for sparse data** (`Compact_Table`, `Tiny_Table`) to keep memory proportional
  to actual component counts, rather than letting sparse combinations multiply archetype count.
- **`pause_packing`/`Command_Buffer`:** two explicit, composable ways to defer structural
  changes beyond a single query's lexical scope (e.g. across an entire frame, or across
  threads) — odecs's deferral is automatic but tied to the `query`'s scope specifically.
- **`Overbase`:** a shareable entity ID space across multiple `Database`s.
- **Binary serialization:** snapshot/restore a whole `Database` (or shared `Overbase`); odecs
  has no equivalent.
- **Cycle-safe relations:** `set_parent` always rejects cycles; odecs's `Cascade` trait performs
  no cycle check, so a manually-constructed relation cycle in odecs is the caller's problem.
- **Explicit parallelism hooks:** ranged iterators for data-parallel batches, share-nothing
  multiple databases.
- **Many-to-many relations with O(1) target-destroy cleanup:** `Pair_Table(T)` walks only the
  destroyed entity's own pair rows when either side of a pair is destroyed, not the whole table —
  cheap for entities that never appear in any `Pair_Table`, same principle as odecs's own
  archetype design but scoped per-relation instead of per-entity-component-set.
- **Compile-time zero-cost `Observer` gating:** off by default, and disabling it removes the
  notify code from the binary entirely rather than a runtime toggle — empirically verified
  against the churn benchmarks to add no measurable overhead when unused.

## What only odecs has

- **Wildcard relation queries and semantic traits on pairs:** `Wildcard` targets in queries
  (`query(world, {pair(ChildOf, Wildcard)})`), and `Exclusive` (single-target, auto-replace) /
  `Cascade` (deleting the target deletes dependents) traits built into the relation type itself.
  ODE_ECS's `Pair_Table(T)` now covers odecs's core "many-to-many pairs with typed data" case
  (`add_pair(world, chest, Contains{50}, gold)` ≈ `pair_add(&pt, chest, gold, Contains{50})`),
  but has no query-language wildcard matching and no trait system — `Exclusive`/`Cascade`-like
  semantics would need to be built by hand on top of `pair_add`/`pair_remove`.
- **Depth-ordered `hierarchy`/`cascade` query iteration** (parents before children) built into
  the query itself. (ODE_ECS's `Relations_Table` has the read-only equivalent —
  `walk_hierarchy`/`walk_subtree`, also parent-before-child — but as a separate traversal call,
  not composed into a general query.)
- **Rich query term language:** `all`/`and`, `or`/`some`, `not`/`none`, and `pair` compose freely
  and mix with plain typeids in one query call — ODE_ECS's `View` now covers the same AND/OR/NOT
  shape (`includes`/`any_of`/`excludes`), but as three separate lists set at `view_init`/
  `refilter` time rather than terms composed ad hoc per call, and with no `pair`/wildcard
  equivalent.
- **Observers that see relation-trait side effects:** odecs's `on_add`/`on_remove` fire on any
  archetype transition, including ones caused by `Exclusive`/`Cascade` relation traits. Since
  `Pair_Table` has no trait system, ODE_ECS's `Observer` `Pair_Added`/`Pair_Removed` events only
  ever reflect direct `pair_add`/`pair_remove`/destroy-cascade calls, never trait-driven side
  effects — there are none to see.
- **Unlimited entity count and component-type count** — no capacity chosen up front for either.
- **Automatic archetype migration for arbitrary component combinations:** any add/remove moves
  an entity to whichever archetype matches its new exact component set, creating that archetype
  on demand if needed. ODE_ECS's `Arch_Table` is a single fixed archetype with no such migration
  — mixing archetype storage into an ODE_ECS database means picking specific static component
  sets up front (`Arch_Table` per set) rather than letting arbitrary combinations happen.
- **Automatic deferred mutation scoped to iteration, no opt-in required:** any structural change
  made while a `query` is open is deferred and flushed automatically at scope exit — closer to
  moecs's always-on model than to ODE_ECS's opt-in mechanisms, but scoped per-query rather than
  per-frame.
- **A `cache_allocator` split from the general allocator**, aimed at frame-snapshot/rollback
  use cases (e.g. GGPO-style rollback netcode) where the query cache needs to survive an arena
  reset that the rest of the world doesn't.

## Bottom line

Both libraries are architecturally SoA and land at or near the same iteration hardware floor
(see [README.md](README.md), scenario 1: odecs's plain query loop vs ODE_ECS's `dense_slice`)
— the real differences are in scope and structural-operation cost, not raw
sweep speed. `Arch_Table` narrows the architectural gap further for one specific shape: a fixed
component set that never changes membership on a live entity now gets true-archetype storage
in ODE_ECS too, and comes out ahead of odecs's equivalent archetype on every measured axis for
that shape (README scenario 1/3: ~460x faster setup, ties iteration, ~6x faster churn). But it's
a single static archetype, not odecs's auto-migrating model — for entities whose component set
is assembled or mutated dynamically at the individual-component level, odecs's whole-database
archetype migration is the only one of the two designs that represents the workload at all
(README scenario 5). ODE_ECS stays a lean, fully-preallocated core with fixed capacities,
immediate O(1) structural changes by default, plus opt-in `Command_Buffer`/`pause_packing`/
`Overbase`/`Arch_Table`/serialization/`Pair_Table`/`Observer` for the cases that need them —
relations now cover both a minimal parent/child tree and typed many-to-many links, still without
odecs's wildcard query matching or relation traits (`Exclusive`/`Cascade`). odecs is a minimal
*but dynamic* core inspired by Flecs: wildcard relation queries, `Exclusive`/`Cascade` traits, a
richer query term language, and automatic per-query deferred mutation — paid for with dynamically
growing archetype storage and a very expensive entity-creation path (its variadic `add_entity` is
the single biggest number separating the two libraries in the benchmarks — see README.md scenario
0/1). Pick ODE_ECS when you want fixed memory budgets and fast structural operations (spawning,
despawning, re-parenting, pairing) at scale, reaching for `Arch_Table` on the component sets that
are static per entity; pick odecs when you want Flecs-style wildcard queries, relation traits, and
automatic migration across arbitrary/dynamic component combinations, and can afford (or avoid, by
creating entities rarely) its archetype-churn and entity-creation costs.
