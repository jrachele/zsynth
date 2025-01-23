const ADSR = @This();

const std = @import("std");
const tracy = @import("tracy");

const ADSRState = enum {
    Idle,
    Attack,
    Decay,
    Sustain,
    Release,
};

// State of the ADSR envelope
state: ADSRState,
attack_time: f64 = 0,
decay_time: f64 = 0,
release_time: f64 = 0,
sustain_value: f64 = 0,
original_sustain_value: f64 = 0,

// Current envelope value for fast retrieval
value: f64 = 0,

// Elapsed time since the last state change
elapsed: f64 = 0,

// Below this states will transition naturally into the next state
const ms = 1;

pub fn init(attack_time: f64, decay_time: f64, sustain_value: f64, release_time: f64) ADSR {
    return .{
        .state = ADSRState.Attack,
        .attack_time = attack_time,
        .decay_time = decay_time,
        .release_time = release_time,
        .sustain_value = sustain_value,
        .original_sustain_value = sustain_value,
    };
}

// Linear attack
fn attack(t: f64, duration: f64) f64 {
    return t / duration;
}

fn decay(t: f64, duration: f64, sustain: f64) f64 {
    return 1.0 + (sustain - 1.0) * (t / duration);
}

fn release(t: f64, duration: f64, sustain: f64) f64 {
    return sustain * (1.0 - (t / duration));
}

pub fn update(self: *ADSR, dt: f64) void {
    const zone = tracy.ZoneN(@src(), "ADSR update");
    defer zone.End();

    self.elapsed += dt;
    switch (self.state) {
        ADSRState.Idle => {},
        ADSRState.Attack => {
            // Gradually build to attack_time
            self.value = attack(self.elapsed, self.attack_time);
            if (self.value >= 1 or self.attack_time < ms) {
                // Once we hit the top, begin decaying
                self.value = 1;
                self.state = .Decay;
                self.elapsed = 0;
            }
        },
        ADSRState.Decay => {
            self.value = decay(self.elapsed, self.decay_time, self.sustain_value);
            if (self.elapsed >= self.decay_time or self.decay_time < ms) {
                self.value = self.sustain_value;
                self.state = .Sustain;
            }
        },
        ADSRState.Sustain => {
            self.value = self.sustain_value;
        },
        ADSRState.Release => {
            self.value = release(self.elapsed, self.release_time, self.sustain_value);
            if (self.elapsed >= self.release_time or self.release_time < ms) {
                self.value = 0.0;
                self.elapsed = 0.0;
                self.state = .Idle;
            }
        },
    }
}

pub fn onNoteOff(self: *ADSR) void {
    // change the sustain value to match the current value we've accumulated to
    self.sustain_value = self.value;
    self.state = .Release;
    self.elapsed = 0;
}

pub fn isEnded(self: *const ADSR) bool {
    return self.state == .Idle;
}

pub fn reset(self: *ADSR) void {
    // To prevent clipping when reset, set the elapsed time to begin the attack where the release left off
    if (self.state == .Release and self.release_time > 0) {
        // elapsed / attack_time = value
        self.elapsed = self.value * self.attack_time;
    } else if (self.state != .Attack) {
        self.elapsed = 0;
    }

    // Reset the sustain value to what the envelope was set to originally
    self.sustain_value = self.original_sustain_value;

    // Begin at attack
    self.state = ADSRState.Attack;
}

const TestADSR = struct {
    pub fn create() ADSR {
        const attack_time = 300.0;
        const decay_time = 500.0;
        const sustain_value = 0.69;
        const release_time = 3000.0;
        return ADSR.init(attack_time, decay_time, sustain_value, release_time);
    }
};

