# Feature comparison: ODE_ECS vs moecs

Two ECS libraries written in Odin, compared feature-by-feature. ODE_ECS
([github.com/odin-engine/ode_ecs](https://github.com/odin-engine/ode_ecs)) takes a
relational-database approach — typed component tables plus incrementally-maintained views.
moecs ([github.com/helioscout/moecs](https://github.com/helioscout/moecs)) takes an
archetype approach — entities grouped by component/tag signature, with a batteries-included
feature set (systems, observers, relations, resources). For measured performance numbers see
[README.md](README.md).

## At a glance

| Feature | ODE_ECS | moecs |
|---|---|---|
| Architecture | Relational: dense SoA `Table` per component type + `View`s | Archetype: AoS chunks per entity in memory blocks |
| License | zlib | MIT |
| Multiple worlds | Yes — any number of independent `Database`s | Yes — any number of `World`s in one space |
| Entity identity | `entity_id` = index + generation (stale-handle detection via `is_entity_expired`) | `^Entity` pointer; `despawning()` / `deleted()` state checks |
| Memory model | Everything preallocated up front; **no hidden allocations** during the game loop | Block/chunk allocation; new blocks allocated as the world grows |
| Custom allocators | Yes, per `Database` (propagates to tables/views) | No explicit allocator API |
| Entity count | Fixed `entities_cap` chosen at init | Unlimited (grows by blocks) |
| Component storage | 100% dense per-type arrays (SoA), tail-swap on remove | Per-entity chunk holding all its components (AoS), bit flags for presence |
| Component type limit | 128 default, unlimited via `ECS_TABLES_MULT` config | `MAX_COMPONENTS_COUNT` constant (128 default, edit manually) |
| Memory-lean table variants | `Compact_Table`, `Tiny_Table` for sparse component types | — (one chunk layout; sparse entities still reserve full chunk row) |
| Tags | `Tag_Table` (dense entity list, composable into views) | Bit-flag tags — set/unset is just a bit write, no storage |
| Queries | `View` over N tables, incrementally maintained on add/remove; `rebuild()` for late init | System match queries: components + tags + relations, plus `without` exclusion |
| Iteration API | Direct table loop, `Iterator` over views (with automatic dense fast path), `view_dense_slice` raw-SoA batch API | System callbacks driven by `progress()`; `each()` for all entities |
| Systems / scheduler | None — you write plain loops and call them yourself | Built-in: `mount` with phases (START / PRE_UPDATE / UPDATE / POST_UPDATE / MANUAL), named systems, `enable` / `disable` / `execute` |
| Structural changes | Immediate (tail-swap, O(1)) | Deferred to end of progress step (`perform` stage) |
| Mutation while iterating | Manual rule ("don't mutate while iterating") or `pause_tail_swap` / `resume_tail_swap` / `pack` deferred mode | Safe by design — despawns and archetype moves are deferred automatically |
| Observers / events | None | 9 event types (SPAWNED, DESPAWNED, ADDED, REMOVED, SET, TAGGED, UNTAGGED, RELATED, UNRELATED), per-type on/off |
| Entity relations | Parent/child via `Relations_Table` (one parent per child): O(1) set/remove/reparent, always-on cycle check, orphan-on-destroy or cascading `destroy_children` | One-to-one and one-to-many, with relationship data; built-in `ChildOf` / `ParentOf` / `RelationOf`, multi-parent, cascade despawn of orphaned children |
| Resources (singletons) | None (use plain Odin globals/structs) | First-class registered resources with `set` / `get` / `get_mut` |
| Entity lifetimes | One kind | `DYNAMIC` and `STATIC` (never-despawned) entities in separate blocks |
| Parallelism support | Designed-in batching: `iterator_init(start_row, end_row)`; one `Database` per thread; phase-separation guidance | Not addressed; deferred model implies single-threaded `progress()` |
| Validation / safety checks | `ECS_VALIDATIONS` asserts (zero cost on hot paths) | Runtime checks in API procs |
| Docs & examples | README, wiki, 6+ samples, test suite incl. randomized fuzz test | Extensive README, design diagrams, example game (mouniverse) |

## What only ODE_ECS has

- **Predictable memory:** everything is preallocated at init with an optional custom
  allocator; nothing allocates, frees, or moves during the game loop.
- **Generational entity IDs** — a saved `entity_id` can be safely checked for staleness
  after the slot is reused.
- **Dense fast path + `view_dense_slice`:** when view rows align with table rows (the common
  case), iteration reads dense arrays directly and the batch API compiles to a raw SoA sweep
  at the hardware memory floor.
- **Table variants for sparse data** (`Compact_Table`, `Tiny_Table`) to keep memory
  proportional to actual component counts.
- **`pause_tail_swap` deferred mode** — opt-in pointer stability so you can destroy entities
  mid-iteration, then `pack` the holes away.
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
- **Deferred-safety programming model:** despawn or re-archetype freely inside system code;
  changes apply at the end of the frame.
- **Free tags** (pure bit flags — no per-tag storage) and **static entity lifetime** for
  things that never despawn.
- **Unlimited entity count** — the world grows block by block, no capacity chosen up front.

## Bottom line

ODE_ECS is a lean iteration engine: fewer concepts (database, table, view, relations),
immediate O(1) structural changes, zero hidden allocations, and the fastest iteration paths —
you bring your own systems and events, and its relations are deliberately minimal
(parent/child). moecs is a framework: scheduler, queries, observers, typed relations,
and resources out of the box, paid for with deferred structural changes and
per-entity chunk storage that iterates slower (see the benchmarks). Pick ODE_ECS when raw
throughput and memory predictability dominate; pick moecs when you want the feature set and
its deferred-safety model.
