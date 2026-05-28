// spectral-norm: the Benchmarks Game's spectral norm of an infinite matrix, by the power method.
// Floating-point division and dot products in nested loops. Prints the norm to 9 decimals.
// The C version of main.fels: the same algorithm, data layout and output.

#include <math.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#ifdef _WIN32
#include <fcntl.h>
#include <io.h>
#endif

static double eval_a(size_t i, size_t j) {
    return 1.0 / (double)((i + j) * (i + j + 1) / 2 + i + 1);
}

// `v` and `out` both have `n` elements.
static void mul_av(const double *v, double *out, size_t n) {
    for (size_t i = 0; i < n; i++) {
        double s = 0.0;
        for (size_t j = 0; j < n; j++) s += eval_a(i, j) * v[j];
        out[i] = s;
    }
}

static void mul_atv(const double *v, double *out, size_t n) {
    for (size_t i = 0; i < n; i++) {
        double s = 0.0;
        for (size_t j = 0; j < n; j++) s += eval_a(j, i) * v[j];
        out[i] = s;
    }
}

static void mul_atav(const double *v, double *out, double *tmp, size_t n) {
    mul_av(v, tmp, n);
    mul_atv(tmp, out, n);
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
    size_t n = (size_t)arg_int(argc, argv, 100);
    double *u = malloc(n * sizeof *u);
    double *v = malloc(n * sizeof *v);
    double *tmp = malloc(n * sizeof *tmp);
    if (u == NULL || v == NULL || tmp == NULL) {
        fputs("out of memory\n", stderr);
        return 1;
    }
    for (size_t i = 0; i < n; i++) u[i] = 1.0;
    for (int k = 0; k < 10; k++) {
        mul_atav(u, v, tmp, n);
        mul_atav(v, u, tmp, n);
    }
    double vbv = 0.0;
    double vv = 0.0;
    for (size_t i = 0; i < n; i++) {
        vbv += u[i] * v[i];
        vv += v[i] * v[i];
    }
    printf("%.9f\n", sqrt(vbv / vv));
    return 0;
}
