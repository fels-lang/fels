// fannkuch-redux: the Benchmarks Game's pancake flips over every permutation of 1..n.
// Small integer arrays, copies and reversals, and a permutation generator. Prints the checksum
// and the most flips.
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

// The first argument as a number, or `fallback`.
static int64_t arg_int(int argc, char **argv, int64_t fallback) {
    if (argc < 2) return fallback;
    return strtoll(argv[1], NULL, 10);
}

int main(int argc, char **argv) {
#ifdef _WIN32
    _setmode(_fileno(stdout), _O_BINARY); // "\n" stays LF, as the Fels and Zig versions print it
#endif
    size_t n = (size_t)arg_int(argc, argv, 7);
    int32_t *perm = malloc(n * sizeof *perm);
    int32_t *perm1 = malloc(n * sizeof *perm1);
    int32_t *count = malloc(n * sizeof *count);
    if (perm == NULL || perm1 == NULL || count == NULL) {
        fputs("out of memory\n", stderr);
        return 1;
    }
    for (size_t i = 0; i < n; i++) perm1[i] = (int32_t)i;

    int32_t max_flips = 0;
    int32_t checksum = 0;
    int32_t perm_count = 0;
    size_t r = n;
    while (1) {
        while (r != 1) {
            count[r - 1] = (int32_t)r;
            r -= 1;
        }
        for (size_t i = 0; i < n; i++) perm[i] = perm1[i];
        int32_t flips = 0;
        size_t k = (size_t)perm[0];
        while (k != 0) {
            size_t lo = 0;
            size_t hi = k;
            while (lo < hi) {
                int32_t t = perm[lo];
                perm[lo] = perm[hi];
                perm[hi] = t;
                lo += 1;
                hi -= 1;
            }
            flips += 1;
            k = (size_t)perm[0];
        }
        if (flips > max_flips) max_flips = flips;
        if (perm_count % 2 == 0) checksum += flips; else checksum -= flips;

        // The next permutation.
        while (1) {
            if (r == n) {
                printf("%" PRId32 "\nPfannkuchen(%zu) = %" PRId32 "\n", checksum, n, max_flips);
                return 0;
            }
            int32_t perm0 = perm1[0];
            for (size_t i = 0; i < r; i++) perm1[i] = perm1[i + 1];
            perm1[r] = perm0;
            count[r] -= 1;
            if (count[r] > 0) break;
            r += 1;
        }
        perm_count += 1;
    }
    return 0;
}
