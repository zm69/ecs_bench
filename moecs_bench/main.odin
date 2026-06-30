package bench_moecs

import "core:fmt"
import "core:time"
import "core:mem"
import ecs "../moecs/src"

Position :: struct { x, y: f64 }
Velocity :: struct { x, y: f64 }

N      :: 1_000_000
FRAMES :: 100

mover_system :: proc(entities: ^[dynamic]^ecs.Entity, world: ^ecs.World) {
    for e in entities {
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

    // --- Setup: spawn N entities, each with Position + Velocity ---
    sw: time.Stopwatch
    time.stopwatch_start(&sw)
    first: ^ecs.Entity
    for i in 0..<N {
        e := ecs.spawn(world, .DYNAMIC)
        ecs.add(e, Position, &Position{0, 0})
        ecs.add(e, Velocity, &Velocity{1, 2})
        if i == 0 do first = e
    }
    ecs.perform(world) // flush deferred archetyping so entities are live in their archetype
    time.stopwatch_stop(&sw)
    setup_ns := time.duration_nanoseconds(time.stopwatch_duration(sw))
    live_mem := track.current_memory_allocated

    // --- Hot loop: F frames of pos += vel via progress() ---
    time.stopwatch_reset(&sw)
    time.stopwatch_start(&sw)
    for f in 0..<FRAMES {
        ecs.progress(world)
    }
    time.stopwatch_stop(&sw)
    iter_ns := time.duration_nanoseconds(time.stopwatch_duration(sw))

    sample := ecs.get_mut(first, Position)

    fmt.printfln("moecs    | archetypes=%d | setup=%.1f ms | iter %d frames=%.1f ms | %.2f ns/ent/frame | live mem=%d MB | x=%.0f",
        len(world.archetypes), f64(setup_ns)/1e6, FRAMES, f64(iter_ns)/1e6,
        f64(iter_ns)/f64(N)/f64(FRAMES), live_mem/1024/1024, sample.x)
}
