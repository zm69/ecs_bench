package bench_moecs_many

import "core:fmt"
import "core:time"
import "core:mem"
import ecs "../moecs/src"

// 32 distinct component types, all the same shape (16 bytes).
C0  :: struct { x, y: f64 }
C1  :: struct { x, y: f64 }
C2  :: struct { x, y: f64 }
C3  :: struct { x, y: f64 }
C4  :: struct { x, y: f64 }
C5  :: struct { x, y: f64 }
C6  :: struct { x, y: f64 }
C7  :: struct { x, y: f64 }
C8  :: struct { x, y: f64 }
C9  :: struct { x, y: f64 }
C10 :: struct { x, y: f64 }
C11 :: struct { x, y: f64 }
C12 :: struct { x, y: f64 }
C13 :: struct { x, y: f64 }
C14 :: struct { x, y: f64 }
C15 :: struct { x, y: f64 }
C16 :: struct { x, y: f64 }
C17 :: struct { x, y: f64 }
C18 :: struct { x, y: f64 }
C19 :: struct { x, y: f64 }
C20 :: struct { x, y: f64 }
C21 :: struct { x, y: f64 }
C22 :: struct { x, y: f64 }
C23 :: struct { x, y: f64 }
C24 :: struct { x, y: f64 }
C25 :: struct { x, y: f64 }
C26 :: struct { x, y: f64 }
C27 :: struct { x, y: f64 }
C28 :: struct { x, y: f64 }
C29 :: struct { x, y: f64 }
C30 :: struct { x, y: f64 }
C31 :: struct { x, y: f64 }

N      :: 250_000
FRAMES :: 100

mover_system :: proc(entities: ^[dynamic]^ecs.Entity, world: ^ecs.World) {
    for e in entities {
        p := ecs.get_mut(e, C0)
        v := ecs.get_mut(e, C1)
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
    ecs.register(world, .COMPONENT, C0);  ecs.register(world, .COMPONENT, C1)
    ecs.register(world, .COMPONENT, C2);  ecs.register(world, .COMPONENT, C3)
    ecs.register(world, .COMPONENT, C4);  ecs.register(world, .COMPONENT, C5)
    ecs.register(world, .COMPONENT, C6);  ecs.register(world, .COMPONENT, C7)
    ecs.register(world, .COMPONENT, C8);  ecs.register(world, .COMPONENT, C9)
    ecs.register(world, .COMPONENT, C10); ecs.register(world, .COMPONENT, C11)
    ecs.register(world, .COMPONENT, C12); ecs.register(world, .COMPONENT, C13)
    ecs.register(world, .COMPONENT, C14); ecs.register(world, .COMPONENT, C15)
    ecs.register(world, .COMPONENT, C16); ecs.register(world, .COMPONENT, C17)
    ecs.register(world, .COMPONENT, C18); ecs.register(world, .COMPONENT, C19)
    ecs.register(world, .COMPONENT, C20); ecs.register(world, .COMPONENT, C21)
    ecs.register(world, .COMPONENT, C22); ecs.register(world, .COMPONENT, C23)
    ecs.register(world, .COMPONENT, C24); ecs.register(world, .COMPONENT, C25)
    ecs.register(world, .COMPONENT, C26); ecs.register(world, .COMPONENT, C27)
    ecs.register(world, .COMPONENT, C28); ecs.register(world, .COMPONENT, C29)
    ecs.register(world, .COMPONENT, C30); ecs.register(world, .COMPONENT, C31)
    ecs.run(world)
    ecs.mount(world, components = {C0, C1}, callback = mover_system)

    sw: time.Stopwatch
    time.stopwatch_start(&sw)
    first: ^ecs.Entity
    for i in 0..<N {
        e := ecs.spawn(world, .DYNAMIC)
        ecs.add(e, C0, &C0{0, 0}); ecs.add(e, C1, &C1{1, 2})
        ecs.add(e, C2, &C2{});   ecs.add(e, C3, &C3{})
        ecs.add(e, C4, &C4{});   ecs.add(e, C5, &C5{})
        ecs.add(e, C6, &C6{});   ecs.add(e, C7, &C7{})
        ecs.add(e, C8, &C8{});   ecs.add(e, C9, &C9{})
        ecs.add(e, C10, &C10{}); ecs.add(e, C11, &C11{})
        ecs.add(e, C12, &C12{}); ecs.add(e, C13, &C13{})
        ecs.add(e, C14, &C14{}); ecs.add(e, C15, &C15{})
        ecs.add(e, C16, &C16{}); ecs.add(e, C17, &C17{})
        ecs.add(e, C18, &C18{}); ecs.add(e, C19, &C19{})
        ecs.add(e, C20, &C20{}); ecs.add(e, C21, &C21{})
        ecs.add(e, C22, &C22{}); ecs.add(e, C23, &C23{})
        ecs.add(e, C24, &C24{}); ecs.add(e, C25, &C25{})
        ecs.add(e, C26, &C26{}); ecs.add(e, C27, &C27{})
        ecs.add(e, C28, &C28{}); ecs.add(e, C29, &C29{})
        ecs.add(e, C30, &C30{}); ecs.add(e, C31, &C31{})
        if i == 0 do first = e
    }
    ecs.perform(world)
    time.stopwatch_stop(&sw)
    setup_ns := time.duration_nanoseconds(time.stopwatch_duration(sw))
    live_mem := track.current_memory_allocated

    time.stopwatch_reset(&sw)
    time.stopwatch_start(&sw)
    for f in 0..<FRAMES {
        ecs.progress(world)
    }
    time.stopwatch_stop(&sw)
    iter_ns := time.duration_nanoseconds(time.stopwatch_duration(sw))

    sample := ecs.get_mut(first, C0)
    fmt.printfln("moecs    | 32 types | setup=%.1f ms | iter %d frames=%.1f ms | %.2f ns/ent/frame | live mem=%d MB | x=%.0f",
        f64(setup_ns)/1e6, FRAMES, f64(iter_ns)/1e6, f64(iter_ns)/f64(N)/f64(FRAMES), live_mem/1024/1024, sample.x)
}
