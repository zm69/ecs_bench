package bench_ode_arch

import "core:fmt"
import "core:time"
import "core:mem"
import ecs "../../ode/ode_ecs"

Position :: struct { x, y: f64 }
Velocity :: struct { x, y: f64 }

N      :: 1_000_000
FRAMES :: 100

main :: proc() {
    track: mem.Tracking_Allocator
    mem.tracking_allocator_init(&track, context.allocator)
    context.allocator = mem.tracking_allocator(&track)

    db: ecs.Database
    pv: ecs.Arch_Table // Position + Velocity as one archetype row (true SoA, one shared index)

    if ecs.init(&db, N) != nil { fmt.println("init fail"); return }
    if ecs.arch_table__init(&pv, &db, N, {Position, Velocity}) != nil { fmt.println("arch init fail"); return }

    // --- Setup: spawn N entities, each getting a Position+Velocity row in one call ---
    sw: time.Stopwatch
    time.stopwatch_start(&sw)
    for i in 0..<N {
        eid, _ := ecs.arch_table__create_entity(&pv)
        p := ecs.arch_table__get_component(&pv, eid, Position); p^ = {0, 0}
        v := ecs.arch_table__get_component(&pv, eid, Velocity); v^ = {1, 2}
    }
    time.stopwatch_stop(&sw)
    setup_ns := time.duration_nanoseconds(time.stopwatch_duration(sw))
    live_mem := track.current_memory_allocated

    // --- Hot loop: F frames of pos += vel, straight off the archetype's own columns ---
    time.stopwatch_reset(&sw)
    time.stopwatch_start(&sw)
    for f in 0..<FRAMES {
        pos := ecs.arch_table__dense_slice(&pv, Position)
        vel := ecs.arch_table__dense_slice(&pv, Velocity)
        for i in 0..<len(pos) {
            pos[i].x += vel[i].x
            pos[i].y += vel[i].y
        }
    }
    time.stopwatch_stop(&sw)
    iter_ns := time.duration_nanoseconds(time.stopwatch_duration(sw))

    // checksum to defeat dead-code elimination
    sample := ecs.arch_table__get_component(&pv, ecs.get_entity(&db, 0), Position)

    fmt.printfln("ODE_ECS arch | rows=%d | setup=%.1f ms | iter %d frames=%.1f ms | %.2f ns/ent/frame | live mem=%d MB | x=%.0f",
        ecs.table_len(&pv), f64(setup_ns)/1e6, FRAMES, f64(iter_ns)/1e6,
        f64(iter_ns)/f64(N)/f64(FRAMES), live_mem/1024/1024, sample.x)
}
