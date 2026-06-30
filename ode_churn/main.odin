package bench_ode_churn

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
    movers:     ecs.View

    ecs.init(&db, N)
    ecs.table_init(&positions,  &db, N)
    ecs.table_init(&velocities, &db, N)
    ecs.view_init(&movers, &db, {&positions, &velocities})

    handles := make([]ecs.entity_id, N)
    defer delete(handles)
    for i in 0..<N {
        eid, _ := ecs.create_entity(&db)
        p, _ := ecs.add_component(&positions,  eid); p^ = {0, 0}
        v, _ := ecs.add_component(&velocities, eid); v^ = {1, 2}
        handles[i] = eid
    }

    it: ecs.Iterator
    cursor := 0
    sw: time.Stopwatch
    time.stopwatch_start(&sw)
    for f in 0..<FRAMES {
        // structural churn: destroy K, create K (each with both components)
        for k in 0..<K {
            ecs.destroy_entity(&db, handles[cursor])
            eid, _ := ecs.create_entity(&db)
            p, _ := ecs.add_component(&positions,  eid); p^ = {0, 0}
            v, _ := ecs.add_component(&velocities, eid); v^ = {1, 2}
            handles[cursor] = eid
            cursor = (cursor + 1) % N
        }
        // movement update over all
        ecs.iterator_init(&it, &movers)
        for ecs.iterator_next(&it) {
            p := ecs.get_component(&positions,  &it)
            v := ecs.get_component(&velocities, &it)
            p.x += v.x
            p.y += v.y
        }
    }
    time.stopwatch_stop(&sw)
    total_ns := time.duration_nanoseconds(time.stopwatch_duration(sw))

    sample := ecs.get_component(&positions, handles[0])
    fmt.printfln("ODE_ECS  | churn | total=%.1f ms | %.3f ms/frame | %.1f ns/churn-op | view_len=%d | x=%.0f",
        f64(total_ns)/1e6, f64(total_ns)/1e6/f64(FRAMES), f64(total_ns)/f64(FRAMES)/f64(2*K),
        ecs.view_len(&movers), sample != nil ? sample.x : -1)
}
