// matmul: an n x n matrix product of doubles, the naive i-k-j loop order.
// Floating-point multiply-add over rows, the loop compilers vectorize. The entries are small
// integers, so the sum it prints is exact in every language.
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
    size_t n = (size_t)arg_int(argc, argv, 100);
    double *x = malloc(n * n * sizeof *x);
    double *y = malloc(n * n * sizeof *y);
    double *z = malloc(n * n * sizeof *z);
    if (x == NULL || y == NULL || z == NULL) {
        fputs("out of memory\n", stderr);
        return 1;
    }
    for (size_t i = 0; i < n; i++) {
        for (size_t j = 0; j < n; j++) {
            x[i * n + j] = (double)((i + j) % 3);
            y[i * n + j] = (double)((i * j) % 5);
            z[i * n + j] = 0.0;
        }
    }
    for (size_t i = 0; i < n; i++) {
        for (size_t k = 0; k < n; k++) {
            double xik = x[i * n + k];
            for (size_t j = 0; j < n; j++) z[i * n + j] += xik * y[k * n + j];
        }
    }
    double sum = 0.0;
    for (size_t i = 0; i < n * n; i++) sum += z[i];
    printf("%" PRId64 "\n", (int64_t)sum);
    return 0;
}
