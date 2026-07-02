package bench_ode_one

import "core:fmt"
import "core:time"
import "core:mem"
import ecs "../../ode_ecs"

Position :: struct { x, y: f64 }

N      :: 1_000_000
FRAMES :: 100

main :: proc() {
    track: mem.Tracking_Allocator
    mem.tracking_allocator_init(&track, context.allocator)
    context.allocator = mem.tracking_allocator(&track)

    db: ecs.Database
    positions: ecs.Table(Position)
    movers:    ecs.View

    if ecs.init(&db, N) != nil { fmt.println("init fail"); return }
    if ecs.table_init(&positions, &db, N) != nil { fmt.println("pos table fail"); return }
    if ecs.view_init(&movers, &db, {&positions}) != nil { fmt.println("view fail"); return }

    // --- Setup: spawn N entities, each with Position ---
    sw: time.Stopwatch
    time.stopwatch_start(&sw)
    for i in 0..<N {
        eid, _ := ecs.create_entity(&db)
        p, _ := ecs.add_component(&positions, eid)
        p^ = {0, 2}
    }
    time.stopwatch_stop(&sw)
    setup_ns := time.duration_nanoseconds(time.stopwatch_duration(sw))
    live_mem := track.current_memory_allocated

    // --- Hot loop A: direct table iteration (idiomatic single-component path) ---
    time.stopwatch_reset(&sw)
    time.stopwatch_start(&sw)
    for f in 0..<FRAMES {
        for &p in positions.rows {
            p.x += p.y
        }
    }
    time.stopwatch_stop(&sw)
    table_ns := time.duration_nanoseconds(time.stopwatch_duration(sw))

    // --- Hot loop B: same work through a single-table View + Iterator ---
    it: ecs.Iterator
    time.stopwatch_reset(&sw)
    time.stopwatch_start(&sw)
    for f in 0..<FRAMES {
        ecs.iterator_init(&it, &movers)
        for ecs.iterator_next(&it) {
            p := ecs.get_component(&positions, &it)
            p.x += p.y
        }
    }
    time.stopwatch_stop(&sw)
    view_ns := time.duration_nanoseconds(time.stopwatch_duration(sw))

    // checksum to defeat dead-code elimination (x = 2 * FRAMES * 2 passes = 400)
    sample := ecs.get_component(&positions, ecs.get_entity(&db, 0))

    fmt.printfln("ODE_ECS  | one comp | rows=%d | setup=%.1f ms | table iter=%.1f ms (%.2f ns/ent/frame) | view iter=%.1f ms (%.2f ns/ent/frame) | live mem=%d MB | x=%.0f",
        ecs.table_len(&positions), f64(setup_ns)/1e6,
        f64(table_ns)/1e6, f64(table_ns)/f64(N)/f64(FRAMES),
        f64(view_ns)/1e6,  f64(view_ns)/f64(N)/f64(FRAMES),
        live_mem/1024/1024, sample.x)
}
