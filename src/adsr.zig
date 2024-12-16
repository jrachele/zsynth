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

// Current envelope value for fast retrieval
value: f64 = 0,

// Elapsed time since the last state change
elapsed: f64 = 0,

// Below this states will transition naturally into the next state
const ms = 1;

pub fn init(attack_time: f64, decay_time: f64, sustain_value: f64, release_time: f64) @This() {
    return .{
        .state = ADSRState.Attack,
        .attack_time = attack_time,
        .decay_time = decay_time,
        .release_time = release_time,
        .sustain_value = sustain_value,
    };
}

pub fn update(self: *@This(), dt: f64) void {
    switch (self.state) {
        ADSRState.Idle => {},
        ADSRState.Attack => {
            // Gradually build to attack_time
            self.value = self.elapsed / self.attack_time;
            if (self.value >= 1 or self.attack_time < ms) {
                // Once we hit the top, begin decaying
                self.value = 1;
                self.state = .Decay;
                self.elapsed = 0;
            }
        },
        ADSRState.Decay => {
            const decay_progress = self.elapsed / self.decay_time;
            self.value = 1.0 + (self.sustain_value - 1.0) * decay_progress;
            if (self.elapsed >= self.decay_time or self.decay_time < ms) {
                self.value = self.sustain_value;
                self.state = .Sustain;
            }
        },
        ADSRState.Sustain => {
            self.value = self.sustain_value;
        },
        ADSRState.Release => {
            const release_progress = self.elapsed / self.release_time;
            self.value = self.sustain_value * (1.0 - release_progress);
            if (self.elapsed >= self.release_time or self.release_time < ms) {
                self.value = 0.0;
                self.state = .Idle;
            }
        },
    }
    self.elapsed += dt;
}

pub fn onNoteOff(self: *@This()) void {
    // if we were mid attack, change the sustain value to match the current value we've accumulated to
    if (self.state == .Attack) {
        self.sustain_value = self.value;
    }
    self.state = .Release;
    self.elapsed = 0;
}

pub fn isEnded(self: *const @This()) bool {
    return self.state == .Idle;
}
