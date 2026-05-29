// mandelbrot: the Benchmarks Game's Mandelbrot set, an n x n bitmap of 50 iterations each.
// A tight floating-point loop, and bits packed into bytes. Instead of the bitmap it prints a
// checksum of its bytes.
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
    size_t n = (size_t)arg_int(argc, argv, 200);
    double w = (double)n;
    uint32_t checksum = 0;
    for (size_t y = 0; y < n; y++) {
        double ci = 2.0 * (double)y / w - 1.0;
        uint32_t byte = 0;
        uint32_t bits = 0;
        for (size_t x = 0; x < n; x++) {
            double cr = 2.0 * (double)x / w - 1.5;
            double zr = 0.0;
            double zi = 0.0;
            double tr = 0.0;
            double ti = 0.0;
            int32_t i = 0;
            while (i < 50 && tr + ti <= 4.0) {
                zi = 2.0 * zr * zi + ci;
                zr = tr - ti + cr;
                tr = zr * zr;
                ti = zi * zi;
                i += 1;
            }
            byte = byte << 1;
            if (tr + ti <= 4.0) byte = byte | 1;
            bits += 1;
            if (bits == 8) {
                checksum = checksum * 31 + byte;
                byte = 0;
                bits = 0;
            } else if (x == n - 1) {
                byte = (byte << (8 - (uint32_t)(n % 8))) & 255;
                checksum = checksum * 31 + byte;
                byte = 0;
                bits = 0;
            }
        }
    }
    printf("%zu %" PRIu32 "\n", n, checksum);
    return 0;
}
