const builtin = @import("builtin");
const std = @import("std");

const audio = @import("audio.zig");
const Voice = audio.Voice;

// TODO: Eventually implement wave tables for each sample
const SampleRate = i32;
const supported_sample_rates = [_]SampleRate{ 8000, 11025, 16000, 22050, 44100, 48000, 88200, 96000, 176400, 192000, 352800, 384000 };
inline fn sampleRateSupported(sample_rate: f64) bool {
    for (supported_sample_rates) |rate_i| {
        const rate: f64 = @floatFromInt(rate_i);
        if (rate == sample_rate) return true;
    }

    return false;
}

pub const sample_count = 256;
const waveshape_count = std.meta.fields(Wave).len;

const half_steps_per_table = 4;
const table_count = 128 / half_steps_per_table;
comptime {
    if (@mod(table_count, 1.0) != 0.0) {
        @compileError("half_steps_per_table must be a divisor of 128!");
    }
}
pub const WaveTable = [waveshape_count][table_count][sample_count]f64;

pub inline fn generate_wave_table() WaveTable {
    @setEvalBranchQuota(std.math.maxInt(u32));
    var table: WaveTable = undefined;
    const sample_rate = 48000;

    inline for (std.meta.fields(Wave)) |field| {
        const waveshape_type: Wave = @enumFromInt(field.value);
        const waveshape_index: usize = @intCast(field.value - 1);
        if (!@inComptime()) {
            std.log.debug("Generating data for wave type: {}", .{waveshape_type});
        }
        var table_data = &table[waveshape_index];
        for (0..table_count) |table_index| {
            var sample_data = &table_data[table_index];
            // TODO: Ensure the key at the upper bound of this doesn't produce harmonics that exceed the nyquist
            const key: f64 = @floatFromInt(table_index * half_steps_per_table);
            const frequency = getFrequency(key);
            for (0..sample_count) |sample_index| {
                const phase: f64 = @as(f64, @floatFromInt(sample_index)) / @as(f64, @floatFromInt(sample_count));
                sample_data[sample_index] = generate(waveshape_type, sample_rate, frequency, phase);
            }
        }
    }

    if (!@inComptime()) {
        std.log.debug("Done generating wave table.", .{});
    }
    return table;
}

pub const Wave = enum(u32) {
    Sine = 1,
    Saw = 2,
    Triangle = 3,
    Square = 4,
};

pub inline fn getFrequency(key: f64) f64 {
    return 440.0 * std.math.exp2((key - 57.0) / 12.0);
}

pub inline fn get(wave_table: *const WaveTable, wave_type: Wave, sample_rate: f64, voice: *const Voice, frames: f64) f64 {
    if (!sampleRateSupported(sample_rate)) {
        std.debug.panic("Attempted to use plugin with unsupported sample rate!: {d}", .{sample_rate});
        return -1;
    }

    const key: f64 = @as(f64, @floatFromInt(voice.key)) + voice.expression_values.get(.tuning);

    const table_index: usize = @intFromFloat(key / @as(f64, @floatFromInt(half_steps_per_table)));
    const waveshape_index: usize = @intFromEnum(wave_type) - 1;
    const sample_data = &wave_table[waveshape_index][table_index];

    const frequency = getFrequency(key);

    const phase: f64 = @mod((frequency / sample_rate) * frames, 1.0);

    const period_length: f64 = @floatFromInt(sample_count);
    const index_f: f64 = @mod(period_length * phase, period_length); // Mod it just incase phase was exactly 1.00
    const index_l: usize = @intFromFloat(index_f);
    const index_r: usize = @mod(@as(usize, @intFromFloat(std.math.ceil(index_f))), sample_count);

    // If our index was an integer value to begin with, no need to interpolate
    if (index_l == index_r) {
        return sample_data[index_l];
    }

    // Otherwise linear interpolate between the two closest integer indices to the non-integer index
    const weight: f64 = index_f - std.math.floor(index_f);
    return (sample_data[index_r] * weight) + (sample_data[index_l] * (1.0 - weight));
}

pub inline fn generate(wave_type: Wave, sample_rate: f64, frequency: f64, phase: f64) f64 {
    switch (wave_type) {
        Wave.Sine => {
            return generate_sine(sample_rate, frequency, phase);
        },
        Wave.Saw => {
            return generate_saw(sample_rate, frequency, phase);
        },
        Wave.Triangle => {
            return generate_triangle(sample_rate, frequency, phase);
        },
        Wave.Square => {
            return generate_square(sample_rate, frequency, phase);
        },
    }
}

