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

As of July 24, 2026: ODE_ECS at commit `2e8268c`, moecs at commit `ccd00f2` (source unchanged
since `8d50786` — the newer commits are README-only), odecs at commit `e3ca0a5` (unchanged
since 7/5/2026).

# ODE_ECS vs moecs

ODE_ECS shipped a large batch of features in July 2026 not covered by earlier versions of this
doc: `Group`, `Command_Buffer`, `Relations_Table`, `Overbase`, binary serialization, and view
`excludes`/`refilter` — all included below.

## At a glance

| Feature | ODE_ECS | moecs |
|---|---|---|
| Architecture | Relational: dense SoA `Table` per component type + `View`s/`Group`s | Archetype: AoS chunks per entity in memory blocks |
| License | zlib | MIT |
| Multiple worlds | Yes — any number of independent `Database`s | Yes — any number of `World`s in one space |
| Shared entity ID space | `Overbase` — attach several `Database`s to one shared id space; destroying an entity through any attached Database removes its components everywhere | None — `World`s are independent id spaces |
| Entity identity | `entity_id` = index + generation (stale-handle detection via `is_entity_expired`) | `^Entity` pointer; `despawning()` / `deleted()` state checks |
| Memory model | Everything preallocated up front; **no hidden allocations** during the game loop | Block/chunk allocation; new blocks allocated as the world grows |
| Custom allocators | Yes, per `Database` (propagates to tables/views/groups) | No explicit allocator API |
| Entity count | Fixed `entities_cap` chosen at init | Unlimited (grows by blocks) |
| Component storage | 100% dense per-type arrays (SoA), tail-swap on remove | Per-entity chunk holding all its components (AoS), bit flags for presence |
| Component type limit | 128 default, unlimited via `ECS_TABLES_MULT` config | `MAX_COMPONENTS_COUNT` constant (128 default, edit manually) |
| Memory-lean table variants | `Compact_Table`, `Tiny_Table` for sparse component types (both support pause/resume packing like `Table`) | — (one chunk layout; sparse entities still reserve full chunk row) |
| Tags | `Tag_Table` (dense entity list, composable into views; supports pause/resume packing) | Bit-flag tags — set/unset is just a bit write, no storage |
| Queries | `View` over N tables (`excludes` list for structural negation, optional `filter` proc, `refilter()`/`rebuild()`), incrementally maintained on add/remove; `Group` for a fixed owned-table set with enforced alignment | System match queries: components + tags + relations, plus `without` exclusion |
| Iteration API | Direct table loop, `Iterator` over views (automatic dense fast path, `for v1, v2 in ecs.iterate(&it, &t1, &t2)` sugar), `view_dense_slice`/`group_dense_slice` raw-SoA batch APIs | System callbacks driven by `progress()`; `each()` for all entities |
| Systems / scheduler | None — you write plain loops and call them yourself | Built-in: `mount` with phases (START / PRE_UPDATE / UPDATE / POST_UPDATE / MANUAL), named systems, `enable` / `disable` / `execute` |
| Structural changes | Immediate (tail-swap, O(1)) by default; opt into deferred via `pause_packing`/`Command_Buffer` (below) | Deferred to end of progress step (`perform` stage) |
| Mutation while iterating | Three opt-in mechanisms: manual rule ("don't mutate while iterating"); `pause_packing`/`resume_packing`/`pack`, scoped to a `Database`, `Table`, or `Group`; or a `Command_Buffer` that records `destroy_entity`/add/remove-component/tag/`set_parent` and applies them later with `replay` (also composes with `pause_packing`) | Safe by design and always-on — despawns and archetype moves are deferred automatically, no opt-in needed |
| Observers / events | None | 9 event types (SPAWNED, DESPAWNED, ADDED, REMOVED, SET, TAGGED, UNTAGGED, RELATED, UNRELATED), per-type on/off |
| Entity relations | Parent/child via `Relations_Table` (one parent per child): O(1) set/remove/reparent, always-on cycle check, orphan-on-destroy or cascading `destroy_children`; deferrable via `Command_Buffer`'s `cmd_set_parent`/`cmd_remove_parent` | One-to-one and one-to-many, with relationship data; built-in `ChildOf` / `ParentOf` / `RelationOf`, multi-parent, cascade despawn of orphaned children |
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
- **Dense fast path + `view_dense_slice`:** when view rows align with table rows (the common
  case), iteration reads dense arrays directly and the batch API compiles to a raw SoA sweep
  at the hardware memory floor.
- **`Group`:** exclusive ownership of a fixed set of tables that *enforces* (not just detects)
  dense alignment — no per-row fallback structure at all, at the cost of a row swap on every
  membership change. See [README.md](README.md) for when it beats a `View`.
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

