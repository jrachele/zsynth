const builtin = @import("builtin");
const std = @import("std");
const zigplotlib = @import("plotlib");

const waves = @import("audio/waves.zig");
const Wave = waves.Wave;

const SVG = zigplotlib.SVG;

const rgb = zigplotlib.rgb;
const Range = zigplotlib.Range;

const Figure = zigplotlib.Figure;
const Line = zigplotlib.Line;
const Scatter = zigplotlib.Scatter;
const ShapeMarker = zigplotlib.ShapeMarker;

const SMOOTHING = 0.2;

// Provide a main function for plotting... scheming...
pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const sample_rate = 48000;

    const key: i16 = 77;
    const frequency: f64 = waves.getFrequency(key);

    const wave_table = waves.generate_wave_table();

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
            sine_y[i] = @floatCast(waves.generate_sine(sample_rate, frequency, t));
            saw_y[i] = @floatCast(waves.generate_saw(sample_rate, frequency, t));
            triangle_y[i] = @floatCast(waves.generate_triangle(sample_rate, frequency, t));
            square_y[i] = @floatCast(waves.generate_square(sample_rate, frequency, t));
        }

        var generated_figure = Figure.init(allocator, .{
            .value_padding = .{
                .x_min = .{ .value = 1.0 },
                .x_max = .{ .value = 1.0 },
            },
            .axis = .{
                .x_range = .{ .min = 0.0, .max = 1.0 },
                .y_range = .{ .min = -1.0, .max = 1.0 },
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
        std.log.debug("Generating all waves...", .{});
        var file = try std.fs.cwd().createFile("waves/All.svg", .{});
        defer file.close();
        try svg.writeTo(file.writer());
    }

    inline for (std.meta.fields(Wave)) |field| {
        const wave_type: Wave = @enumFromInt(field.value);

        comptime var ideal_wave: waves.NaiveWaveFunction = undefined;
        comptime var generated_wave: waves.WaveFunction = undefined;
        switch (wave_type) {
            Wave.Saw => {
                ideal_wave = waves.naive_saw;
                generated_wave = waves.generate_saw;
            },
            Wave.Square => {
                ideal_wave = waves.naive_square;
                generated_wave = waves.generate_square;
            },
            Wave.Triangle => {
                ideal_wave = waves.naive_triangle;
                generated_wave = waves.generate_triangle;
            },
            Wave.Sine => {
                ideal_wave = waves.naive_sine;
                generated_wave = waves.generate_sine;
            },
        }

        var x: [steps]f32 = undefined;
        var ideal_y: [steps]f32 = undefined;
        var generated_y: [steps]f32 = undefined;
        var wave_table_y: [steps]f32 = undefined;
        for (0..steps) |i| {
            const t: f64 = @floatFromInt(i);
            const phase = t * (frequency / sample_rate);
            x[i] = @floatCast(phase);
            ideal_y[i] = @floatCast(ideal_wave(phase));
            generated_y[i] = @floatCast(generated_wave(sample_rate, frequency, phase));
            wave_table_y[i] = @floatCast(waves.get(&wave_table, wave_type, sample_rate, key, t));
        }

        var generated_figure = Figure.init(allocator, .{
            .value_padding = .{
                .x_min = .{ .value = 1.0 },
                .x_max = .{ .value = 1.0 },
            },
            .axis = .{
                .x_range = .{ .min = 0.0, .max = 1.0 },
                .y_range = .{ .min = -1.0, .max = 1.0 },
                .show_y_axis = false,
            },
        });
        defer generated_figure.deinit();

        // try generated_figure.addPlot(Line{ .x = &x, .y = &generated_y, .style = .{
        //     .color = rgb.RED,
        //     .width = 2.0,
        //     .smooth = SMOOTHING,
        // } });
        try generated_figure.addPlot(Scatter{ .x = &x, .y = &wave_table_y, .style = .{
            .color = rgb.RED,
        } });

        try generated_figure.addPlot(Line{ .x = &x, .y = &ideal_y, .style = .{
            .color = rgb.BLACK,
            .width = 1.0,
            .dash = 4.0,
            .smooth = SMOOTHING,
        } });

        var svg = try generated_figure.show();
        defer svg.deinit();

        // Write to an output file
        std.log.debug("Generating {s}.svg", .{field.name});
        var file_name_buf: [128]u8 = undefined;
        const file_name = try std.fmt.bufPrint(&file_name_buf, "waves/{s}.svg", .{field.name});
        var file = try std.fs.cwd().createFile(file_name, .{});
        defer file.close();
        try svg.writeTo(file.writer());
    }
}

test "Multi arrays" {
    var data: [1][2][3]f64 = undefined;

    var layer1 = &data[0];

    var layer2 = &layer1[0];
    layer2[2] = 2312321313;
    std.log.debug("{any}", .{data});
}
