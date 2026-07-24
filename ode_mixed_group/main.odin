package bench_ode_mixed_group

import "core:fmt"
import "core:time"
import "core:mem"
import ecs "../../ode_ecs"
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

    db: ecs.Database
    t0: ecs.Table(C0); t1: ecs.Table(C1); t2: ecs.Table(C2); t3: ecs.Table(C3); t4: ecs.Table(C4)
    grp: ecs.Group

    ecs.init(&db, N)
    ecs.table_init(&t0, &db, N); ecs.table_init(&t1, &db, N); ecs.table_init(&t2, &db, N)
    ecs.table_init(&t3, &db, N); ecs.table_init(&t4, &db, N)
    ecs.group_init(&grp, &db, {&t2, &t3, &t4})

    handles := make([]ecs.entity_id, N)
    defer delete(handles)

    sw_setup: time.Stopwatch
    time.stopwatch_start(&sw_setup)
    for i in 0..<N {
        eid, _ := ecs.create_entity(&db)
        m := plan.masks[i]
        if m & (1 << 0) != 0 { p, _ := ecs.add_component(&t0, eid); p^ = {u8(i), {}} }
        if m & (1 << 1) != 0 { p, _ := ecs.add_component(&t1, eid); p^ = {u8(i), {}} }
        if m & (1 << 2) != 0 { p, _ := ecs.add_component(&t2, eid); p^ = {u8(i), {}} }
        if m & (1 << 3) != 0 { p, _ := ecs.add_component(&t3, eid); p^ = {u8(i), {}} }
        if m & (1 << 4) != 0 { p, _ := ecs.add_component(&t4, eid); p^ = {u8(i), {}} }
        handles[i] = eid
    }
    time.stopwatch_stop(&sw_setup)
    setup_ms := f64(time.duration_nanoseconds(time.stopwatch_duration(sw_setup))) / 1e6
    live_mem := track.current_memory_allocated

    sw_add: time.Stopwatch
    time.stopwatch_start(&sw_add)
    for op in 0..<gen.ADD_COUNT {
        eid := handles[plan.add_entity[op]]
        switch plan.add_component[op] {
        case 0: if !ecs.has_component(&t0, eid) { p, _ := ecs.add_component(&t0, eid); p^ = {u8(op), {}} }
        case 1: if !ecs.has_component(&t1, eid) { p, _ := ecs.add_component(&t1, eid); p^ = {u8(op), {}} }
        case 2: if !ecs.has_component(&t2, eid) { p, _ := ecs.add_component(&t2, eid); p^ = {u8(op), {}} }
        case 3: if !ecs.has_component(&t3, eid) { p, _ := ecs.add_component(&t3, eid); p^ = {u8(op), {}} }
        case 4: if !ecs.has_component(&t4, eid) { p, _ := ecs.add_component(&t4, eid); p^ = {u8(op), {}} }
        }
    }
    time.stopwatch_stop(&sw_add)
    add_ns := f64(time.duration_nanoseconds(time.stopwatch_duration(sw_add)))

    sw_rem: time.Stopwatch
    time.stopwatch_start(&sw_rem)
    for op in 0..<gen.REMOVE_COUNT {
        eid := handles[plan.remove_entity[op]]
        rm := plan.remove_mask[op]
        if rm & (1 << 0) != 0 && ecs.has_component(&t0, eid) do ecs.remove_component(&t0, eid)
        if rm & (1 << 1) != 0 && ecs.has_component(&t1, eid) do ecs.remove_component(&t1, eid)
        if rm & (1 << 2) != 0 && ecs.has_component(&t2, eid) do ecs.remove_component(&t2, eid)
        if rm & (1 << 3) != 0 && ecs.has_component(&t3, eid) do ecs.remove_component(&t3, eid)
        if rm & (1 << 4) != 0 && ecs.has_component(&t4, eid) do ecs.remove_component(&t4, eid)
    }
    time.stopwatch_stop(&sw_rem)
    rem_ns := f64(time.duration_nanoseconds(time.stopwatch_duration(sw_rem)))

    before := ecs.entities_len(&db)
    sw_des: time.Stopwatch
    time.stopwatch_start(&sw_des)
    for idx in plan.destroy_entity {
        ecs.destroy_entity(&db, handles[idx])
    }
    time.stopwatch_stop(&sw_des)
    des_ms := f64(time.duration_nanoseconds(time.stopwatch_duration(sw_des))) / 1e6
    alive := ecs.entities_len(&db)
    destroyed := before - alive

    checksum := 0
    sw_iter: time.Stopwatch
    time.stopwatch_start(&sw_iter)
    for f in 0..<FRAMES {
        c2 := ecs.group_dense_slice(&grp, &t2)
        c3 := ecs.group_dense_slice(&grp, &t3)
        c4 := ecs.group_dense_slice(&grp, &t4)
        for i in 0..<len(c3) {
            c3[i].x = c3[i].x + c2[i].x
            c3[i].x = c3[i].x + c4[i].x
            checksum += int(c3[i].x)
        }
    }
    time.stopwatch_stop(&sw_iter)
    iter_ns := time.duration_nanoseconds(time.stopwatch_duration(sw_iter))

    matched := ecs.group_len(&grp)
    fmt.printfln("ODE_ECS  | mixed (group) | setup=%.1f ms | add=%.1f ns/op | remove=%.1f ns/op | destroy=%.2f ms (%d destroyed, %d alive) | iter %d frames=%.1f ms | %.2f ns/ent/frame | matched=%d | live mem=%d MB | x=%d",
        setup_ms, add_ns/f64(gen.ADD_COUNT), rem_ns/f64(gen.REMOVE_COUNT), des_ms, destroyed, alive,
        FRAMES, f64(iter_ns)/1e6, f64(iter_ns)/f64(matched)/f64(FRAMES), matched, live_mem/1024/1024, checksum)
}
