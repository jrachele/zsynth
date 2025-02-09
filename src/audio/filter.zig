const Filter = @This();

// Biquad filter
// http://shepazu.github.io/Audio-EQ-Cookbook/audio-eq-cookbook.html
const std = @import("std");
pub const FilterType = enum {
    LowPass,
    HighPass,
    BandPass,
};

// Difference equation:
// y[n] = (b0 / a0) * x[n] + (b1 / a0) * x[n-1] + (b2 / a0) * x[n-2] - (a1 / a0) * y[n - 1] - (a2 / a0) * y[n - 2]
// A = 10 (dbGain / 40)
// w0 =2*pi* (freq / sample_rate)
// alpha = sin(w0) / 2Q

a0: f32,
a1: f32,
a2: f32,
b0: f32,
b1: f32,
b2: f32,
f0: f32,
sample_rate: f32,
q: f32,
ysub1: f32 = 0,
ysub2: f32 = 0,
xsub1: f32 = 0,
xsub2: f32 = 0,
_filter_type: FilterType,

pub fn init(filter_type: FilterType, f0: f32, sample_rate: f32, q: f32) !Filter {
    var filter: Filter = undefined;
    try filter.update(filter_type, f0, sample_rate, q);
    return filter;
}

pub fn update(filter: *Filter, filter_type: FilterType, f0: f32, sample_rate: f32, q: f32) !void {
    if (sample_rate == 0) {
        return error.ZeroSampleRate;
    }
    if (q == 0) {
        return error.ZeroQ;
    }

    filter._filter_type = filter_type;
    filter.f0 = f0;
    filter.sample_rate = sample_rate;
    filter.q = q;
    try filter.calculateCoefficients();
}

// Runs the filter on the given input, returning the output, and updating the previous values internally
pub fn step(filter: *Filter, x: f32) f32 {
    // y[n] = (b0 / a0) * x[n] + (b1 / a0) * x[n-1] + (b2 / a0) * x[n-2] - (a1 / a0) * y[n - 1] - (a2 / a0) * y[n - 2]
    const output = ((filter.b0 / filter.a0) * x) + ((filter.b1 / filter.a0) * filter.xsub1) + ((filter.b2 / filter.a0) * filter.xsub2) - ((filter.a1 / filter.a0) * filter.ysub1) - ((filter.a2 / filter.a0) * filter.ysub2);
    filter.ysub2 = filter.ysub1;
    filter.ysub1 = output;
    filter.xsub2 = filter.xsub1;
    filter.xsub1 = x;
    return output;
}

fn calculateCoefficients(filter: *Filter) !void {
    if (filter.sample_rate == 0) {
        return error.ZeroSampleRate;
    }
    if (filter.q == 0) {
        return error.ZeroQ;
    }

    const w0 = 2 * std.math.pi * (filter.f0 / filter.sample_rate);
    const alpha = std.math.sin(w0) / (2 * filter.q);
    switch (filter._filter_type) {
        .LowPass => {
            filter.a0 = 1 + alpha;
            filter.a1 = -2 * std.math.cos(w0);
            filter.a2 = 1 - alpha;
            filter.b0 = (1 - std.math.cos(w0)) / 2;
            filter.b1 = 1 - std.math.cos(w0);
            filter.b2 = filter.b0;
        },
        .HighPass => {
            filter.a0 = 1 + alpha;
            filter.a1 = -2 * std.math.cos(w0);
            filter.a2 = 1 - alpha;
            filter.b0 = (1 + std.math.cos(w0)) / 2;
            filter.b1 = -1 - std.math.cos(w0);
            filter.b2 = filter.b0;
        },
        .BandPass => {
            filter.a0 = 1 + alpha;
            filter.a1 = -2 * std.math.cos(w0);
            filter.a2 = 1 - alpha;
            filter.b0 = filter.q * alpha;
            filter.b1 = 0;
            filter.b2 = -filter.q * alpha;
        },
    }
}
