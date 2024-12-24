const builtin = @import("builtin");
const std = @import("std");
const clap = @import("clap-bindings");

const Plugin = @import("../plugin.zig");
const Params = @import("../ext/params.zig");
const waves = @import("waves.zig");
const ADSR = @import("adsr.zig");

const Parameter = Params.Parameter;
const Wave = waves.Wave;

const Expression = clap.events.NoteExpression.Id;
const ExpressionValues = std.EnumArray(Expression, f64);

const expression_values_default: std.enums.EnumFieldStruct(Expression, f64, null) = .{
    .volume = 1,
    .pan = 0.5,
    .tuning = 0,
    .vibrato = 0,
    .expression = 0,
    .brightness = 0,
    .pressure = 0,
};

pub const Voice = struct {
    noteId: i32 = 0,
    channel: i16 = 0,
    key: i16 = 0,
    velocity: f64 = 0,
    expression_values: ExpressionValues = ExpressionValues.init(expression_values_default),
    adsr: ADSR = ADSR.init(0, 0, 1, 0),
    elapsed_frames: u64 = 0,
};

fn getOrCreateVoice(plugin: *Plugin, event: *const clap.events.Header) !*Voice {
    const adsr = ADSR.init(
        plugin.params.get(Parameter.Attack),
        plugin.params.get(Parameter.Decay),
        plugin.params.get(Parameter.Sustain),
        plugin.params.get(Parameter.Release),
    );

    var new_voice = Voice{};
    switch (event.type) {
        .note_choke, .note_end, .note_off, .note_on => {
            const note_event: *const clap.events.Note = @ptrCast(@alignCast(event));

            new_voice = .{
                .noteId = note_event.note_id,
                .channel = note_event.channel,
                .key = note_event.key,
                .velocity = note_event.velocity,
                .adsr = adsr,
                .expression_values = ExpressionValues.init(expression_values_default),
            };
        },
        .note_expression => {
            const note_event: *const clap.events.NoteExpression = @ptrCast(@alignCast(event));

            new_voice = .{
                .noteId = note_event.note_id,
                .channel = note_event.channel,
                .key = note_event.key,
                .adsr = adsr,
                .expression_values = ExpressionValues.init(expression_values_default),
            };
        },
        else => {
            return error.ClapEventNotForVoice;
        },
    }

    for (plugin.voices.items) |*voice| {
        if ((voice.channel == new_voice.channel or new_voice.channel == -1) and
            (voice.key == new_voice.key or new_voice.key == -1) and
            (voice.noteId == new_voice.noteId or new_voice.noteId == -1))
        {
            if (new_voice.noteId != -1) {
                voice.noteId = new_voice.noteId;
            }
            return voice;
        }
    }

    const voice_ptr = try plugin.voices.addOne();
    voice_ptr.* = new_voice;
    return voice_ptr;
}

// Processing logic
pub fn processNoteChanges(plugin: *Plugin, event: *const clap.events.Header) void {
    if (event.space_id != clap.events.core_space_id) {
        return;
    }
    switch (event.type) {
        .note_on, .note_off, .note_choke => {
            // A new note was pressed
            if (event.type == .note_on) {
                _ = getOrCreateVoice(plugin, event) catch unreachable;
            } else {
                var i: u32 = 0;
                while (i < plugin.voices.items.len) : (i += 1) {
                    // We can cast the pointer as we now know that is the parent type
                    const note_event: *const clap.events.Note = @ptrCast(@alignCast(event));
                    var voice = &plugin.voices.items[i];
                    if ((voice.channel == note_event.channel or note_event.channel == -1) and
                        (voice.key == note_event.key or note_event.key == -1) and
                        (voice.noteId == note_event.note_id or note_event.note_id == -1))
                    {

                        // Note choke would have the note be immediately removed
                        if (event.type == .note_choke) {
                            _ = plugin.voices.orderedRemove(i);
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
            var voice: *Voice = getOrCreateVoice(plugin, event) catch unreachable;
            voice.expression_values.set(note_expression_event.expression_id, note_expression_event.value);
        },
        else => {},
    }
}

pub fn renderAudio(plugin: *Plugin, start: u32, end: u32, output_left: [*]f32, output_right: [*]f32) void {
    const wave_value: u32 = @intFromFloat(plugin.params.get(Parameter.WaveShape));
    const wave_type: Wave = std.meta.intToEnum(Wave, wave_value) catch Wave.Sine;

    var index = start;
    while (index < end) : (index += 1) {
        var voice_sum_l: f64 = 0;
        var voice_sum_r: f64 = 0;
        var voice_sum_mono: f64 = 0;
        for (plugin.voices.items) |*voice| {
            var wave: f64 = undefined;
            const t: f64 = @floatFromInt(voice.elapsed_frames);

            // retrieve the wave data from the pre-calculated table
            wave = waves.get(&plugin.wave_table, wave_type, plugin.sample_rate.?, voice, t);

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

        // If we have reached a point where the audio level is close enough to 0, process events in the queue
        if (std.math.approxEqAbs(f64, voice_sum_mono, 0.0, 0.1)) {
            while (plugin.event_queue.popOrNull()) |event| {
                processNoteChanges(plugin, event);
            }
        }
    }
}