pub inline fn generate_naive(wave_type: Wave, phase: f64) f64 {
    switch (wave_type) {
        Wave.Sine => {
            return naive_sine(phase);
        },
        Wave.Saw => {
            return naive_saw(phase);
        },
        Wave.Triangle => {
            return naive_triangle(phase);
        },
        Wave.Square => {
            return naive_square(phase);
        },
    }
}

pub inline fn naive_sine(phase: f64) f64 {
    return std.math.sin(phase * 2.0 * std.math.pi);
}

pub inline fn naive_saw(phase: f64) f64 {
    return 2.0 * (phase - std.math.floor(phase + 0.5));
}

pub inline fn naive_square(phase: f64) f64 {
    return if (phase > 0.5) -1 else 1;
}

pub inline fn naive_triangle(phase: f64) f64 {
    return 4 * @abs(@mod(phase - 0.25, 1.0) - 0.5) - 1;
}

pub inline fn generate_sine(_: f64, _: f64, phase: f64) f64 {
    // Sine just uses naive all the time
    return naive_sine(phase);
}

pub inline fn generate_saw(sample_rate: f64, frequency: f64, phase: f64) f64 {
    const nyquist = sample_rate / 2;
    var wave: f64 = 0;
    var n: f64 = 1;
    while (n * frequency < nyquist) : (n += 1) {
        wave += ((std.math.pow(f64, -1, n)) / n) * std.math.sin(phase * n * 2.0 * std.math.pi);
    }
    return wave * (-2.0 / std.math.pi);
}

pub inline fn generate_square(sample_rate: f64, frequency: f64, phase: f64) f64 {
    const nyquist = sample_rate / 2;
    var wave: f64 = 0;
    var n: f64 = 1;
    var k = (2 * n) - 1;
    while (k * frequency < nyquist) : (n += 1) {
        k = (2 * n) - 1;
        wave += (1 / k) * std.math.sin(phase * k * 2.0 * std.math.pi);
    }
    // TODO: Resolve the Gibbs phenomenon issues more gracefully than this
    // return wave * (4.0 / std.math.pi);
    return wave;
}

pub inline fn generate_triangle(sample_rate: f64, frequency: f64, phase: f64) f64 {
    const nyquist = sample_rate / 2;
    var wave: f64 = 0;
    var n: f64 = 1;
    var k = (2 * n) - 1;
    while (k * frequency < nyquist) : (n += 1) {
        k = (2 * n) - 1;
        wave += ((std.math.pow(f64, -1, n)) / (k * k)) * std.math.sin(phase * k * 2.0 * std.math.pi);
    }
    return wave * (-8.0 / (std.math.pi * std.math.pi));
}

pub const NaiveWaveFunction = *const fn (phase: f64) callconv(.@"inline") f64;
pub const WaveFunction = *const fn (sample_rate: f64, frequency: f64, phase: f64) callconv(.@"inline") f64;

fn test_wave_functions(ideal_wave: NaiveWaveFunction, generated_wave: WaveFunction) !void {
    const epsilon: f64 = 0.1; // Within 10% accuracy from the real thing
    const sample_rate: f64 = 48000;

    for (0..87) |i| {
        const key: f64 = @floatFromInt(i);
        const frequency = getFrequency(key);

        const subdivisions = 10;
        // Test at discrete subdivisions
        for (1..subdivisions) |j| {
            const phase: f64 = @as(f64, @floatFromInt(j)) / @as(f64, @floatFromInt(subdivisions));
            // Edge case where the generated wave will be 0 here, because it has to manually cross the axis instead of
            // teleporting across like the ideal
            const ideal = if (phase == 0.5) 0 else ideal_wave(phase);
            const generated = generated_wave(sample_rate, frequency, phase);

            const approx_eq = std.math.approxEqAbs(f64, ideal, generated, epsilon);
            if (!approx_eq) {
                std.log.debug("Not approx eq: {d} {d} {d} at frequency {d} and phase {d}", .{
                    ideal,
                    generated,
                    epsilon,
                    frequency,
                    phase,
                });
            }
            try std.testing.expect(approx_eq);
        }
    }
}

test "Saw function accuracy" {
    try test_wave_functions(naive_saw, generate_saw);
}

test "Square function accuracy" {
    try test_wave_functions(naive_square, generate_square);
}

test "Triangle function accuracy" {
    try test_wave_functions(naive_triangle, generate_triangle);
}
