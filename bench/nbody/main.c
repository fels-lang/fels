// nbody: the Computer Language Benchmarks Game's n-body simulation of the Jovian planets.
// Floating-point arithmetic, `sqrt`, and a small array of structs updated in place.
// Prints the energy before and after `n` steps of 0.01, to 9 decimals.
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

typedef struct { double x, y, z, vx, vy, vz, mass; } Body;

#define PI 3.141592653589793
#define SOLAR_MASS (4.0 * PI * PI)
#define DAYS_PER_YEAR 365.24

static void advance(Body *bodies, size_t len, double dt) {
    for (size_t i = 0; i < len; i++) {
        for (size_t j = i + 1; j < len; j++) {
            double dx = bodies[i].x - bodies[j].x;
            double dy = bodies[i].y - bodies[j].y;
            double dz = bodies[i].z - bodies[j].z;
            double d2 = dx * dx + dy * dy + dz * dz;
            double mag = dt / (d2 * sqrt(d2));
            double mj = bodies[j].mass * mag;
            bodies[i].vx -= dx * mj;
            bodies[i].vy -= dy * mj;
            bodies[i].vz -= dz * mj;
            double mi = bodies[i].mass * mag;
            bodies[j].vx += dx * mi;
            bodies[j].vy += dy * mi;
            bodies[j].vz += dz * mi;
        }
    }
    for (size_t i = 0; i < len; i++) {
        bodies[i].x += dt * bodies[i].vx;
        bodies[i].y += dt * bodies[i].vy;
        bodies[i].z += dt * bodies[i].vz;
    }
}

static double energy(const Body *bodies, size_t len) {
    double e = 0.0;
    for (size_t i = 0; i < len; i++) {
        Body b = bodies[i];
        e += 0.5 * b.mass * (b.vx * b.vx + b.vy * b.vy + b.vz * b.vz);
        for (size_t j = i + 1; j < len; j++) {
            double dx = b.x - bodies[j].x;
            double dy = b.y - bodies[j].y;
            double dz = b.z - bodies[j].z;
            e -= b.mass * bodies[j].mass / sqrt(dx * dx + dy * dy + dz * dz);
        }
    }
    return e;
}

static void offset_momentum(Body *bodies, size_t len) {
    double px = 0.0;
    double py = 0.0;
    double pz = 0.0;
    for (size_t i = 0; i < len; i++) {
        px += bodies[i].vx * bodies[i].mass;
        py += bodies[i].vy * bodies[i].mass;
        pz += bodies[i].vz * bodies[i].mass;
    }
    bodies[0].vx = -px / SOLAR_MASS;
    bodies[0].vy = -py / SOLAR_MASS;
    bodies[0].vz = -pz / SOLAR_MASS;
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
    int64_t n = arg_int(argc, argv, 1000);
    Body bodies[5] = {
        { 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, SOLAR_MASS },
        { 4.84143144246472090e+00, -1.16032004402742839e+00, -1.03622044471123109e-01,
          1.66007664274403694e-03 * DAYS_PER_YEAR, 7.69901118419740425e-03 * DAYS_PER_YEAR,
          -6.90460016972063023e-05 * DAYS_PER_YEAR, 9.54791938424326609e-04 * SOLAR_MASS },
        { 8.34336671824457987e+00, 4.12479856412430479e+00, -4.03523417114321381e-01,
          -2.76742510726862411e-03 * DAYS_PER_YEAR, 4.99852801234917238e-03 * DAYS_PER_YEAR,
          2.30417297573763929e-05 * DAYS_PER_YEAR, 2.85885980666130812e-04 * SOLAR_MASS },
        { 1.28943695621391310e+01, -1.51111514016986312e+01, -2.23307578892655734e-01,
          2.96460137564761618e-03 * DAYS_PER_YEAR, 2.37847173959480950e-03 * DAYS_PER_YEAR,
          -2.96589568540237556e-05 * DAYS_PER_YEAR, 4.36624404335156298e-05 * SOLAR_MASS },
        { 1.53796971148509165e+01, -2.59193146099879641e+01, 1.79258772950371181e-01,
          2.68067772490389322e-03 * DAYS_PER_YEAR, 1.62824170038242295e-03 * DAYS_PER_YEAR,
          -9.51592254519715870e-05 * DAYS_PER_YEAR, 5.15138902046611451e-05 * SOLAR_MASS },
    };
    offset_momentum(bodies, 5);
    printf("%.9f\n", energy(bodies, 5));
    for (int64_t step = 0; step < n; step++) advance(bodies, 5, 0.01);
    printf("%.9f\n", energy(bodies, 5));
    return 0;
}