test "ADSR test state machines and accuracy with full duration" {
    var adsr = TestADSR.create();
    const dt = 1.0;

    const attack_time: usize = @intFromFloat(adsr.attack_time);
    for (0..attack_time) |i| {
        const elapsed = @as(f64, @floatFromInt(i));
        try std.testing.expectEqual(elapsed, adsr.elapsed);

        const value = elapsed / adsr.attack_time;
        try std.testing.expectEqual(value, adsr.value);

        adsr.update(dt);
    }

    // Attack -> Decay
    try std.testing.expectEqual(adsr.state, .Decay);

    const decay_time: usize = @intFromFloat(adsr.decay_time);
    for (0..decay_time) |i| {
        const elapsed = @as(f64, @floatFromInt(i));
        try std.testing.expectEqual(elapsed, adsr.elapsed);

        const value = decay(elapsed, adsr.decay_time, adsr.sustain_value);
        try std.testing.expectEqual(value, adsr.value);
        adsr.update(dt);
    }

    // Decay -> Sustain
    try std.testing.expectEqual(adsr.state, .Sustain);

    // Ensure that the value sustains indefinitely
    for (0..10) |_| {
        try std.testing.expectEqual(adsr.value, adsr.sustain_value);
        adsr.update(dt);
    }

    adsr.onNoteOff();

    // Sustain -> Release
    try std.testing.expectEqual(adsr.state, .Release);

    const release_time: usize = @intFromFloat(adsr.release_time);
    for (0..release_time) |i| {
        const elapsed = @as(f64, @floatFromInt(i));
        try std.testing.expectEqual(elapsed, adsr.elapsed);

        const value = release(elapsed, adsr.release_time, adsr.sustain_value);
        if (value != adsr.value) {
            std.log.err("Release value not equal at {d}", .{i});
        }
        try std.testing.expectEqual(value, adsr.value);

        adsr.update(dt);
    }

    // Release -> Idle
    try std.testing.expect(adsr.isEnded());
    try std.testing.expectEqual(adsr.value, 0);
    try std.testing.expectEqual(adsr.elapsed, 0);
}

test "ADSR attack ended early" {
    var adsr = TestADSR.create();
    const dt = 1.0;

    const attack_time: usize = @intFromFloat(adsr.attack_time);
    for (0..attack_time / 2) |i| {
        const elapsed = @as(f64, @floatFromInt(i));
        try std.testing.expectEqual(elapsed, adsr.elapsed);

        const value = elapsed / adsr.attack_time;
        try std.testing.expectEqual(value, adsr.value);

        adsr.update(dt);
    }

    adsr.onNoteOff();

    // Ensure the last value of the attack is where the release starts from
    try std.testing.expectEqual(adsr.sustain_value, adsr.value);
    try std.testing.expect(adsr.original_sustain_value != adsr.value);

    // Attack -> Release
    try std.testing.expectEqual(adsr.state, .Release);

    const release_time: usize = @intFromFloat(adsr.release_time);
    for (0..release_time) |i| {
        const elapsed = @as(f64, @floatFromInt(i));
        try std.testing.expectEqual(elapsed, adsr.elapsed);

        const value = release(elapsed, adsr.release_time, adsr.sustain_value);
        if (value != adsr.value) {
            std.log.err("Release value not equal at {d}", .{i});
        }
        try std.testing.expectEqual(value, adsr.value);

        adsr.update(dt);
    }

    // Release -> Idle
    try std.testing.expect(adsr.isEnded());
    try std.testing.expectEqual(adsr.value, 0);
    try std.testing.expectEqual(adsr.elapsed, 0);
}

test "ADSR decay ended early" {
    var adsr = TestADSR.create();
    const dt = 1.0;

    const attack_time: usize = @intFromFloat(adsr.attack_time);
    for (0..attack_time) |i| {
        const elapsed = @as(f64, @floatFromInt(i));
        try std.testing.expectEqual(elapsed, adsr.elapsed);

        const value = elapsed / adsr.attack_time;
        try std.testing.expectEqual(value, adsr.value);

        adsr.update(dt);
    }

    // Attack -> Decay
    try std.testing.expectEqual(adsr.state, .Decay);

    const decay_time: usize = @intFromFloat(adsr.decay_time);
    for (0..decay_time / 2) |i| {
        const elapsed = @as(f64, @floatFromInt(i));
        try std.testing.expectEqual(elapsed, adsr.elapsed);

        const value = decay(elapsed, adsr.decay_time, adsr.sustain_value);
        try std.testing.expectEqual(value, adsr.value);
        adsr.update(dt);
    }

    adsr.onNoteOff();

    // Ensure the last value of the decay is where the release starts from
    try std.testing.expectEqual(adsr.sustain_value, adsr.value);
    try std.testing.expect(adsr.original_sustain_value != adsr.value);

    // Decay -> Release
    try std.testing.expectEqual(adsr.state, .Release);

    const release_time: usize = @intFromFloat(adsr.release_time);
    for (0..release_time) |i| {
        const elapsed = @as(f64, @floatFromInt(i));
        try std.testing.expectEqual(elapsed, adsr.elapsed);

        const value = release(elapsed, adsr.release_time, adsr.sustain_value);
        if (value != adsr.value) {
            std.log.err("Release value not equal at {d}", .{i});
        }
        try std.testing.expectEqual(value, adsr.value);

        adsr.update(dt);
    }

    // Release -> Idle
    try std.testing.expect(adsr.isEnded());
    try std.testing.expectEqual(adsr.value, 0);
    try std.testing.expectEqual(adsr.elapsed, 0);
}
