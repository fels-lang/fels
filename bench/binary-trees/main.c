// binary-trees: the Benchmarks Game's binary trees, built and walked many times over.
// Many small allocations and pointer chasing. Every tree is allocated in an arena that is
// reset after it is checked, in all three languages.
// The C version of main.fels: the same algorithm, data layout and output.

#include <inttypes.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#ifdef _WIN32
#include <fcntl.h>
#include <io.h>
#endif

// A chunked bump-pointer arena, the counterpart of the Fels std.heap Arena that main.fels
// uses, and the same design: memory comes from malloc in chunks of ARENA_CHUNK bytes, an
// allocation is the next 16-byte-aligned piece of the current chunk, and `arena_reset` rewinds
// to the first chunk, keeping all of them for reuse (a later chunk is marked empty when an
// allocation moves into it, so a reset takes the same time however many chunks there are).
// Like the Fels arena it never gives a chunk back; the process exit does.

#define ARENA_CHUNK 65536 // payload bytes of a chunk, as in std.heap
#define ARENA_ALIGN 16

typedef struct Chunk {
    struct Chunk *next; // the next chunk, in the order they are used
    size_t cap;         // payload bytes
    size_t used;        // payload bytes handed out
    _Alignas(ARENA_ALIGN) unsigned char data[];
} Chunk;

typedef struct {
    Chunk *first; // the oldest chunk, where a reset starts over
    Chunk *head;  // the chunk allocations come from
} Arena;

static Arena arena_make(void) {
    Arena a = { NULL, NULL };
    return a;
}

// `size` uninitialized bytes from `a`. Aborts when out of memory.
static void *arena_alloc(Arena *a, size_t size) {
    Chunk *c = a->head;
    if (c != NULL) {
        size_t at = (c->used + ARENA_ALIGN - 1) & ~(size_t)(ARENA_ALIGN - 1);
        if (at + size <= c->cap) {
            c->used = at + size;
            return c->data + at;
        }
        // The current chunk is full. After a reset, the next one is free for reuse.
        Chunk *next = c->next;
        if (next != NULL && size <= next->cap) {
            next->used = size;
            a->head = next;
            return next->data;
        }
    }
    // A new chunk, linked in after the current one. A larger allocation gets its own.
    size_t cap = size > ARENA_CHUNK ? size : ARENA_CHUNK;
    Chunk *fresh = malloc(sizeof(Chunk) + cap);
    if (fresh == NULL) {
        fputs("out of memory\n", stderr);
        abort();
    }
    fresh->cap = cap;
    fresh->used = size;
    if (c != NULL) {
        fresh->next = c->next;
        c->next = fresh;
    } else {
        fresh->next = NULL;
        a->first = fresh;
    }
    a->head = fresh;
    return fresh->data;
}

// Empties `a` and keeps its chunks: what was allocated is gone, the memory is reused.
static void arena_reset(Arena *a) {
    if (a->first != NULL) a->first->used = 0;
    a->head = a->first;
}

typedef struct Node { struct Node *left, *right; } Node;

static Node *bottom_up(int32_t depth, Arena *a) {
    Node *node = arena_alloc(a, sizeof(Node));
    if (depth > 0) {
        node->left = bottom_up(depth - 1, a);
        node->right = bottom_up(depth - 1, a);
    } else {
        node->left = NULL;
        node->right = NULL;
    }
    return node;
}

static int32_t check(const Node *node) {
    if (node->left != NULL) {
        if (node->right != NULL) return 1 + check(node->left) + check(node->right);
    }
    return 1;
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
    int32_t min_depth = 4;
    int32_t max_depth = (int32_t)arg_int(argc, argv, 10);
    if (max_depth < min_depth + 2) max_depth = min_depth + 2;

    int32_t stretch = max_depth + 1;
    Arena scratch = arena_make();
    int32_t stretch_check = check(bottom_up(stretch, &scratch));
    printf("stretch tree of depth %" PRId32 "\t check: %" PRId32 "\n", stretch, stretch_check);
    arena_reset(&scratch);

    Arena long_arena = arena_make();
    Node *long_lived = bottom_up(max_depth, &long_arena);

    int32_t d = min_depth;
    while (d <= max_depth) {
        int32_t iterations = (int32_t)1 << (max_depth - d + min_depth);
        int32_t sum = 0;
        for (int32_t i = 0; i < iterations; i++) {
            sum += check(bottom_up(d, &scratch));
            arena_reset(&scratch);
        }
        printf("%" PRId32 "\t trees of depth %" PRId32 "\t check: %" PRId32 "\n", iterations, d,
               sum);
        d += 2;
    }
    printf("long lived tree of depth %" PRId32 "\t check: %" PRId32 "\n", max_depth,
           check(long_lived));
    return 0;
}
