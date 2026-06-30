package bench_moecs_churn

import "core:fmt"
import "core:time"
import "core:mem"
import ecs "../moecs/src"

Position :: struct { x, y: f64 }
Velocity :: struct { x, y: f64 }

N      :: 100_000
FRAMES :: 100
K      :: 10_000 // despawn+respawn per frame (10%)

mover_system :: proc(entities: ^[dynamic]^ecs.Entity, world: ^ecs.World) {
    for e in entities {
        if ecs.despawning(e) do continue
        p := ecs.get_mut(e, Position)
        v := ecs.get_mut(e, Velocity)
        p.x += v.x
        p.y += v.y
    }
}

main :: proc() {
    track: mem.Tracking_Allocator
    mem.tracking_allocator_init(&track, context.allocator)
    context.allocator = mem.tracking_allocator(&track)

    ecs.init()
    world := ecs.new_world(approach = .ARCHETYPE, observable = false)
    ecs.register(world, .COMPONENT, Position)
    ecs.register(world, .COMPONENT, Velocity)
    ecs.run(world)
    ecs.mount(world, components = {Position, Velocity}, callback = mover_system)

    handles := make([]^ecs.Entity, N)
    defer delete(handles)
    for i in 0..<N {
        e := ecs.spawn(world, .DYNAMIC)
        ecs.add(e, Position, &Position{0, 0})
        ecs.add(e, Velocity, &Velocity{1, 2})
        handles[i] = e
    }
    ecs.perform(world) // build archetypes

    cursor := 0
    sw: time.Stopwatch
    time.stopwatch_start(&sw)
    for f in 0..<FRAMES {
        // structural churn: despawn K (deferred), spawn K
        for k in 0..<K {
            ecs.despawn(world, handles[cursor])
            e := ecs.spawn(world, .DYNAMIC)
            ecs.add(e, Position, &Position{0, 0})
            ecs.add(e, Velocity, &Velocity{1, 2})
            handles[cursor] = e
            cursor = (cursor + 1) % N
        }
        // movement system + perform (applies the deferred churn)
        ecs.progress(world)
    }
    time.stopwatch_stop(&sw)
    total_ns := time.duration_nanoseconds(time.stopwatch_duration(sw))

    sample := ecs.get_mut(handles[0], Position)
    fmt.printfln("moecs    | churn | total=%.1f ms | %.3f ms/frame | %.1f ns/churn-op | archetypes=%d | x=%.0f",
        f64(total_ns)/1e6, f64(total_ns)/1e6/f64(FRAMES), f64(total_ns)/f64(FRAMES)/f64(2*K),
        len(world.archetypes), sample != nil ? sample.x : -1)
}
