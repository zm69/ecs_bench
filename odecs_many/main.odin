package bench_odecs_many

import "core:fmt"
import "core:time"
import "core:mem"
import ecs "../odecs/src"

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

main :: proc() {
    track: mem.Tracking_Allocator
    mem.tracking_allocator_init(&track, context.allocator)
    context.allocator = mem.tracking_allocator(&track)

    world := ecs.create_world()

    sw: time.Stopwatch
    time.stopwatch_start(&sw)
    first: ecs.EntityID
    for i in 0..<N {
        e := ecs.add_entity(world,
            C0{0, 0},  C1{1, 2},  C2{},  C3{},  C4{},  C5{},  C6{},  C7{},
            C8{},  C9{},  C10{}, C11{}, C12{}, C13{}, C14{}, C15{},
            C16{}, C17{}, C18{}, C19{}, C20{}, C21{}, C22{}, C23{},
            C24{}, C25{}, C26{}, C27{}, C28{}, C29{}, C30{}, C31{})
        if i == 0 do first = e
    }
    time.stopwatch_stop(&sw)
    setup_ns := time.duration_nanoseconds(time.stopwatch_duration(sw))
    free_all(context.temp_allocator)
    live_mem := track.current_memory_allocated

    time.stopwatch_reset(&sw)
    time.stopwatch_start(&sw)
    for _ in 0..<FRAMES {
        q := ecs.query(world, {C0, C1})
        for arch in q {
            c0 := ecs.get_table(world, arch, C0)
            c1 := ecs.get_table(world, arch, C1)
            for i in 0..<len(c0) {
                c0[i].x += c1[i].x
                c0[i].y += c1[i].y
            }
        }
        free_all(context.temp_allocator)
    }
    time.stopwatch_stop(&sw)
    iter_ns := time.duration_nanoseconds(time.stopwatch_duration(sw))

    sample := ecs.get_component(world, first, C0)
    fmt.printfln("odecs    | 32 types | setup=%.1f ms | iter %d frames=%.1f ms | %.2f ns/ent/frame | live mem=%d MB | x=%.0f",
        f64(setup_ns)/1e6, FRAMES, f64(iter_ns)/1e6, f64(iter_ns)/f64(N)/f64(FRAMES), live_mem/1024/1024, sample.x)
}
