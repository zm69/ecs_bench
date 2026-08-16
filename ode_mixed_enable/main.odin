package bench_ode_mixed_enable

import "core:fmt"
import "core:time"
import "core:mem"
import ecs "../../ode/ode_ecs"
import gen "../scenario5_gen"

// Same scenario 5 workload as ode_mixed, but using ODE_ECS's enable_component/
// disable_component (soft, bitset-based toggle: no data movement, no tail-swap) instead
// of add_component/remove_component (real structural change) for the add/remove phases.
// Requires every entity to physically hold all 5 components up front (enable/disable can't
// create/destroy storage, only mask it from View matching) — the mask that in ode_mixed
// controls physical presence here controls only the initial enabled/disabled bit, applied
// right after each unconditional add_component. Trades memory (full C0..C4 storage per
// entity, not just the components in its mask) for near-free toggle ops.

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
    mv: ecs.View

    ecs.init(&db, N)
    ecs.table_init(&t0, &db, N); ecs.table_init(&t1, &db, N); ecs.table_init(&t2, &db, N)
    ecs.table_init(&t3, &db, N); ecs.table_init(&t4, &db, N)
    ecs.view_init(&mv, &db, {&t2, &t3, &t4})

    handles := make([]ecs.entity_id, N)
    defer delete(handles)

    // --- Setup: every entity gets ALL 5 components physically added, then components
    // absent from its random mask are immediately disabled (soft-excluded from `mv`). ---
    sw_setup: time.Stopwatch
    time.stopwatch_start(&sw_setup)
    for i in 0..<N {
        eid, _ := ecs.create_entity(&db)
        m := plan.masks[i]
        p0, _ := ecs.add_component(&t0, eid); p0^ = {u8(i), {}}
        p1, _ := ecs.add_component(&t1, eid); p1^ = {u8(i), {}}
        p2, _ := ecs.add_component(&t2, eid); p2^ = {u8(i), {}}
        p3, _ := ecs.add_component(&t3, eid); p3^ = {u8(i), {}}
        p4, _ := ecs.add_component(&t4, eid); p4^ = {u8(i), {}}
        if m & (1 << 0) == 0 do ecs.disable_component(&t0, eid)
        if m & (1 << 1) == 0 do ecs.disable_component(&t1, eid)
        if m & (1 << 2) == 0 do ecs.disable_component(&t2, eid)
        if m & (1 << 3) == 0 do ecs.disable_component(&t3, eid)
        if m & (1 << 4) == 0 do ecs.disable_component(&t4, eid)
        handles[i] = eid
    }
    time.stopwatch_stop(&sw_setup)
    setup_ms := f64(time.duration_nanoseconds(time.stopwatch_duration(sw_setup))) / 1e6
    live_mem := track.current_memory_allocated

    // --- "Add" phase: enable_component instead of add_component (bit flip, no data move) ---
    sw_add: time.Stopwatch
    time.stopwatch_start(&sw_add)
    for op in 0..<gen.ADD_COUNT {
        eid := handles[plan.add_entity[op]]
        switch plan.add_component[op] {
        case 0: if ecs.is_component_disabled(&t0, eid) do ecs.enable_component(&t0, eid)
        case 1: if ecs.is_component_disabled(&t1, eid) do ecs.enable_component(&t1, eid)
        case 2: if ecs.is_component_disabled(&t2, eid) do ecs.enable_component(&t2, eid)
        case 3: if ecs.is_component_disabled(&t3, eid) do ecs.enable_component(&t3, eid)
        case 4: if ecs.is_component_disabled(&t4, eid) do ecs.enable_component(&t4, eid)
        }
    }
    time.stopwatch_stop(&sw_add)
    add_ns := f64(time.duration_nanoseconds(time.stopwatch_duration(sw_add)))

    // --- "Remove" phase: disable_component instead of remove_component (bit flip, data kept) ---
    sw_rem: time.Stopwatch
    time.stopwatch_start(&sw_rem)
    for op in 0..<gen.REMOVE_COUNT {
        eid := handles[plan.remove_entity[op]]
        rm := plan.remove_mask[op]
        if rm & (1 << 0) != 0 && !ecs.is_component_disabled(&t0, eid) do ecs.disable_component(&t0, eid)
        if rm & (1 << 1) != 0 && !ecs.is_component_disabled(&t1, eid) do ecs.disable_component(&t1, eid)
        if rm & (1 << 2) != 0 && !ecs.is_component_disabled(&t2, eid) do ecs.disable_component(&t2, eid)
        if rm & (1 << 3) != 0 && !ecs.is_component_disabled(&t3, eid) do ecs.disable_component(&t3, eid)
        if rm & (1 << 4) != 0 && !ecs.is_component_disabled(&t4, eid) do ecs.disable_component(&t4, eid)
    }
    time.stopwatch_stop(&sw_rem)
    rem_ns := f64(time.duration_nanoseconds(time.stopwatch_duration(sw_rem)))

    // --- Destroy phase: unchanged, real entity destruction (not a component-membership op) ---
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
    it: ecs.Iterator
    sw_iter: time.Stopwatch
    time.stopwatch_start(&sw_iter)
    for f in 0..<FRAMES {
        ecs.iterator_init(&it, &mv)
        for ecs.iterator_next(&it) {
            c2 := ecs.get_component(&t2, &it)
            c3 := ecs.get_component(&t3, &it)
            c4 := ecs.get_component(&t4, &it)
            c3.x = c3.x + c2.x
            c3.x = c3.x + c4.x
            checksum += int(c3.x)
        }
    }
    time.stopwatch_stop(&sw_iter)
    iter_ns := time.duration_nanoseconds(time.stopwatch_duration(sw_iter))

    matched := ecs.view_len(&mv)
    fmt.printfln("ODE_ECS  | mixed (enable/disable) | setup=%.1f ms | add=%.1f ns/op | remove=%.1f ns/op | destroy=%.2f ms (%d destroyed, %d alive) | iter %d frames=%.1f ms | %.2f ns/ent/frame | matched=%d | live mem=%d MB | x=%d",
        setup_ms, add_ns/f64(gen.ADD_COUNT), rem_ns/f64(gen.REMOVE_COUNT), des_ms, destroyed, alive,
        FRAMES, f64(iter_ns)/1e6, f64(iter_ns)/f64(matched)/f64(FRAMES), matched, live_mem/1024/1024, checksum)
}
