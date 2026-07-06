package bench_odecs_churn

import "core:fmt"
import "core:time"
import "core:mem"
import ecs "../odecs/src"

Position :: struct { x, y: f64 }
Velocity :: struct { x, y: f64 }

N      :: 100_000
FRAMES :: 100
K      :: 10_000 // despawn+respawn per frame (10%)

main :: proc() {
    track: mem.Tracking_Allocator
    mem.tracking_allocator_init(&track, context.allocator)
    context.allocator = mem.tracking_allocator(&track)

    world := ecs.create_world()

    handles := make([]ecs.EntityID, N)
    defer delete(handles)
    for i in 0..<N {
        handles[i] = ecs.add_entity(world, Position{0, 0}, Velocity{1, 2})
    }
    free_all(context.temp_allocator)

    cursor := 0
    sw: time.Stopwatch
    time.stopwatch_start(&sw)
    for _ in 0..<FRAMES {
        // structural churn: despawn K, spawn K (immediate outside iteration)
        for _ in 0..<K {
            ecs.remove_entity(world, handles[cursor])
            handles[cursor] = ecs.add_entity(world, Position{0, 0}, Velocity{1, 2})
            cursor = (cursor + 1) % N
        }
        // movement pass via query + table batch
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
    total_ns := time.duration_nanoseconds(time.stopwatch_duration(sw))

    sample := ecs.get_component(world, handles[0], Position)
    fmt.printfln("odecs    | churn | total=%.1f ms | %.3f ms/frame | %.1f ns/churn-op | archetypes=%d | x=%.0f",
        f64(total_ns)/1e6, f64(total_ns)/1e6/f64(FRAMES), f64(total_ns)/f64(FRAMES)/f64(2*K),
        len(world.archetypes), sample != nil ? sample.x : -1)
}
