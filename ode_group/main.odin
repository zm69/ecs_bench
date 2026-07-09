package bench_ode_group

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
    movers:     ecs.Group

    if ecs.init(&db, N) != nil { fmt.println("init fail"); return }
    if ecs.table_init(&positions,  &db, N) != nil { fmt.println("pos table fail");  return }
    if ecs.table_init(&velocities, &db, N) != nil { fmt.println("vel table fail");  return }
    // Full-owning group: entities with BOTH Position and Velocity form the aligned prefix.
    if ecs.group_init(&movers, &db, {&positions, &velocities}) != nil { fmt.println("group fail"); return }

    // --- Setup: spawn N entities, each with Position + Velocity ---
    // Every add_component here completes group membership, so this also pays the
    // group's incremental swap-in cost (O(owned tables) row swaps per entity).
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

    // --- Hot loop: F frames of pos += vel, group dense slices (always aligned, no check) ---
    time.stopwatch_reset(&sw)
    time.stopwatch_start(&sw)
    for f in 0..<FRAMES {
        pos := ecs.group_dense_slice(&movers, &positions)
        vel := ecs.group_dense_slice(&movers, &velocities)
        for i in 0..<len(pos) {
            pos[i].x += vel[i].x
            pos[i].y += vel[i].y
        }
    }
    time.stopwatch_stop(&sw)
    iter_ns := time.duration_nanoseconds(time.stopwatch_duration(sw))

    // checksum to defeat dead-code elimination
    sample := ecs.get_component(&positions, ecs.get_entity(&db, 0))

    fmt.printfln("ODE_ECS group | group_len=%d | setup=%.1f ms | iter %d frames=%.1f ms | %.2f ns/ent/frame | live mem=%d MB | x=%.0f",
        ecs.group_len(&movers), f64(setup_ns)/1e6, FRAMES, f64(iter_ns)/1e6,
        f64(iter_ns)/f64(N)/f64(FRAMES), live_mem/1024/1024, sample.x)
}
