// sieve: the primes up to n, by the sieve of Eratosthenes over one byte per number.
// Memory traffic with strided writes, and a branch per number. Prints how many there are.
// The C version of main.fels: the same algorithm, data layout and output.

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
    size_t n = (size_t)arg_int(argc, argv, 1000);
    uint8_t *composite = malloc((n + 1) * sizeof *composite);
    if (composite == NULL) {
        fputs("out of memory\n", stderr);
        return 1;
    }
    for (size_t i = 0; i < n + 1; i++) composite[i] = 0;
    size_t count = 0;
    for (size_t i = 2; i < n + 1; i++) {
        if (composite[i] == 0) {
            count += 1;
            size_t j = i * i;
            while (j <= n) {
                composite[j] = 1;
                j += i;
            }
        }
    }
    printf("%zu\n", count);
    return 0;
}
