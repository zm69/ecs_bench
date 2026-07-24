package bench_moecs_mixed

import "core:fmt"
import "core:time"
import "core:mem"
import ecs "../moecs/src"
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

checksum := 0

mover_system :: proc(entities: ^[dynamic]^ecs.Entity, world: ^ecs.World) {
    for e in entities {
        c2 := ecs.get_mut(e, C2)
        c3 := ecs.get_mut(e, C3)
        c4 := ecs.get_mut(e, C4)
        c3.x = c3.x + c2.x
        c3.x = c3.x + c4.x
        checksum += int(c3.x)
    }
}

main :: proc() {
    plan := gen.generate()

    track: mem.Tracking_Allocator
    mem.tracking_allocator_init(&track, context.allocator)
    context.allocator = mem.tracking_allocator(&track)

    ecs.init()
    world := ecs.new_world(approach = .ARCHETYPE, observable = false)
    ecs.register(world, .COMPONENT, C0); ecs.register(world, .COMPONENT, C1)
    ecs.register(world, .COMPONENT, C2); ecs.register(world, .COMPONENT, C3)
    ecs.register(world, .COMPONENT, C4)
    ecs.run(world)
    ecs.mount(world, components = {C2, C3, C4}, callback = mover_system)

    entities := make([]^ecs.Entity, N)
    defer delete(entities)

    sw_setup: time.Stopwatch
    time.stopwatch_start(&sw_setup)
    for i in 0..<N {
        e := ecs.spawn(world, .DYNAMIC)
        m := plan.masks[i]
        if m & (1 << 0) != 0 { v := C0{u8(i), {}}; ecs.add(e, C0, &v) }
        if m & (1 << 1) != 0 { v := C1{u8(i), {}}; ecs.add(e, C1, &v) }
        if m & (1 << 2) != 0 { v := C2{u8(i), {}}; ecs.add(e, C2, &v) }
        if m & (1 << 3) != 0 { v := C3{u8(i), {}}; ecs.add(e, C3, &v) }
        if m & (1 << 4) != 0 { v := C4{u8(i), {}}; ecs.add(e, C4, &v) }
        entities[i] = e
    }
    ecs.perform(world)
    time.stopwatch_stop(&sw_setup)
    setup_ms := f64(time.duration_nanoseconds(time.stopwatch_duration(sw_setup))) / 1e6
    live_mem := track.current_memory_allocated

    sw_add: time.Stopwatch
    time.stopwatch_start(&sw_add)
    for op in 0..<gen.ADD_COUNT {
        e := entities[plan.add_entity[op]]
        switch plan.add_component[op] {
        case 0: if !ecs.has_component(e, C0) { v := C0{u8(op), {}}; ecs.add(e, C0, &v) }
        case 1: if !ecs.has_component(e, C1) { v := C1{u8(op), {}}; ecs.add(e, C1, &v) }
        case 2: if !ecs.has_component(e, C2) { v := C2{u8(op), {}}; ecs.add(e, C2, &v) }
        case 3: if !ecs.has_component(e, C3) { v := C3{u8(op), {}}; ecs.add(e, C3, &v) }
        case 4: if !ecs.has_component(e, C4) { v := C4{u8(op), {}}; ecs.add(e, C4, &v) }
        }
    }
    ecs.perform(world)
    time.stopwatch_stop(&sw_add)
    add_ns := f64(time.duration_nanoseconds(time.stopwatch_duration(sw_add)))

    sw_rem: time.Stopwatch
    time.stopwatch_start(&sw_rem)
    for op in 0..<gen.REMOVE_COUNT {
        e := entities[plan.remove_entity[op]]
        rm := plan.remove_mask[op]
        if rm & (1 << 0) != 0 && ecs.has_component(e, C0) do ecs.remove_component(e, C0)
        if rm & (1 << 1) != 0 && ecs.has_component(e, C1) do ecs.remove_component(e, C1)
        if rm & (1 << 2) != 0 && ecs.has_component(e, C2) do ecs.remove_component(e, C2)
        if rm & (1 << 3) != 0 && ecs.has_component(e, C3) do ecs.remove_component(e, C3)
        if rm & (1 << 4) != 0 && ecs.has_component(e, C4) do ecs.remove_component(e, C4)
    }
    ecs.perform(world)
    time.stopwatch_stop(&sw_rem)
    rem_ns := f64(time.duration_nanoseconds(time.stopwatch_duration(sw_rem)))

    sw_des: time.Stopwatch
    time.stopwatch_start(&sw_des)
    for idx in plan.destroy_entity {
        ecs.despawn(world, entities[idx])
    }
    ecs.perform(world)
    time.stopwatch_stop(&sw_des)
    des_ms := f64(time.duration_nanoseconds(time.stopwatch_duration(sw_des))) / 1e6

    sw_iter: time.Stopwatch
    time.stopwatch_start(&sw_iter)
    for f in 0..<FRAMES {
        ecs.progress(world)
    }
    time.stopwatch_stop(&sw_iter)
    iter_ns := time.duration_nanoseconds(time.stopwatch_duration(sw_iter))

    fmt.printfln("moecs    | mixed | setup=%.1f ms | add=%.1f ns/op | remove=%.1f ns/op | destroy=%.2f ms (%d destroyed) | iter %d frames=%.1f ms | live mem=%d MB | x=%d",
        setup_ms, add_ns/f64(gen.ADD_COUNT), rem_ns/f64(gen.REMOVE_COUNT), des_ms, gen.DESTROY_COUNT,
        FRAMES, f64(iter_ns)/1e6, live_mem/1024/1024, checksum)
}
