const std = @import("std");
const c = @cImport({
    @cInclude("pulse/pulseaudio.h");
});
const Channel = @import("Channel.zig");
const Utils = @import("Utils.zig");

const Sink = @This();
const CollectionType = Utils.Collection(
    Entry,
    c.pa_context_get_sink_info_by_index,
    c.pa_context_get_sink_info_list,
);

const pa_log = std.log.scoped(.pulse_sink);

collection: CollectionType,

pub const Entry = struct {
    const Self = @This();

    allocator: std.mem.Allocator,

    index: u32,
    name: []const u8,
    description: []const u8,
    channels: ?Channel.Map = null,

    pub fn init(allocator: std.mem.Allocator, info: [*c]const c.pa_sink_info) !Self {
        pa_log.debug("Sink[{d}] {s} init", .{ info.*.index, info.*.name });
        return Self{
            .allocator = allocator,
            .index = info.*.index,
            .name = try allocator.dupe(u8, std.mem.span(info.*.name)),
            .description = try allocator.dupe(u8, std.mem.span(info.*.description)),
            .channels = Channel.Map.init(info.*.channel_map),
        };
    }

    pub fn deinit(self: *Self) void {
        pa_log.debug("Sink[{d}] {s} deinit", .{ self.index, self.name });
        self.allocator.free(self.description);
        self.allocator.free(self.name);

        self.* = undefined;
    }
};

pub fn init(allocator: std.mem.Allocator, mainloop: *c.pa_threaded_mainloop, context: *c.pa_context) Sink {
    return Sink{
        .collection = CollectionType.init(
            allocator,
            mainloop,
            context,
        ),
    };
}

pub fn deinit(self: *Sink) void {
    self.collection.deinit();
}
