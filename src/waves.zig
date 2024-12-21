const std = @import("std");

const Waves = @This();

const SampleRate = i32;
const supported_sample_rates = [_]SampleRate{ 8000, 11025, 16000, 22050, 44100, 48000, 88200, 96000, 176400, 192000, 352800, 384000 };
const new_table_period = 3; // Every minor third

// Wave data consists of a segmented list of data at sets of frequencies one new_table_period apart
const WaveData = std.ArrayList(std.ArrayList(f64));
const WaveTable = std.AutoHashMap(Wave, WaveData);

tables: std.AutoHashMap(SampleRate, WaveTable),
allocator: std.mem.Allocator,

pub const Wave = enum(u32) {
    Sine = 1,
    Saw = 2,
    Triangle = 3,
    Square = 4,
};

pub fn init(allocator: std.mem.Allocator) Waves {
    return Waves{
        .tables = .init(allocator),
        .allocator = allocator,
    };
}

pub fn deinit(self: *Waves) void {
    var it = self.tables.valueIterator();
    while (it.next()) |wave_table| {
        var wave_table_it = wave_table.valueIterator();
        while (wave_table_it.next()) |wave_data| {
            for (wave_data.items) |*sample_data| {
                sample_data.deinit();
            }
            wave_data.deinit();
        }
        wave_table.deinit();
    }
    self.tables.deinit();
}

test "Generating table" {
    const allocator = std.testing.allocator;
    var wave_table = Waves.init(allocator);
    defer wave_table.deinit();

    try wave_table.generate_table(48000);
    _ = wave_table.get(Wave.Sine, 48000, 63, 0.5);
}

// TODO: Somehow get this to work at comptime
pub fn generate_table(self: *Waves, sample_rate: f64) !void {
    std.debug.print("Generating wave tables for sample rate: {d}", .{sample_rate});
    const sample_rate_int: i32 = @intFromFloat(sample_rate);

    // Get the wave table associated with the given sample rate, or create it if necessary
    const wave_table_entry = try self.tables.getOrPut(sample_rate_int);
    var wave_table: *WaveTable = wave_table_entry.value_ptr;
    if (!wave_table_entry.found_existing) {
        wave_table.* = .init(self.allocator);
    }
    inline for (std.meta.fields(Wave)) |field| {
        std.debug.print("Generating wave table for wave type: {s}", .{field.name});
        const wave_type: Wave = @enumFromInt(field.value);
        const wave_data_entry = try wave_table.getOrPut(wave_type);
        var wave_data: *WaveData = wave_data_entry.value_ptr;
        if (wave_data_entry.found_existing) {
            // Clear existing data
            std.debug.print("Previous wave data existed for sample rate: {d}, clearing and regenerating", .{sample_rate});
            for (wave_data.items) |sample_list| {
                sample_list.deinit();
            }
            wave_data.clearAndFree();
        }
        wave_data.* = .init(self.allocator);

        const subtables_len = (128 / new_table_period) - 1;
        const subtables: []std.ArrayList(f64) = try wave_data.addManyAsSlice(subtables_len);
        for (0..subtables_len) |i| {
            const key: i16 = @intCast(i * new_table_period);
            const frequency = getFrequency(key);
            var subtable = &subtables[i];
            subtable.* = .init(self.allocator);

            const num_samples: usize = @intFromFloat(sample_rate / frequency);
            for (0..num_samples) |sample_i| {
                const t: f64 = @floatFromInt(sample_i);
                var wave_value: f64 = 0;
                switch (wave_type) {
                    Wave.Sine => {
                        wave_value = generate_sine(sample_rate, frequency, t);
                    },
                    Wave.Saw => {
                        wave_value = generate_saw(sample_rate, frequency, t);
                    },
                    Wave.Triangle => {
                        wave_value = generate_triangle(sample_rate, frequency, t);
                    },
                    Wave.Square => {
                        wave_value = generate_square(sample_rate, frequency, t);
                    },
                }
                try subtable.append(wave_value);
            }
        }
    }

    std.debug.print("Wave table generation complete", .{});
}

fn getFrequency(key: i16) f64 {
    return 440.0 * std.math.exp2((@as(f64, @floatFromInt(key)) - 57.0) / 12.0);
}

fn sampleRateSupported(sample_rate: f64) bool {
    for (supported_sample_rates) |rate_i| {
        const rate: f64 = @floatFromInt(rate_i);
        if (rate == sample_rate) return true;
    }

    return false;
}

