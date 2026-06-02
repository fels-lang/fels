// crc32: the IEEE CRC-32 (the table-driven, byte-at-a-time loop zlib's reference uses) of a
// 16 MiB buffer of xorshift32 bytes, `n` times over. Byte loads, table lookups and shifts in
// a dependency chain. Prints the CRC.
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

#define SIZE 16777216

// The first argument as a number, or `fallback`.
static int64_t arg_int(int argc, char **argv, int64_t fallback) {
    if (argc < 2) return fallback;
    return strtoll(argv[1], NULL, 10);
}

int main(int argc, char **argv) {
#ifdef _WIN32
    _setmode(_fileno(stdout), _O_BINARY); // "\n" stays LF, as the Fels and Zig versions print it
#endif
    int64_t passes = arg_int(argc, argv, 1);
    uint32_t *table = malloc(256 * sizeof *table);
    uint8_t *buf = malloc(SIZE * sizeof *buf);
    if (table == NULL || buf == NULL) {
        fputs("out of memory\n", stderr);
        return 1;
    }
    for (size_t i = 0; i < 256; i++) {
        uint32_t c = (uint32_t)i;
        for (int k = 0; k < 8; k++) {
            if ((c & 1) != 0) c = 0xEDB88320u ^ (c >> 1); else c = c >> 1;
        }
        table[i] = c;
    }
    uint32_t x = 2463534242u;
    for (size_t i = 0; i < SIZE; i++) {
        x = x ^ (x << 13);
        x = x ^ (x >> 17);
        x = x ^ (x << 5);
        buf[i] = (uint8_t)(x & 255);
    }
    uint32_t crc = 0xFFFFFFFFu;
    for (int64_t p = 0; p < passes; p++) {
        for (size_t i = 0; i < SIZE; i++) {
            uint8_t b = buf[i];
            crc = table[(crc ^ (uint32_t)b) & 255] ^ (crc >> 8);
        }
    }
    printf("%" PRIu32 "\n", crc ^ 0xFFFFFFFFu);
    return 0;
}
