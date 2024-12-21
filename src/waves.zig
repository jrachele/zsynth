const std = @import("std");

const Waves = @This();
sample_rate: f64 = 48000,

pub fn saw(self: *const Waves, frequency: f64, t: f64) f64 {
    const nyquist = self.sample_rate / 2;
    var wave: f64 = 0;
    var n: f64 = 1;
    const phase = (frequency / self.sample_rate) * t;
    while (n * frequency < nyquist) : (n += 1) {
        wave += ((std.math.pow(f64, -1, n)) / n) * std.math.sin(phase * n * 2.0 * std.math.pi);
    }
    return wave * (-2.0 / std.math.pi);
}

pub fn square(self: *const Waves, frequency: f64, t: f64) f64 {
    const nyquist = self.sample_rate / 2;
    var wave: f64 = 0;
    var n: f64 = 1;
    const phase = (frequency / self.sample_rate) * t;
    var k = (2 * n) - 1;
    while (k * frequency < nyquist) : (n += 1) {
        k = (2 * n) - 1;
        wave += (1 / k) * std.math.sin(phase * k * 2.0 * std.math.pi);
    }
    return wave * (4.0 / std.math.pi);
}

pub fn triangle(self: *const Waves, frequency: f64, t: f64) f64 {
    const nyquist = self.sample_rate / 2;
    var wave: f64 = 0;
    var n: f64 = 1;
    const phase = (frequency / self.sample_rate) * t;
    var k = (2 * n) - 1;
    while (k * frequency < nyquist) : (n += 1) {
        k = (2 * n) - 1;
        wave += ((std.math.pow(f64, -1, n)) / (k * k)) * std.math.sin(phase * k * 2.0 * std.math.pi);
    }
    return wave * (-8.0 / (std.math.pi * std.math.pi));
}
