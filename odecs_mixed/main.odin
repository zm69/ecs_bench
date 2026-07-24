package bench_odecs_mixed

import "core:fmt"
import "core:time"
import "core:mem"
import ecs "../odecs/src"
import gen "../scenario5_gen"

C0 :: struct { x: u8, _pad: [31]u8 }  // 32 bytes
C1 :: struct { x: u8, _pad: [63]u8 }  // 64 bytes
C2 :: struct { x: u8, _pad: [195]u8 } // 196 bytes
C3 :: struct { x: u8, _pad: [385]u8 } // 386 bytes
C4 :: struct { x: u8, _pad: [499]u8 } // 500 bytes
#assert(size_of(C0) == 32)
#assert(size_of(C1) == 64)
#assert(size_of(C2) == 196)
#assert(size_of(C3) == 386)
#assert(size_of(C4) == 500)

N      :: gen.N
FRAMES :: 100

main :: proc() {
    plan := gen.generate()

    track: mem.Tracking_Allocator
    mem.tracking_allocator_init(&track, context.allocator)
    context.allocator = mem.tracking_allocator(&track)

    world := ecs.create_world()

    handles := make([]ecs.EntityID, N)
    defer delete(handles)

    sw_setup: time.Stopwatch
    time.stopwatch_start(&sw_setup)
    for i in 0..<N {
        eid := ecs.add_entity(world)
        m := plan.masks[i]
        if m & (1 << 0) != 0 do ecs.add_component(world, eid, C0{u8(i), {}})
        if m & (1 << 1) != 0 do ecs.add_component(world, eid, C1{u8(i), {}})
        if m & (1 << 2) != 0 do ecs.add_component(world, eid, C2{u8(i), {}})
        if m & (1 << 3) != 0 do ecs.add_component(world, eid, C3{u8(i), {}})
        if m & (1 << 4) != 0 do ecs.add_component(world, eid, C4{u8(i), {}})
        handles[i] = eid
    }
    free_all(context.temp_allocator)
    time.stopwatch_stop(&sw_setup)
    setup_ms := f64(time.duration_nanoseconds(time.stopwatch_duration(sw_setup))) / 1e6
    live_mem := track.current_memory_allocated

    sw_add: time.Stopwatch
    time.stopwatch_start(&sw_add)
    for op in 0..<gen.ADD_COUNT {
        eid := handles[plan.add_entity[op]]
        switch plan.add_component[op] {
        case 0: if !ecs.has_component(world, eid, C0) do ecs.add_component(world, eid, C0{u8(op), {}})
        case 1: if !ecs.has_component(world, eid, C1) do ecs.add_component(world, eid, C1{u8(op), {}})
        case 2: if !ecs.has_component(world, eid, C2) do ecs.add_component(world, eid, C2{u8(op), {}})
        case 3: if !ecs.has_component(world, eid, C3) do ecs.add_component(world, eid, C3{u8(op), {}})
        case 4: if !ecs.has_component(world, eid, C4) do ecs.add_component(world, eid, C4{u8(op), {}})
        }
    }
    free_all(context.temp_allocator)
    time.stopwatch_stop(&sw_add)
    add_ns := f64(time.duration_nanoseconds(time.stopwatch_duration(sw_add)))

    sw_rem: time.Stopwatch
    time.stopwatch_start(&sw_rem)
    for op in 0..<gen.REMOVE_COUNT {
        eid := handles[plan.remove_entity[op]]
        rm := plan.remove_mask[op]
        if rm & (1 << 0) != 0 && ecs.has_component(world, eid, C0) do ecs.remove_component(world, eid, C0)
        if rm & (1 << 1) != 0 && ecs.has_component(world, eid, C1) do ecs.remove_component(world, eid, C1)
        if rm & (1 << 2) != 0 && ecs.has_component(world, eid, C2) do ecs.remove_component(world, eid, C2)
        if rm & (1 << 3) != 0 && ecs.has_component(world, eid, C3) do ecs.remove_component(world, eid, C3)
        if rm & (1 << 4) != 0 && ecs.has_component(world, eid, C4) do ecs.remove_component(world, eid, C4)
    }
    free_all(context.temp_allocator)
    time.stopwatch_stop(&sw_rem)
    rem_ns := f64(time.duration_nanoseconds(time.stopwatch_duration(sw_rem)))

    sw_des: time.Stopwatch
    time.stopwatch_start(&sw_des)
    for idx in plan.destroy_entity {
        ecs.remove_entity(world, handles[idx])
    }
    free_all(context.temp_allocator)
    time.stopwatch_stop(&sw_des)
    des_ms := f64(time.duration_nanoseconds(time.stopwatch_duration(sw_des))) / 1e6

    checksum := 0
    sw_iter: time.Stopwatch
    time.stopwatch_start(&sw_iter)
    for f in 0..<FRAMES {
        q := ecs.query(world, {C2, C3, C4})
        for arch in q {
            c2 := ecs.get_table(world, arch, C2)
            c3 := ecs.get_table(world, arch, C3)
            c4 := ecs.get_table(world, arch, C4)
            for i in 0..<len(c3) {
                c3[i].x = c3[i].x + c2[i].x
                c3[i].x = c3[i].x + c4[i].x
                checksum += int(c3[i].x)
            }
        }
        free_all(context.temp_allocator)
    }
    time.stopwatch_stop(&sw_iter)
    iter_ns := time.duration_nanoseconds(time.stopwatch_duration(sw_iter))

    fmt.printfln("odecs    | mixed | setup=%.1f ms | add=%.1f ns/op | remove=%.1f ns/op | destroy=%.2f ms (%d destroyed) | iter %d frames=%.1f ms | live mem=%d MB | x=%d",
        setup_ms, add_ns/f64(gen.ADD_COUNT), rem_ns/f64(gen.REMOVE_COUNT), des_ms, gen.DESTROY_COUNT,
        FRAMES, f64(iter_ns)/1e6, live_mem/1024/1024, checksum)
}
