// quicksort: n pseudo-random u32 (xorshift32) sorted by one quicksort written out the same way
// in every language: Hoare partition around the middle element, insertion sort below 16
// elements, the smaller side recursed into. Comparisons, swaps and unpredictable branches.
// Prints whether the result is sorted, its ends and a checksum.
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

static void insertion_sort(uint32_t *a, int64_t lo, int64_t hi) {
    int64_t i = lo + 1;
    while (i <= hi) {
        uint32_t v = a[i];
        int64_t j = i - 1;
        while (j >= lo && a[j] > v) {
            a[j + 1] = a[j];
            j -= 1;
        }
        a[j + 1] = v;
        i += 1;
    }
}

static void quicksort(uint32_t *a, int64_t lo, int64_t hi) {
    while (hi - lo > 16) {
        uint32_t p = a[lo + (hi - lo) / 2];
        int64_t i = lo - 1;
        int64_t j = hi + 1;
        while (1) {
            i += 1;
            while (a[i] < p) i += 1;
            j -= 1;
            while (a[j] > p) j -= 1;
            if (i >= j) break;
            uint32_t t = a[i];
            a[i] = a[j];
            a[j] = t;
        }
        // Recurse into the smaller side, go on with the larger.
        if (j - lo < hi - j) {
            quicksort(a, lo, j);
            lo = j + 1;
        } else {
            quicksort(a, j + 1, hi);
            hi = j;
        }
    }
    insertion_sort(a, lo, hi);
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
    uint32_t *a = malloc(n * sizeof *a);
    if (a == NULL) {
        fputs("out of memory\n", stderr);
        return 1;
    }
    uint32_t x = 2463534242u;
    for (size_t i = 0; i < n; i++) {
        x = x ^ (x << 13);
        x = x ^ (x >> 17);
        x = x ^ (x << 5);
        a[i] = x;
    }
    quicksort(a, 0, (int64_t)n - 1);
    bool sorted = true;
    uint64_t checksum = 0;
    for (size_t i = 0; i < n; i++) {
        if (i > 0 && a[i - 1] > a[i]) sorted = false;
        checksum = checksum + (uint64_t)a[i] * ((uint64_t)i + 1);
    }
    printf("%s %" PRIu32 " %" PRIu32 " %" PRIu64 "\n", sorted ? "true" : "false", a[0], a[n - 1],
           checksum);
    return 0;
}
