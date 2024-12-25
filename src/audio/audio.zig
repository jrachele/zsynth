const builtin = @import("builtin");
const std = @import("std");
const clap = @import("clap-bindings");

const Plugin = @import("../plugin.zig");
const Params = @import("../ext/params.zig");
const waves = @import("waves.zig");
const ADSR = @import("adsr.zig");
const Voices = @import("voices.zig");

const Parameter = Params.Parameter;
const Voice = Voices.Voice;
const Expression = Voices.Expression;

const Wave = waves.Wave;

// Processing logic
pub fn processNoteChanges(plugin: *Plugin, event: *const clap.events.Header) void {
    if (event.space_id != clap.events.core_space_id) {
        return;
    }
    switch (event.type) {
        .note_on, .note_off, .note_choke => {
            // A new note was pressed
            if (event.type == .note_on) {
                const note_event: *const clap.events.Note = @ptrCast(@alignCast(event));

                const adsr = ADSR.init(
                    plugin.params.param_values.get(Parameter.Attack),
                    plugin.params.param_values.get(Parameter.Decay),
                    plugin.params.param_values.get(Parameter.Sustain),
                    plugin.params.param_values.get(Parameter.Release),
                );

                var new_voice = Voice{};
                new_voice = .{
                    .noteId = note_event.note_id,
                    .channel = note_event.channel,
                    .key = note_event.key,
                    .velocity = note_event.velocity,
                    .adsr = adsr,
                };
                plugin.voices.voices.append(new_voice) catch unreachable;
            } else {
                var i: u32 = 0;
                while (i < plugin.voices.voices.items.len) : (i += 1) {
                    // We can cast the pointer as we now know that is the parent type
                    const note_event: *const clap.events.Note = @ptrCast(@alignCast(event));
                    var voice = &plugin.voices.voices.items[i];
                    if ((voice.channel == note_event.channel or note_event.channel == -1) and
                        (voice.key == note_event.key or note_event.key == -1) and
                        (voice.noteId == note_event.note_id or note_event.note_id == -1))
                    {

                        // Note choke would have the note be immediately removed
                        if (event.type == .note_choke) {
                            _ = plugin.voices.voices.orderedRemove(i);
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
        .note_expression => {
            const note_expression_event: *const clap.events.NoteExpression = @ptrCast(@alignCast(event));
            if (Voices.getVoiceByKey(plugin.voices.voices.items, note_expression_event.key)) |voice| {
                // When we detune, shift the phase appropriately to match the phase of the previous tuning
                if (note_expression_event.expression_id == .tuning) {
                    const original_key = voice.getTunedKey();
                    const original_frequency = waves.getFrequency(original_key);
                    const original_phase = (original_frequency / plugin.sample_rate.?) * @as(f64, @floatFromInt(voice.elapsed_frames));

                    voice.expression_values.set(note_expression_event.expression_id, note_expression_event.value);
                    const new_key = voice.getTunedKey();
                    const new_frequency = waves.getFrequency(new_key);
                    // (new_frequency / sample_rate) * frames = original_phase
                    voice.elapsed_frames = @intFromFloat(original_phase * (plugin.sample_rate.? / new_frequency));
                } else {
                    voice.expression_values.set(note_expression_event.expression_id, note_expression_event.value);
                }
            }
        },
        else => {},
    }
}

pub fn renderAudio(plugin: *Plugin, start: u32, end: u32, output_left: [*]f32, output_right: [*]f32) void {
    const wave_value: u32 = @intFromFloat(plugin.params.param_values.get(Parameter.WaveShape));
    const wave_type: Wave = std.meta.intToEnum(Wave, wave_value) catch Wave.Sine;

    var index = start;
    while (index < end) : (index += 1) {
        var voice_sum_l: f64 = 0;
        var voice_sum_r: f64 = 0;
        var voice_sum_mono: f64 = 0;
        for (plugin.voices.voices.items) |*voice| {
            var wave: f64 = undefined;
            const t: f64 = @floatFromInt(voice.elapsed_frames);

            // retrieve the wave data from the pre-calculated table
            wave = waves.get(&plugin.wave_table, wave_type, plugin.sample_rate.?, voice.getTunedKey(), t);

            // Elapse the voice time by a frame and update envelope
            voice.elapsed_frames += 1;

            const pan = voice.expression_values.get(Expression.pan);
            voice_sum_mono += wave * voice.adsr.value * voice.velocity * voice.expression_values.get(Expression.volume);
            voice_sum_l += voice_sum_mono * (1 - pan);
            voice_sum_r += voice_sum_mono * pan;

            const dt = (1 / plugin.sample_rate.?) * 1000;
            voice.adsr.update(dt);
        }

        const output_l: f32 = @floatCast(voice_sum_l);
        const output_r: f32 = @floatCast(voice_sum_r);
        output_left[index] = output_l;
        output_right[index] = output_r;
    }
}
