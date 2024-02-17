const std = @import("std");
const c = @cImport({
    @cInclude("pulse/pulseaudio.h");
});
const Channel = @import("Channel.zig");
const Utils = @import("Utils.zig");

const SinkInput = @This();
const CollectionType = Utils.Collection(
    Entry,
    c.pa_context_get_sink_input_info,
    c.pa_context_get_sink_input_info_list,
);

const pa_log = std.log.scoped(.pulse_sink_input);

collection: CollectionType,

pub const Entry = struct {
    const Self = @This();

    allocator: std.mem.Allocator,

    index: u32,
    client: u32,
    sink: u32,
    name: []const u8,
    channel_map: ?Channel.Map = null,

    pub fn init(allocator: std.mem.Allocator, info: [*c]const c.pa_sink_input_info) !Self {
        pa_log.debug("SinkInput[{d}] {s} init", .{ info.*.index, info.*.name });
        return Self{
            .allocator = allocator,
            .index = info.*.index,
            .client = info.*.client,
            .sink = info.*.sink,
            .name = try allocator.dupe(u8, std.mem.span(info.*.name)),
            .channel_map = Channel.Map.init(info.*.channel_map),
        };
    }

    pub fn deinit(self: *Self) void {
        pa_log.debug("SinkInput[{d}] {s} deinit", .{ self.index, self.name });
        self.allocator.free(self.name);

        self.* = undefined;
    }
};

pub fn init(allocator: std.mem.Allocator, mainloop: *c.pa_threaded_mainloop, context: *c.pa_context) SinkInput {
    return SinkInput{
        .collection = CollectionType.init(
            allocator,
            mainloop,
            context,
        ),
    };
}

pub fn deinit(self: *SinkInput) void {
    self.collection.deinit();
}
