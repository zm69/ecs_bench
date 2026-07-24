package scenario5gen

import "core:math/rand"

N             :: 100_000
ADD_COUNT     :: 10_000
REMOVE_COUNT  :: 10_000
DESTROY_COUNT :: 10_000
SEED          :: 0xC0FFEE

Plan :: struct {
    masks:          []u8,  // len N; bit i set => entity i starts with component i (1-5 bits set)
    add_entity:     []int, // len ADD_COUNT; distinct indices into [0,N)
    add_component:  []int, // len ADD_COUNT; which component (0..4) to add if missing
    remove_entity:  []int, // len REMOVE_COUNT; distinct indices into [0,N)
    remove_mask:    []u8,  // len REMOVE_COUNT; 1-5 bits set = components to try removing
    destroy_entity: []int, // len DESTROY_COUNT; distinct indices into [0,N)
}

// partial Fisher-Yates over {0..4}: returns a mask with `count` random distinct bits set
shuffled_prefix_mask :: proc(count: int) -> u8 {
    idxs := [5]int{0, 1, 2, 3, 4}
    for i := 4; i > 0; i -= 1 {
        j := rand.int_max(i + 1)
        idxs[i], idxs[j] = idxs[j], idxs[i]
    }
    m: u8 = 0
    for c in 0..<count do m |= 1 << u8(idxs[c])
    return m
}

// partial Fisher-Yates over {0..<N}: returns `count` random distinct indices
pick_distinct :: proc(count: int) -> []int {
    pool := make([]int, N)
    for i in 0..<N do pool[i] = i
    for i := 0; i < count; i += 1 {
        j := i + rand.int_max(N - i)
        pool[i], pool[j] = pool[j], pool[i]
    }
    result := make([]int, count)
    copy(result, pool[:count])
    delete(pool)
    return result
}

generate :: proc() -> Plan {
    rng := rand.create(SEED)
    context.random_generator = rand.default_random_generator(&rng)

    masks := make([]u8, N)
    for i in 0..<N {
        k := rand.int_max(5) + 1 // 1..5 components
        masks[i] = shuffled_prefix_mask(k)
    }

    add_entity := pick_distinct(ADD_COUNT)
    add_component := make([]int, ADD_COUNT)
    for i in 0..<ADD_COUNT do add_component[i] = rand.int_max(5)

    remove_entity := pick_distinct(REMOVE_COUNT)
    remove_mask := make([]u8, REMOVE_COUNT)
    for i in 0..<REMOVE_COUNT {
        r := rand.int_max(5) + 1
        remove_mask[i] = shuffled_prefix_mask(r)
    }

    destroy_entity := pick_distinct(DESTROY_COUNT)

    return Plan{masks, add_entity, add_component, remove_entity, remove_mask, destroy_entity}
}
