package bench_odecs

import "core:fmt"
import "core:time"
import "core:mem"
import ecs "../odecs/src"

Position :: struct { x, y: f64 }
Velocity :: struct { x, y: f64 }

N      :: 1_000_000
FRAMES :: 100

main :: proc() {
    track: mem.Tracking_Allocator
    mem.tracking_allocator_init(&track, context.allocator)
    context.allocator = mem.tracking_allocator(&track)

    world := ecs.create_world()

    // --- Setup: spawn N entities, each with Position + Velocity ---
    sw: time.Stopwatch
    time.stopwatch_start(&sw)
    first: ecs.EntityID
    for i in 0..<N {
        e := ecs.add_entity(world, Position{0, 0}, Velocity{1, 2})
        if i == 0 do first = e
    }
    time.stopwatch_stop(&sw)
    setup_ns := time.duration_nanoseconds(time.stopwatch_duration(sw))
    free_all(context.temp_allocator)
    live_mem := track.current_memory_allocated

    // --- Hot loop: F frames of pos += vel via query + table batch ---
    time.stopwatch_reset(&sw)
    time.stopwatch_start(&sw)
    for _ in 0..<FRAMES {
        q := ecs.query(world, {Position, Velocity})
        for arch in q {
            positions  := ecs.get_table(world, arch, Position)
            velocities := ecs.get_table(world, arch, Velocity)
            for i in 0..<len(positions) {
                positions[i].x += velocities[i].x
                positions[i].y += velocities[i].y
            }
        }
        free_all(context.temp_allocator)
    }
    time.stopwatch_stop(&sw)
    iter_ns := time.duration_nanoseconds(time.stopwatch_duration(sw))

    sample := ecs.get_component(world, first, Position)

    fmt.printfln("odecs    | archetypes=%d | setup=%.1f ms | iter %d frames=%.1f ms | %.2f ns/ent/frame | live mem=%d MB | x=%.0f",
        len(world.archetypes), f64(setup_ns)/1e6, FRAMES, f64(iter_ns)/1e6,
        f64(iter_ns)/f64(N)/f64(FRAMES), live_mem/1024/1024, sample.x)
}
