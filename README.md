# Note:

These results are expected purely because of architectural differences: ODE_ECS uses a relational database-like approach (with tables for components and views), while moecs uses an archetype approach.

All tests were generated automatically by Claude AI, and the conclusions below were also made by the AI without any human intervention.

# Extended benchmark results: ODE_ECS vs moecs

Same machine, `-o:aggressive`, same tracking-allocator harness (`mem.Tracking_Allocator`,
`current_memory_allocated` after setup). Each library uses its idiomatic fast path:
ODE_ECS via `View` + `Iterator`; moecs via an `ARCHETYPE` system driven by `progress()`.

Benchmark sources live under `G:\odin\ecs_bench\` (`ode`, `moecs_bench`, `ode_many`,
`moecs_many`, `ode_churn`, `moecs_churn`).

## Scenario 1 — Movement, 2 component types (1M entities, 100 frames)

Each entity has `Position{x,y:f64}` + `Velocity{x,y:f64}`; per frame `pos += vel`.

| Library | setup | iter/frame | ns/ent/frame | live mem |
|---------|-------|------------|--------------|----------|
| ODE_ECS | 20 ms | 1.17 ms    | **1.17**     | 122 MB   |
| moecs   | 790 ms| 4.98 ms    | 4.98         | 184 MB   |

ODE_ECS: ~38x faster setup, ~4.3x faster iteration, ~1.5x leaner. Results were
identical with `ECS_VALIDATIONS=false`, i.e. the validation asserts cost nothing on the
hot path.

## Scenario 2 — Many component types: 16 types, all on every entity (250k entities, 100 frames)

Every entity has all 16 component types (identical 16-byte shape); movement still touches
only 2 of them.

| Library | setup | iter/frame | ns/ent/frame | live mem |
|---------|-------|------------|--------------|----------|
| ODE_ECS | 29 ms | 0.28 ms    | **1.11**     | 137 MB   |
| moecs   | 81 ms | 1.65 ms    | 6.6          | **99 MB**|

## Scenario 3 — Structural churn: 10% despawn+respawn/frame + movement (100k entities, 100 frames)

| Library | total | ms/frame  | ns per churn-op | last-entity x |
|---------|-------|-----------|-----------------|---------------|
| ODE_ECS | 52 ms | **0.52**  | **26**          | 10            |
| moecs   | 116 ms| 1.16      | 58              | 9             |

# What the scenarios reveal

**1. ODE_ECS iteration is flat vs component-type count; moecs degrades.** Going from
2 -> 16 registered component types, ODE_ECS's per-entity iteration cost is unchanged
(1.17 -> 1.11 ns) — its SoA layout means iterating `{Position, Velocity}` only ever touches
those two dense arrays no matter how many other component types exist. moecs slows by ~33%
(4.98 -> 6.6 ns) because (a) each `get_mut` strides into a now-256-byte AoS chunk, so the two
fields you want are scattered across cache lines shared with 14 unused components, and (b)
the `component_index` typeid scan (`component.odin:38`) is now over 16 entries. The gap
widens from 4.3x to 5.9x exactly as predicted as the game grows more component types.

**2. Memory flips depending on density.** In this *dense* test (every entity genuinely has
all 16 components) moecs uses less memory (99 vs 137 MB), because ODE_ECS creates 16 full
`Table`s and each carries an `eid_to_ptr: []rawptr` sized to the full entity capacity
(~2 MB x 16 = 32 MB of pure index overhead) on top of its rows. moecs's single packed chunk
avoids that. Caveat both ways: if components were *sparse* (each entity has 2 of 16),
ODE_ECS would size the other 14 tables small or use `Compact_Table`/`Tiny_Table` (the
README's explicit guidance) and win memory handily, while moecs would still reserve the full
256-byte chunk per entity. So: moecs wins memory when components are universal; ODE_ECS wins
when they're sparse.

**3. Churn: ODE_ECS is ~2.2x faster even though this is moecs's design-for case.** moecs's
deferred-mutation model exists to make structural changes *safe* during iteration, not
necessarily *fast*. ODE_ECS's immediate tail-swap (`table.odin:163`) costs ~26 ns per
despawn/respawn op vs moecs's ~58 ns (deferred queue + `perform()` rebuild + per-frame
`slice.filter` over archetypes, `world.odin:755`). The `x=10` vs `x=9` in the output is not
an error — it is the 1-frame deferral made visible. ODE_ECS applies churn immediately so the
respawned entity is updated the same frame; moecs archetypes it at end-of-frame, so it starts
updating next frame. That deferral is the price and the feature (you can safely despawn
mid-system-iteration in moecs; in ODE_ECS you must follow the "don't mutate while iterating"
rule).

# Overall

Across all three workloads, ODE_ECS iterates 4–6x faster and sets up/churns ~2–40x faster,
with the iteration lead growing as component-type count rises — the structural payoff of
SoA + zero-lookup typed tables + incrementally-maintained views. moecs's wins are
feature-driven, not throughput-driven: lower memory when every entity shares the same dense
component set, safe deferred structural changes, and the relations/observers/scheduler this
synthetic suite never exercised. If your bottleneck is raw component iteration and structural
churn, ODE_ECS is decisively faster; if you want batteries-included relations/systems and
value the deferred-safety programming model, moecs's costs are the price of those features.

## Method notes / caveats

- One machine, one run set; absolute numbers vary, but the ratios track the architectural
  differences and were stable across repeated runs and across `-o:speed` / `-o:aggressive`.
- All workloads verified correct via a checksum (`x` value) that also defeats dead-code
  elimination.
- Movement (Scenario 1) is ODE_ECS's home turf; moecs does more per-frame bookkeeping by
  design (deferred actions, archetype re-filtering) to support features not exercised here.