pub fn get(self: *const Waves, wave_type: Wave, sample_rate: f64, key: i16, frames: f64) f64 {
    if (!sampleRateSupported(sample_rate)) {
        std.debug.panic("Attempted to use plugin with unsupported sample rate!: {d}", .{sample_rate});
        return -1;
    }

    const sample_rate_i: i32 = @intFromFloat(sample_rate);
    if (!self.tables.contains(sample_rate_i)) {
        std.debug.panic("Attempted to get wavetable that has not yet been generated!", .{});
        return -1;
    }

    const subtable_index: usize = @intCast(@divFloor(key, new_table_period));
    const wave_table: WaveTable = self.tables.get(sample_rate_i).?;
    const tables = wave_table.get(wave_type).?;
    const subtable: std.ArrayList(f64) = tables.items[subtable_index];

    const frequency = getFrequency(key);
    var phase = (frequency / sample_rate) * frames;
    phase -= std.math.floor(phase);
    var index: usize = @intFromFloat(std.math.round(phase * @as(f64, @floatFromInt(subtable.items.len))));
    if (index == subtable.items.len) {
        index -= 1;
    }

    // This won't work for most frequencies until I add interpolation
    return subtable.items[index];
}
fn generate_sine(sample_rate: f64, frequency: f64, t: f64) f64 {
    const phase = (frequency / sample_rate) * t;
    return std.math.sin(phase * 2.0 * std.math.pi);
}

fn naive_saw(sample_rate: f64, frequency: f64, t: f64) f64 {
    const phase = (frequency / sample_rate) * t;
    return 2.0 * (phase - std.math.floor(phase + 0.5));
}

fn generate_saw(sample_rate: f64, frequency: f64, t: f64) f64 {
    const phase = (frequency / sample_rate) * t;
    const nyquist = sample_rate / 2;
    var wave: f64 = 0;
    var n: f64 = 1;
    while (n * frequency < nyquist) : (n += 1) {
        wave += ((std.math.pow(f64, -1, n)) / n) * std.math.sin(phase * n * 2.0 * std.math.pi);
    }
    return wave * (-2.0 / std.math.pi);
}

fn naive_square(sample_rate: f64, frequency: f64, t: f64) f64 {
    const phase = (frequency / sample_rate) * t;
    return if (phase > 0.5) -1 else 1;
}

fn generate_square(sample_rate: f64, frequency: f64, t: f64) f64 {
    const phase = (frequency / sample_rate) * t;
    const nyquist = sample_rate / 2;
    var wave: f64 = 0;
    var n: f64 = 1;
    var k = (2 * n) - 1;
    while (k * frequency < nyquist) : (n += 1) {
        k = (2 * n) - 1;
        wave += (1 / k) * std.math.sin(phase * k * 2.0 * std.math.pi);
    }
    return wave * (4.0 / std.math.pi);
}

fn abs(x: f64) f64 {
    return if (x < 0) x * -1 else x;
}

fn naive_triangle(sample_rate: f64, frequency: f64, t: f64) f64 {
    const phase = (frequency / sample_rate) * t;
    return 4 * abs(@mod(phase - 0.25, 1.0) - 0.5) - 1;
}

