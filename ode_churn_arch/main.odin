package bench_ode_churn_arch

import "core:fmt"
import "core:time"
import "core:mem"
import ecs "../../ode_ecs"

Position :: struct { x, y: f64 }
Velocity :: struct { x, y: f64 }

N      :: 100_000
FRAMES :: 100
K      :: 10_000 // despawn+respawn per frame (10%)

main :: proc() {
    track: mem.Tracking_Allocator
    mem.tracking_allocator_init(&track, context.allocator)
    context.allocator = mem.tracking_allocator(&track)

    db: ecs.Database
    pv: ecs.Arch_Table // Position + Velocity, single archetype row

    ecs.init(&db, N)
    ecs.arch_table__init(&pv, &db, N, {Position, Velocity})

    handles := make([]ecs.entity_id, N)
    defer delete(handles)
    for i in 0..<N {
        eid, _ := ecs.arch_table__create_entity(&pv)
        p := ecs.arch_table__get_component(&pv, eid, Position); p^ = {0, 0}
        v := ecs.arch_table__get_component(&pv, eid, Velocity); v^ = {1, 2}
        handles[i] = eid
    }

    cursor := 0
    sw: time.Stopwatch
    time.stopwatch_start(&sw)
    for f in 0..<FRAMES {
        // structural churn: destroy K, create K (each a fresh whole archetype row).
        // destroy_entity walks the entity's set bits generically, so it removes the
        // Arch_Table row the same way it would a plain Table's — no Arch_Table-specific
        // call needed on the destroy side.
        for k in 0..<K {
            ecs.destroy_entity(&db, handles[cursor])
            eid, _ := ecs.arch_table__create_entity(&pv)
            p := ecs.arch_table__get_component(&pv, eid, Position); p^ = {0, 0}
            v := ecs.arch_table__get_component(&pv, eid, Velocity); v^ = {1, 2}
            handles[cursor] = eid
            cursor = (cursor + 1) % N
        }
        // movement update over all: straight off the archetype's own columns, always packed
        pos := ecs.arch_table__dense_slice(&pv, Position)
        vel := ecs.arch_table__dense_slice(&pv, Velocity)
        for i in 0..<len(pos) {
            pos[i].x += vel[i].x
            pos[i].y += vel[i].y
        }
    }
    time.stopwatch_stop(&sw)
    total_ns := time.duration_nanoseconds(time.stopwatch_duration(sw))

    sample := ecs.arch_table__get_component(&pv, handles[0], Position)
    fmt.printfln("ODE_ECS arch | churn | total=%.1f ms | %.3f ms/frame | %.1f ns/churn-op | rows=%d | x=%.0f",
        f64(total_ns)/1e6, f64(total_ns)/1e6/f64(FRAMES), f64(total_ns)/f64(FRAMES)/f64(2*K),
        ecs.table_len(&pv), sample != nil ? sample.x : -1)
}
