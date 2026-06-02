// hashmap: an open-addressing hash table of u64 keys, written out the same way in every
// language: linear probing, a power-of-two table at least twice the keys, a multiplicative
// hash. n keys from splitmix64 are inserted, then looked up again with n keys of another
// seed. Random memory access and a branch per probe. Prints the hits and the sum of their
// values.
// The C version of main.fels: the same algorithm, data layout and output.

#include <inttypes.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#ifdef _WIN32
#include <fcntl.h>
#include <io.h>
#endif

// `keys` and `vals` both have `cap` slots.
typedef struct { uint64_t *keys; uint64_t *vals; size_t cap; uint64_t shift; } Table;

static uint64_t splitmix(uint64_t *state) {
    *state = *state + UINT64_C(0x9E3779B97F4A7C15);
    uint64_t z = *state;
    z = (z ^ (z >> 30)) * UINT64_C(0xBF58476D1CE4E5B9);
    z = (z ^ (z >> 27)) * UINT64_C(0x94D049BB133111EB);
    return (z ^ (z >> 31)) | 1; // 0 marks an empty slot
}

static size_t slot(const Table *t, uint64_t key) {
    return (size_t)((key * UINT64_C(0x9E3779B97F4A7C15)) >> t->shift);
}

static void insert(Table *t, uint64_t key, uint64_t val) {
    size_t mask = t->cap - 1;
    size_t i = slot(t, key);
    while (t->keys[i] != 0 && t->keys[i] != key) i = (i + 1) & mask;
    t->keys[i] = key;
    t->vals[i] = val;
}

// Whether `key` is in `t`, and if so its value in `*val`.
static bool find(const Table *t, uint64_t key, uint64_t *val) {
    size_t mask = t->cap - 1;
    size_t i = slot(t, key);
    while (t->keys[i] != 0) {
        if (t->keys[i] == key) {
            *val = t->vals[i];
            return true;
        }
        i = (i + 1) & mask;
    }
    return false;
}

// The first argument as a number, or `fallback`.
static int64_t arg_int(int argc, char **argv, int64_t fallback) {
    if (argc < 2) return fallback;
    return strtoll(argv[1], NULL, 10);
}

int main(int argc, char **argv) {
#ifdef _WIN32
    _setmode(_fileno(stdout), _O_BINARY); // "\n" stays LF, as the Fels and Zig versions print it
#endif
    size_t n = (size_t)arg_int(argc, argv, 1000);
    uint64_t bits = 1;
    while (((size_t)1 << (uint32_t)bits) < 2 * n) bits += 1;
    size_t cap = (size_t)1 << (uint32_t)bits;
    Table t = { malloc(cap * sizeof(uint64_t)), malloc(cap * sizeof(uint64_t)), cap, 64 - bits };
    if (t.keys == NULL || t.vals == NULL) {
        fputs("out of memory\n", stderr);
        return 1;
    }
    for (size_t i = 0; i < cap; i++) {
        t.keys[i] = 0;
        t.vals[i] = 0;
    }
    uint64_t seed = 1;
    for (size_t i = 0; i < n; i++) insert(&t, splitmix(&seed), (uint64_t)i);
    uint64_t found = 0;
    uint64_t sum = 0;
    uint64_t v;
    seed = 1;
    for (size_t i = 0; i < n; i++) {
        if (find(&t, splitmix(&seed), &v)) {
            found += 1;
            sum = sum + v;
        }
    }
    seed = 2;
    for (size_t i = 0; i < n; i++) {
        if (find(&t, splitmix(&seed), &v)) {
            found += 1;
            sum = sum + v;
        }
    }
    printf("%" PRIu64 " %" PRIu64 "\n", found, sum);
    return 0;
}
