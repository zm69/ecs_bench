package bench_ode_churn_group

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
    positions:  ecs.Table(Position)
    velocities: ecs.Table(Velocity)
    movers:     ecs.Group

    ecs.init(&db, N)
    ecs.table_init(&positions,  &db, N)
    ecs.table_init(&velocities, &db, N)
    ecs.group_init(&movers, &db, {&positions, &velocities})

    handles := make([]ecs.entity_id, N)
    defer delete(handles)
    for i in 0..<N {
        eid, _ := ecs.create_entity(&db)
        p, _ := ecs.add_component(&positions,  eid); p^ = {0, 0}
        v, _ := ecs.add_component(&velocities, eid); v^ = {1, 2}
        handles[i] = eid
    }

    cursor := 0
    sw: time.Stopwatch
    time.stopwatch_start(&sw)
    for f in 0..<FRAMES {
        // structural churn: destroy K, create K (each with both components).
        // Every destroy/create swaps the entity out of / back into the group's
        // aligned prefix (group__on_add / the table's own removal notify).
        for k in 0..<K {
            ecs.destroy_entity(&db, handles[cursor])
            eid, _ := ecs.create_entity(&db)
            p, _ := ecs.add_component(&positions,  eid); p^ = {0, 0}
            v, _ := ecs.add_component(&velocities, eid); v^ = {1, 2}
            handles[cursor] = eid
            cursor = (cursor + 1) % N
        }
        // movement update over all: group dense slices, always aligned (no fallback needed)
        pos := ecs.group_dense_slice(&movers, &positions)
        vel := ecs.group_dense_slice(&movers, &velocities)
        for i in 0..<len(pos) {
            pos[i].x += vel[i].x
            pos[i].y += vel[i].y
        }
    }
    time.stopwatch_stop(&sw)
    total_ns := time.duration_nanoseconds(time.stopwatch_duration(sw))

    sample := ecs.get_component(&positions, handles[0])
    fmt.printfln("ODE_ECS group | churn | total=%.1f ms | %.3f ms/frame | %.1f ns/churn-op | group_len=%d | x=%.0f",
        f64(total_ns)/1e6, f64(total_ns)/1e6/f64(FRAMES), f64(total_ns)/f64(FRAMES)/f64(2*K),
        ecs.group_len(&movers), sample != nil ? sample.x : -1)
}
