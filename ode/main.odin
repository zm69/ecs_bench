package bench_ode

import "core:fmt"
import "core:time"
import "core:mem"
import ecs "../../ode_ecs"

Position :: struct { x, y: f64 }
Velocity :: struct { x, y: f64 }

N      :: 1_000_000
FRAMES :: 100

main :: proc() {
    track: mem.Tracking_Allocator
    mem.tracking_allocator_init(&track, context.allocator)
    context.allocator = mem.tracking_allocator(&track)

    db: ecs.Database
    positions:  ecs.Table(Position)
    velocities: ecs.Table(Velocity)
    movers:     ecs.View

    if ecs.init(&db, N) != nil { fmt.println("init fail"); return }
    if ecs.table_init(&positions,  &db, N) != nil { fmt.println("pos table fail");  return }
    if ecs.table_init(&velocities, &db, N) != nil { fmt.println("vel table fail");  return }
    if ecs.view_init(&movers, &db, {&positions, &velocities}) != nil { fmt.println("view fail"); return }

    // --- Setup: spawn N entities, each with Position + Velocity ---
    sw: time.Stopwatch
    time.stopwatch_start(&sw)
    for i in 0..<N {
        eid, _ := ecs.create_entity(&db)
        p, _ := ecs.add_component(&positions,  eid)
        v, _ := ecs.add_component(&velocities, eid)
        p^ = {0, 0}
        v^ = {1, 2}
    }
    time.stopwatch_stop(&sw)
    setup_ns := time.duration_nanoseconds(time.stopwatch_duration(sw))
    live_mem := track.current_memory_allocated

    // --- Hot loop: F frames of pos += vel ---
    it: ecs.Iterator
    time.stopwatch_reset(&sw)
    time.stopwatch_start(&sw)
    for f in 0..<FRAMES {
        ecs.iterator_init(&it, &movers)
        for ecs.iterator_next(&it) {
            p := ecs.get_component(&positions,  &it)
            v := ecs.get_component(&velocities, &it)
            p.x += v.x
            p.y += v.y
        }
    }
    time.stopwatch_stop(&sw)
    iter_ns := time.duration_nanoseconds(time.stopwatch_duration(sw))

    // checksum to defeat dead-code elimination
    sample := ecs.get_component(&positions, ecs.get_entity(&db, 0))

    fmt.printfln("ODE_ECS  | view_len=%d | setup=%.1f ms | iter %d frames=%.1f ms | %.2f ns/ent/frame | live mem=%d MB | x=%.0f",
        ecs.view_len(&movers), f64(setup_ns)/1e6, FRAMES, f64(iter_ns)/1e6,
        f64(iter_ns)/f64(N)/f64(FRAMES), live_mem/1024/1024, sample.x)
}