## What only moecs has

- **Systems with a scheduler:** phased pipeline, named systems, enable/disable, manual
  execution, task systems (no query).
- **Query language:** match on components + tags + relations with a `without` exclusion list.
- **Observers:** subscribe to structural, tag, data, and relation events per type.
- **Typed relations with attached data:** user-defined relation types carrying relationship
  data, multi-parent links, and the `RelationOf` reverse index. (ODE_ECS's `Relations_Table`
  covers parent/child only — one parent per child, no attached data.)
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
and binary snapshots when you need save/load — all still opt-in, so the zero-cost default path
is untouched if you don't reach for them. Its relations remain deliberately minimal
(parent/child, no attached data). moecs is a framework: scheduler, queries, observers, typed
relations, and resources out of the box, with always-on deferred-safety as the default rather
than an opt-in, paid for with per-entity chunk storage that iterates slower (see the
benchmarks). Pick ODE_ECS when raw throughput and memory predictability dominate and you want
deferred-safety/persistence as opt-in tools rather than defaults; pick moecs when you want the
full framework and its always-on deferred-safety model out of the box.

# ODE_ECS vs odecs

odecs ([github.com/NateTheGreatt/odecs](https://github.com/NateTheGreatt/odecs)) is a minimal,
flecs-inspired archetype ECS — its API and pair/relationship model are close ports of Flecs
(C) and its sibling library bitECS (TypeScript). It has no scheduler and no resources; its
scope is entities, components, archetypes, queries (with flecs-style term builders), pairs,
and observers.

## At a glance

| Feature | ODE_ECS | odecs |
|---|---|---|
| Architecture | Relational: dense SoA `Table` per component type + `View`s/`Group`s | Archetype: one dense SoA column per component per archetype |
| License | zlib | MIT |
| Multiple worlds | Yes — any number of independent `Database`s | Yes — any number of independent `World`s (`create_world`) |
| Shared entity ID space | `Overbase` — attach several `Database`s to one shared id space | None — each `World` is its own id space |
| Entity identity | `entity_id` = 56-bit index + 8-bit generation packed into one `i64` (`ix_gen`); stale-handle detection via `is_entity_expired` | `EntityID` = 48-bit index + 16-bit generation packed into one `u64`; `entity_alive` for stale-handle checks |
| Memory model | Everything preallocated up front; **no hidden allocations** during the game loop | Archetypes/columns grow dynamically; `add_entity`'s variadic `..any` path allocates temp-allocator scratch per call (see [README.md](README.md)) |
| Custom allocators | Yes, per `Database` (propagates to tables/views/groups) | Yes, per `World` — a separate `cache_allocator` for the query cache (e.g. so it can survive an arena snapshot/rollback for rollback netcode) |
| Entity count | Fixed `entities_cap` chosen at init | Unlimited (archetypes/columns grow as needed) |
| Component storage | 100% dense per-type arrays (SoA) across the whole `Database`, tail-swap on remove | Dense per-type arrays (SoA) *within each archetype*; an entity's components live in whichever archetype matches its exact component set — adding/removing a component moves the whole row to a different archetype |
| Component type limit | 128 default, unlimited via `ECS_TABLES_MULT` config | No fixed limit (component ids are dynamically assigned) |
| Memory-lean table variants | `Compact_Table`, `Tiny_Table` for sparse component types | — (sparse component combinations instead create more, smaller archetypes) |
| Tags | `Tag_Table` (dense entity list, composable into views) | Zero-sized tag structs — a tag is just a component type with no fields, stored as its own archetype-defining bit like any other component |
| Component enable/disable | None — use `remove_component`/`add_component` (structural) | `disable_component`/`enable_component`/`is_component_disabled` — flips a flag without a structural move or losing the stored value |
| Queries | `View` over N tables (`excludes`, optional `filter`, `refilter()`/`rebuild()`), incrementally maintained; `Group` for enforced-alignment iteration | `query(world, {...})` term list per call, auto-cached (invalidated only when a new archetype appears); term builders `all`/`and`, `or`/`some`, `not`/`none`, `pair`, `hierarchy`/`cascade` for depth-ordered relation iteration |
| Iteration API | Direct table loop, `Iterator` over views (dense fast path, `for v1, v2 in ecs.iterate(&it, &t1, &t2)` sugar), `view_dense_slice`/`group_dense_slice` raw-SoA batch APIs | `for arch in query(...) { get_table(world, arch, T) }` — a raw column slice per matched archetype per component type |
| Systems / scheduler | None — you write plain loops and call them yourself | None — "systems" are just plain procs that call `query`; no phases or scheduling |
| Structural changes | Immediate (tail-swap, O(1)) by default; opt into deferred via `pause_packing`/`Command_Buffer` | Immediate outside iteration; **automatically deferred** while inside a `query` (and nested queries), flushing when the enclosing scope exits or the next `query()` call runs |
| Mutation while iterating | Three opt-in mechanisms: manual rule, `pause_packing`/`resume_packing`/`pack` (scoped to Database/Table/Group), or `Command_Buffer` + `replay` | Always-on for query iteration specifically (`@(deferred_in)` on `query`) — no opt-in needed, but the deferral window is the query's lexical scope, not a frame boundary |
| Observers / events | None | `observe(world, on_add(...)/on_remove(...), callback)` — fires on archetype entry/exit (component gained/lost, including via relation-trait side effects); explicitly documented as side-effect-only, not for game logic |
| Entity relations | Parent/child via `Relations_Table` (one parent per child): O(1) set/remove/reparent, always-on cycle check, orphan-on-destroy or cascading `destroy_children`; deferrable via `Command_Buffer` | Flecs-style *pairs* (`pair(Relation, Target)`) — general many-to-many relationships, not just parent/child, can carry data (`add_pair(world, e, Contains{50}, gold)`), queryable with `Wildcard` targets; `Exclusive` trait (single-target, auto-replaces) and `Cascade` trait (deleting the target deletes dependents) opt a relation type into parent/child-like semantics; no cycle check |
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
- **Dense fast path + `view_dense_slice`/`group_dense_slice`:** iteration reads dense arrays
  directly with zero per-row indirection once alignment holds/is enforced; odecs's per-archetype
  columns are also dense SoA, but a component move between archetypes is a real data copy, not
  just a bit flip.
- **`Group`:** exclusive table ownership that *enforces* dense alignment; odecs's archetypes
  give the equivalent guarantee by construction for any one archetype, but an entity whose
  component set doesn't yet match one exact archetype gets no such guarantee until it's created.
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

## What only odecs has

- **Flecs-style general relationships:** pairs are many-to-many and can carry arbitrary data
  (`add_pair(world, chest, Contains{50}, gold)`), not just parent/child — ODE_ECS's
  `Relations_Table` covers one parent per child with no attached data.
- **`Wildcard` relation queries:** `query(world, {pair(ChildOf, Wildcard)})` to match "all
  entities related via ChildOf to anything," and depth-ordered `hierarchy`/`cascade` iteration
  (parents before children) built into the query itself.
- **Rich query term language:** `all`/`and`, `or`/`some`, `not`/`none`, and `pair` compose
  freely and mix with plain typeids in one query call — ODE_ECS's nearest equivalent (a `View`'s
  `excludes` list plus an optional `filter` proc) is less expressive for OR/wildcard-shaped
  queries.
- **Component enable/disable:** toggle a component's presence for query-matching purposes
  without removing it (and losing its stored value) or moving the entity's row.
- **Observers on relation traits:** `on_add`/`on_remove` fire on any archetype transition,
  including ones caused by `Exclusive`/`Cascade` relation side effects, not just plain
  component add/remove.
- **Unlimited entity count and component-type count** — no capacity chosen up front for either.
- **Automatic deferred mutation scoped to iteration, no opt-in required:** any structural change
  made while a `query` is open is deferred and flushed automatically at scope exit — closer to
  moecs's always-on model than to ODE_ECS's opt-in mechanisms, but scoped per-query rather than
  per-frame.
- **A `cache_allocator` split from the general allocator**, aimed at frame-snapshot/rollback
  use cases (e.g. GGPO-style rollback netcode) where the query cache needs to survive an arena
  reset that the rest of the world doesn't.

## Bottom line

Both libraries are architecturally SoA and land at or near the same iteration hardware floor
(see [README.md](README.md), scenario 1: odecs's plain query loop vs ODE_ECS's `view_dense_slice`/
`group_dense_slice`) — the real differences are in scope and structural-operation cost, not raw
sweep speed. ODE_ECS stays a lean, fully-preallocated core with fixed capacities, immediate O(1)
structural changes by default, and a deliberately minimal relations model, plus opt-in
`Command_Buffer`/`pause_packing`/`Overbase`/serialization for the cases that need them. odecs is
a minimal *but dynamic* core inspired by Flecs: general typed relationships with wildcard
queries and hierarchy iteration, a richer query term language, and automatic per-query deferred
mutation — paid for with dynamically growing archetype storage and a very expensive entity-
creation path (its variadic `add_entity` is the single biggest number separating the two
libraries in the benchmarks — see README.md scenario 0/1). Pick ODE_ECS when you want fixed
memory budgets and fast structural operations (spawning, despawning, re-parenting) at scale;
pick odecs when you want Flecs-style general relationships and query expressiveness and can
afford (or avoid, by creating entities rarely) its archetype-churn and entity-creation costs.