fn generate_triangle(sample_rate: f64, frequency: f64, t: f64) f64 {
    const phase = (frequency / sample_rate) * t;
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

const WaveFunction = *const fn (sample_rate: f64, frequency: f64, t: f64) f64;

fn test_wave_functions(ideal_wave: WaveFunction, generated_wave: WaveFunction) !void {
    const epsilon: f64 = 0.1; // Within 10% accuracy from the real thing
    const sample_rate: f64 = 48000;

    for (0..87) |i| {
        const key: i16 = @intCast(i);
        const frequency = getFrequency(key);

        const subdivisions = 10;
        // Test at discrete subdivisions
        for (1..subdivisions) |j| {
            const phase: f64 = @as(f64, @floatFromInt(j)) / @as(f64, @floatFromInt(subdivisions));
            const t = (phase * sample_rate) / frequency;
            // Edge case where the generated wave will be 0 here, because it has to manually cross the axis instead of
            // teleporting across like the ideal
            const ideal = if (phase == 0.5) 0 else ideal_wave(sample_rate, frequency, t);
            const generated = generated_wave(sample_rate, frequency, t);

            const approx_eq = std.math.approxEqAbs(f64, ideal, generated, epsilon);
            if (!approx_eq) {
                std.debug.print("Not approx eq: {d} {d} {d} at frequency {d} and phase {d}", .{
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

// Provide a main function for plotting... scheming...
const zigplotlib = @import("plotlib");
const SVG = zigplotlib.SVG;

const rgb = zigplotlib.rgb;
const Range = zigplotlib.Range;

const Figure = zigplotlib.Figure;
const Line = zigplotlib.Line;
const ShapeMarker = zigplotlib.ShapeMarker;

const SMOOTHING = 0.2;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const frequency: f64 = 440;
    const sample_rate: f64 = 48000;
    const steps: usize = @intFromFloat(sample_rate / frequency);

    {
        var x: [steps]f32 = undefined;
        var sine_y: [steps]f32 = undefined;
        var saw_y: [steps]f32 = undefined;
        var triangle_y: [steps]f32 = undefined;
        var square_y: [steps]f32 = undefined;
        for (0..steps) |i| {
            const t: f64 = @floatFromInt(i);
            x[i] = @floatCast(t * (frequency / sample_rate));
            sine_y[i] = @floatCast(generate_sine(sample_rate, frequency, t));
            saw_y[i] = @floatCast(generate_saw(sample_rate, frequency, t));
            triangle_y[i] = @floatCast(generate_triangle(sample_rate, frequency, t));
            square_y[i] = @floatCast(generate_square(sample_rate, frequency, t));
        }

        var generated_figure = Figure.init(allocator, .{
            .value_padding = .{
                .x_min = .{ .value = 1.0 },
                .x_max = .{ .value = 1.0 },
            },
            .axis = .{
                .x_range = .{ .min = 0.0, .max = 1.0 },
                .show_y_axis = false,
            },
        });
        defer generated_figure.deinit();

        try generated_figure.addPlot(Line{ .x = &x, .y = &sine_y, .style = .{
            .color = rgb.BLUE,
            .width = 2.0,
            .smooth = SMOOTHING,
        } });
        try generated_figure.addPlot(Line{ .x = &x, .y = &saw_y, .style = .{
            .color = rgb.GREEN,
            .width = 2.0,
            .smooth = SMOOTHING,
        } });
        try generated_figure.addPlot(Line{ .x = &x, .y = &triangle_y, .style = .{
            .color = rgb.RED,
            .width = 2.0,
            .smooth = SMOOTHING,
        } });
        try generated_figure.addPlot(Line{ .x = &x, .y = &square_y, .style = .{
            .color = rgb.ORANGE,
            .width = 2.0,
            .smooth = SMOOTHING,
        } });

        var svg = try generated_figure.show();
        defer svg.deinit();

        // Write to an output file (out.svg)
        std.debug.print("Generating all waves", .{});
        var file = try std.fs.cwd().createFile("waves/All.svg", .{});
        defer file.close();
        try svg.writeTo(file.writer());
    }

    inline for (std.meta.fields(Wave)) |field| {
        const wave_type: Wave = @enumFromInt(field.value);

        var ideal_wave: WaveFunction = undefined;
        var generated_wave: WaveFunction = undefined;
        switch (wave_type) {
            Wave.Saw => {
                ideal_wave = naive_saw;
                generated_wave = generate_saw;
            },
            Wave.Square => {
                ideal_wave = naive_square;
                generated_wave = generate_square;
            },
            Wave.Triangle => {
                ideal_wave = naive_triangle;
                generated_wave = generate_triangle;
            },
            Wave.Sine => {
                ideal_wave = generate_sine;
                generated_wave = generate_sine;
            },
        }

        var x: [steps]f32 = undefined;
        var ideal_y: [steps]f32 = undefined;
        var generated_y: [steps]f32 = undefined;
        for (0..steps) |i| {
            const t: f64 = @floatFromInt(i);
            x[i] = @floatCast(t * (frequency / sample_rate));
            ideal_y[i] = @floatCast(ideal_wave(sample_rate, frequency, t));
            generated_y[i] = @floatCast(generated_wave(sample_rate, frequency, t));
        }

        var generated_figure = Figure.init(allocator, .{
            .value_padding = .{
                .x_min = .{ .value = 1.0 },
                .x_max = .{ .value = 1.0 },
            },
            .axis = .{
                .x_range = .{ .min = 0.0, .max = 1.0 },
                .show_y_axis = false,
            },
        });
        defer generated_figure.deinit();

        try generated_figure.addPlot(Line{ .x = &x, .y = &generated_y, .style = .{
            .color = rgb.RED,
            .width = 2.0,
            .smooth = SMOOTHING,
        } });

        try generated_figure.addPlot(Line{ .x = &x, .y = &ideal_y, .style = .{
            .color = rgb.BLACK,
            .width = 1.0,
            .dash = 4.0,
            .smooth = SMOOTHING,
        } });

        var svg = try generated_figure.show();
        defer svg.deinit();

        // Write to an output file (out.svg)
        std.debug.print("Generating {s}.svg", .{field.name});
        var file_name_buf: [128]u8 = undefined;
        const file_name = try std.fmt.bufPrint(&file_name_buf, "waves/{s}.svg", .{field.name});
        var file = try std.fs.cwd().createFile(file_name, .{});
        defer file.close();
        try svg.writeTo(file.writer());
    }
}
