package bench_ode_relations

import "core:fmt"
import "core:time"
import "core:mem"
import ecs "../../ode_ecs"

Position :: struct { x, y: f64 }

N          :: 100_000
ROOTS      :: 100
BRANCH     :: 10
LEAF_START :: (N - ROOTS) / BRANCH // nodes >= LEAF_START have no children initially
BAND       :: 900                  // reparent targets: internal nodes [ROOTS, ROOTS+BAND)
FRAMES     :: 100
R          :: 10_000               // reparent ops per frame
P          :: 10_000               // children_of traversals per frame
A          :: 10_000               // ancestor walks per frame
S          :: 50                   // subtree roots cascade-destroyed at the end

main :: proc() {
    track: mem.Tracking_Allocator
    mem.tracking_allocator_init(&track, context.allocator)
    context.allocator = mem.tracking_allocator(&track)

    db: ecs.Database
    positions: ecs.Table(Position)
    rt: ecs.Relations_Table

    ecs.init(&db, N)
    ecs.table_init(&positions, &db, N)
    ecs.relations_table__init(&rt, &db, N)

    handles := make([]ecs.entity_id, N)
    defer delete(handles)

    // Setup: N entities with Position, linked into a BRANCH-ary forest with
    // ROOTS roots (parent of node i is node (i-ROOTS)/BRANCH).
    sw: time.Stopwatch
    time.stopwatch_start(&sw)
    for i in 0..<N {
        eid, _ := ecs.create_entity(&db)
        p, _ := ecs.add_component(&positions, eid); p^ = {f64(i), 0}
        handles[i] = eid
    }
    for i in ROOTS..<N {
        ecs.set_parent(&db, handles[i], handles[(i - ROOTS) / BRANCH])
    }
    time.stopwatch_stop(&sw)
    setup_ms := f64(time.duration_nanoseconds(time.stopwatch_duration(sw))) / 1e6

    live_mem := track.current_memory_allocated

    checksum := 0

    // Frames: reparent churn on leaves + children traversal + ancestor walks
    sw_rep, sw_chl, sw_anc: time.Stopwatch
    leaf_cursor, band_cursor, child_cursor, walk_cursor := 0, 0, 0, 0
    hops := 0

    for _ in 0..<FRAMES {
        time.stopwatch_start(&sw_rep)
        for _ in 0..<R {
            leaf := LEAF_START + leaf_cursor
            np   := ROOTS + (band_cursor * 13) % BAND
            ecs.set_parent(&db, handles[leaf], handles[np])
            leaf_cursor = (leaf_cursor + 1) % (N - LEAF_START)
            band_cursor += 1
            checksum += 1
        }
        time.stopwatch_stop(&sw_rep)

        time.stopwatch_start(&sw_chl)
        for _ in 0..<P {
            kids, _ := ecs.children_of(&db, handles[child_cursor])
            checksum += len(kids)
            child_cursor = (child_cursor + 1) % LEAF_START
        }
        time.stopwatch_stop(&sw_chl)

        time.stopwatch_start(&sw_anc)
        for _ in 0..<A {
            e := handles[walk_cursor]
            for {
                p, _ := ecs.parent_of(&db, e)
                if p.ix == ecs.DELETED_INDEX do break
                hops += 1
                e = p
            }
            walk_cursor = (walk_cursor + 3) % N
        }
        time.stopwatch_stop(&sw_anc)
    }
    checksum += hops

    // Cascade destroy: S depth-1 subtree roots with all their descendants
    before := ecs.entities_len(&db)
    sw_des: time.Stopwatch
    time.stopwatch_start(&sw_des)
    for i in 0..<S {
        ecs.destroy_entity(&db, handles[ROOTS + i], destroy_children=true)
    }
    time.stopwatch_stop(&sw_des)
    destroyed := before - ecs.entities_len(&db)
    checksum += destroyed

    rep_ns := f64(time.duration_nanoseconds(time.stopwatch_duration(sw_rep)))
    chl_ns := f64(time.duration_nanoseconds(time.stopwatch_duration(sw_chl)))
    anc_ns := f64(time.duration_nanoseconds(time.stopwatch_duration(sw_anc)))
    des_ms := f64(time.duration_nanoseconds(time.stopwatch_duration(sw_des))) / 1e6

    fmt.printfln("ODE_ECS  | relations | setup=%.1f ms | reparent=%.1f ns/op | children_of=%.1f ns/op | ancestor=%.1f ns/hop | cascade=%.2f ms (%d destroyed) | live mem=%d MB | x=%d",
        setup_ms, rep_ns/f64(FRAMES*R), chl_ns/f64(FRAMES*P), anc_ns/f64(hops),
        des_ms, destroyed, live_mem/1024/1024, checksum)
}
