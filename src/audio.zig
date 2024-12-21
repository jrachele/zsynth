const std = @import("std");
const clap = @import("clap-bindings");

const Plugin = @import("plugin.zig");
const Params = @import("params.zig");

const ADSR = @import("adsr.zig");

const Parameter = Params.Parameter;
const Wave = Params.Wave;

pub const Voice = struct {
    noteId: i32,
    channel: i16,
    key: i16,
    adsr: ADSR,
    elapsed_frames: f64,
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
                    .adsr = adsr,
                    .elapsed_frames = 0,
                };

                self.voices.append(voice) catch {
                    std.debug.print("Unable to append voice!", .{});
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
    const waveValue: u32 = @intFromFloat(self.params.get(Parameter.Wave));
    const waveType: Wave = @enumFromInt(waveValue);

    var index = start;
    while (index < end) : (index += 1) {
        var voice_sum: f64 = 0;
        for (self.voices.items) |*voice| {

            // Oscillations per second.
            const frequency = 440.0 * std.math.exp2((@as(f64, @floatFromInt(voice.key)) - 57.0) / 12.0);

            // Where in the wave are we? 1 wavelength is 1 / frequency long
            // So we can divide that by the sample rate to get the number of wave segments per sample
            // Then we can tell where we are in the segment by passing in the elapsed frames the voice has already had
            // And throwing that into sine
            const phase = (frequency / self.sample_rate.?) * voice.elapsed_frames;

            var wave: f64 = 0;
            switch (waveType) {
                Wave.Sine => {
                    wave = std.math.sin(phase * 2.0 * 3.14159);
                },
                Wave.HalfSine => {
                    wave = clamp1(std.math.sin(phase * 2.0 * 3.14159));
                },
                Wave.Saw => {
                    wave = self.wave_table.saw(frequency, voice.elapsed_frames);
                },
                Wave.Triangle => {
                    wave = self.wave_table.triangle(frequency, voice.elapsed_frames);
                },
                Wave.Square => {
                    wave = self.wave_table.square(frequency, voice.elapsed_frames);
                },
            }

            // Elapse the voice time by a frame and update envelope
            voice.elapsed_frames += 1;

            voice_sum += wave * voice.adsr.value * self.params.get(Parameter.BaseAmplitude);

            const dt = (1 / self.sample_rate.?) * 1000;
            voice.adsr.update(dt);
        }
        const output: f32 = @floatCast(voice_sum);
        output_left[index] = output;
        output_right[index] = output;
    }
}
