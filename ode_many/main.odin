package bench_ode_many

import "core:fmt"
import "core:time"
import "core:mem"
import ecs "../../ode_ecs"

// 16 distinct component types, all the same shape (16 bytes).
C0  :: struct { x, y: f64 } // "Position"
C1  :: struct { x, y: f64 } // "Velocity"
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

N      :: 250_000
FRAMES :: 100

main :: proc() {
    track: mem.Tracking_Allocator
    mem.tracking_allocator_init(&track, context.allocator)
    context.allocator = mem.tracking_allocator(&track)

    db: ecs.Database
    t0:  ecs.Table(C0);  t1:  ecs.Table(C1);  t2:  ecs.Table(C2);  t3:  ecs.Table(C3)
    t4:  ecs.Table(C4);  t5:  ecs.Table(C5);  t6:  ecs.Table(C6);  t7:  ecs.Table(C7)
    t8:  ecs.Table(C8);  t9:  ecs.Table(C9);  t10: ecs.Table(C10); t11: ecs.Table(C11)
    t12: ecs.Table(C12); t13: ecs.Table(C13); t14: ecs.Table(C14); t15: ecs.Table(C15)
    movers: ecs.View

    ecs.init(&db, N)
    ecs.table_init(&t0,&db,N);  ecs.table_init(&t1,&db,N);  ecs.table_init(&t2,&db,N);  ecs.table_init(&t3,&db,N)
    ecs.table_init(&t4,&db,N);  ecs.table_init(&t5,&db,N);  ecs.table_init(&t6,&db,N);  ecs.table_init(&t7,&db,N)
    ecs.table_init(&t8,&db,N);  ecs.table_init(&t9,&db,N);  ecs.table_init(&t10,&db,N); ecs.table_init(&t11,&db,N)
    ecs.table_init(&t12,&db,N); ecs.table_init(&t13,&db,N); ecs.table_init(&t14,&db,N); ecs.table_init(&t15,&db,N)
    ecs.view_init(&movers, &db, {&t0, &t1})

    sw: time.Stopwatch
    time.stopwatch_start(&sw)
    for i in 0..<N {
        eid, _ := ecs.create_entity(&db)
        p, _ := ecs.add_component(&t0, eid); p^ = {0, 0}
        v, _ := ecs.add_component(&t1, eid); v^ = {1, 2}
        ecs.add_component(&t2, eid);  ecs.add_component(&t3, eid)
        ecs.add_component(&t4, eid);  ecs.add_component(&t5, eid)
        ecs.add_component(&t6, eid);  ecs.add_component(&t7, eid)
        ecs.add_component(&t8, eid);  ecs.add_component(&t9, eid)
        ecs.add_component(&t10, eid); ecs.add_component(&t11, eid)
        ecs.add_component(&t12, eid); ecs.add_component(&t13, eid)
        ecs.add_component(&t14, eid); ecs.add_component(&t15, eid)
    }
    time.stopwatch_stop(&sw)
    setup_ns := time.duration_nanoseconds(time.stopwatch_duration(sw))
    live_mem := track.current_memory_allocated

    it: ecs.Iterator
    time.stopwatch_reset(&sw)
    time.stopwatch_start(&sw)
    for f in 0..<FRAMES {
        ecs.iterator_init(&it, &movers)
        for ecs.iterator_next(&it) {
            p := ecs.get_component(&t0, &it)
            v := ecs.get_component(&t1, &it)
            p.x += v.x
            p.y += v.y
        }
    }
    time.stopwatch_stop(&sw)
    iter_ns := time.duration_nanoseconds(time.stopwatch_duration(sw))

    sample := ecs.get_component(&t0, ecs.get_entity(&db, 0))
    fmt.printfln("ODE_ECS  | 16 types | setup=%.1f ms | iter %d frames=%.1f ms | %.2f ns/ent/frame | live mem=%d MB | x=%.0f",
        f64(setup_ns)/1e6, FRAMES, f64(iter_ns)/1e6, f64(iter_ns)/f64(N)/f64(FRAMES), live_mem/1024/1024, sample.x)
}
