// nbody: the Computer Language Benchmarks Game's n-body simulation of the Jovian planets.
// Floating-point arithmetic, `sqrt`, and a small array of structs updated in place.
// Prints the energy before and after `n` steps of 0.01, to 9 decimals.
// The Zig version of main.fels: the same algorithm, data layout and output.

const std = @import("std");

const Body = struct { x: f64, y: f64, z: f64, vx: f64, vy: f64, vz: f64, mass: f64 };

const PI: f64 = 3.141592653589793;
const SOLAR_MASS: f64 = 4.0 * PI * PI;
const DAYS_PER_YEAR: f64 = 365.24;

fn advance(bodies: []Body, dt: f64) void {
    for (0..bodies.len) |i| {
        for (i + 1..bodies.len) |j| {
            const dx = bodies[i].x - bodies[j].x;
            const dy = bodies[i].y - bodies[j].y;
            const dz = bodies[i].z - bodies[j].z;
            const d2 = dx * dx + dy * dy + dz * dz;
            const mag = dt / (d2 * @sqrt(d2));
            const mj = bodies[j].mass * mag;
            bodies[i].vx -= dx * mj;
            bodies[i].vy -= dy * mj;
            bodies[i].vz -= dz * mj;
            const mi = bodies[i].mass * mag;
            bodies[j].vx += dx * mi;
            bodies[j].vy += dy * mi;
            bodies[j].vz += dz * mi;
        }
    }
    for (0..bodies.len) |i| {
        bodies[i].x += dt * bodies[i].vx;
        bodies[i].y += dt * bodies[i].vy;
        bodies[i].z += dt * bodies[i].vz;
    }
}

fn energy(bodies: []Body) f64 {
    var e: f64 = 0.0;
    for (0..bodies.len) |i| {
        const b = bodies[i];
        e += 0.5 * b.mass * (b.vx * b.vx + b.vy * b.vy + b.vz * b.vz);
        for (i + 1..bodies.len) |j| {
            const dx = b.x - bodies[j].x;
            const dy = b.y - bodies[j].y;
            const dz = b.z - bodies[j].z;
            e -= b.mass * bodies[j].mass / @sqrt(dx * dx + dy * dy + dz * dz);
        }
    }
    return e;
}

fn offsetMomentum(bodies: []Body) void {
    var px: f64 = 0.0;
    var py: f64 = 0.0;
    var pz: f64 = 0.0;
    for (0..bodies.len) |i| {
        px += bodies[i].vx * bodies[i].mass;
        py += bodies[i].vy * bodies[i].mass;
        pz += bodies[i].vz * bodies[i].mass;
    }
    bodies[0].vx = -px / SOLAR_MASS;
    bodies[0].vy = -py / SOLAR_MASS;
    bodies[0].vz = -pz / SOLAR_MASS;
}

/// The first argument as a number, or `fallback`.
fn argInt(init: std.process.Init, fallback: i64) !i64 {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len < 2) return fallback;
    return std.fmt.parseInt(i64, args[1], 10);
}

pub fn main(init: std.process.Init) !void {
    const n = try argInt(init, 1000);
    var stdout_buffer: [256]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writerStreaming(init.io, &stdout_buffer);
    const out = &stdout_writer.interface;

    var bodies = [5]Body{
        .{ .x = 0.0, .y = 0.0, .z = 0.0, .vx = 0.0, .vy = 0.0, .vz = 0.0, .mass = SOLAR_MASS },
        .{
            .x = 4.84143144246472090e+00,
            .y = -1.16032004402742839e+00,
            .z = -1.03622044471123109e-01,
            .vx = 1.66007664274403694e-03 * DAYS_PER_YEAR,
            .vy = 7.69901118419740425e-03 * DAYS_PER_YEAR,
            .vz = -6.90460016972063023e-05 * DAYS_PER_YEAR,
            .mass = 9.54791938424326609e-04 * SOLAR_MASS,
        },
        .{
            .x = 8.34336671824457987e+00,
            .y = 4.12479856412430479e+00,
            .z = -4.03523417114321381e-01,
            .vx = -2.76742510726862411e-03 * DAYS_PER_YEAR,
            .vy = 4.99852801234917238e-03 * DAYS_PER_YEAR,
            .vz = 2.30417297573763929e-05 * DAYS_PER_YEAR,
            .mass = 2.85885980666130812e-04 * SOLAR_MASS,
        },
        .{
            .x = 1.28943695621391310e+01,
            .y = -1.51111514016986312e+01,
            .z = -2.23307578892655734e-01,
            .vx = 2.96460137564761618e-03 * DAYS_PER_YEAR,
            .vy = 2.37847173959480950e-03 * DAYS_PER_YEAR,
            .vz = -2.96589568540237556e-05 * DAYS_PER_YEAR,
            .mass = 4.36624404335156298e-05 * SOLAR_MASS,
        },
        .{
            .x = 1.53796971148509165e+01,
            .y = -2.59193146099879641e+01,
            .z = 1.79258772950371181e-01,
            .vx = 2.68067772490389322e-03 * DAYS_PER_YEAR,
            .vy = 1.62824170038242295e-03 * DAYS_PER_YEAR,
            .vz = -9.51592254519715870e-05 * DAYS_PER_YEAR,
            .mass = 5.15138902046611451e-05 * SOLAR_MASS,
        },
    };
    const s: []Body = bodies[0..5];
    offsetMomentum(s);
    try out.print("{d:.9}\n", .{energy(s)});
    var step: i64 = 0;
    while (step < n) : (step += 1) advance(s, 0.01);
    try out.print("{d:.9}\n", .{energy(s)});
    try out.flush();
}
