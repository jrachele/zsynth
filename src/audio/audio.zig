const builtin = @import("builtin");
const std = @import("std");
const clap = @import("clap-bindings");

const Plugin = @import("../plugin.zig");
const Params = @import("../ext/params.zig");
const waves = @import("waves.zig");
const ADSR = @import("adsr.zig");

const Parameter = Params.Parameter;
const Wave = waves.Wave;

pub const Voice = struct {
    noteId: i32,
    channel: i16,
    key: i16,
    velocity: f64,
    adsr: ADSR,
    elapsed_frames: u64,
};

// Processing logic
pub fn processNoteChanges(self: *Plugin, event: *const clap.events.Header) void {
    if (event.space_id != clap.events.core_space_id) {
        return;
    }
    switch (event.type) {
        .note_on, .note_off, .note_choke => {
            // We can cast the pointer as we now know that is the parent type
            const note_event: *const clap.events.Note = @ptrCast(@alignCast(event));

            // A new note was pressed
            if (event.type == .note_on) {
                const adsr = ADSR.init(
                    self.params.get(Parameter.Attack),
                    self.params.get(Parameter.Decay),
                    self.params.get(Parameter.Sustain),
                    self.params.get(Parameter.Release),
                );

                const voice = Voice{
                    .noteId = note_event.note_id,
                    .channel = note_event.channel,
                    .key = note_event.key,
                    .velocity = note_event.velocity,
                    .adsr = adsr,
                    .elapsed_frames = 0,
                };

                self.voices.append(voice) catch {
                    std.log.err("Unable to append voice!", .{});
                    return;
                };
            } else {
                var i: u32 = 0;
                while (i < self.voices.items.len) : (i += 1) {
                    var voice = &self.voices.items[i];
                    if ((voice.channel == note_event.channel or note_event.channel == -1) and
                        (voice.key == note_event.key or note_event.key == -1) and
                        (voice.noteId == note_event.note_id or note_event.note_id == -1))
                    {
                        // Note choke would have the note be immediately removed
                        if (event.type == .note_choke) {
                            _ = self.voices.orderedRemove(i);
                            if (i > 0) {
                                i -= 1;
                            }
                        } else {
                            voice.adsr.onNoteOff();
                        }
                    }
                }
            }
        },
        else => {},
    }
}

fn clamp1(f: f64) f64 {
    if (f < 0) return 0;
    if (f > 1) return 1;
    return f;
}

pub fn renderAudio(self: *Plugin, start: u32, end: u32, output_left: [*]f32, output_right: [*]f32) void {
    const wave_value: u32 = @intFromFloat(self.params.get(Parameter.WaveShape));
    const wave_type: Wave = std.meta.intToEnum(Wave, wave_value) catch Wave.Sine;

    var index = start;
    while (index < end) : (index += 1) {
        var voice_sum: f64 = 0;
        for (self.voices.items) |*voice| {
            var wave: f64 = undefined;
            const t: f64 = @floatFromInt(voice.elapsed_frames);

            // retrieve the wave data from the pre-calculated table
            wave = waves.get(&self.wave_table, wave_type, self.sample_rate.?, voice.key, t);

            // Elapse the voice time by a frame and update envelope
            voice.elapsed_frames += 1;

            voice_sum += wave * voice.adsr.value * voice.velocity;

            const dt = (1 / self.sample_rate.?) * 1000;
            voice.adsr.update(dt);
        }
        const output: f32 = @floatCast(voice_sum);
        output_left[index] = output;
        output_right[index] = output;
    }
}
