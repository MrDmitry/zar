const std = @import("std");
const c = @cImport({
    @cInclude("pulse/pulseaudio.h");
});
const Channel = @import("Channel.zig");
const Utils = @import("Utils.zig");

const Source = @This();
const CollectionType = Utils.Collection(
    Entry,
    c.pa_context_get_source_info_by_index,
    c.pa_context_get_source_info_list,
);

const pa_log = std.log.scoped(.pulse_source);

collection: CollectionType,

pub const Entry = struct {
    const Self = @This();

    allocator: std.mem.Allocator,

    index: u32,
    name: []const u8,
    description: []const u8,
    channels: ?Channel.Map = null,
    owner_module: u32,
    monitor_of_sink: u32,
    latency: u64,
    configured_latency: u64,

    pub fn init(allocator: std.mem.Allocator, info: [*c]const c.pa_source_info) !Self {
        const result = Self{
            .allocator = allocator,
            .index = info.*.index,
            .name = try allocator.dupe(u8, std.mem.span(info.*.name)),
            .description = try allocator.dupe(u8, std.mem.span(info.*.description)),
            .channels = Channel.Map.init(info.*.channel_map),
            .owner_module = info.*.owner_module,
            .monitor_of_sink = info.*.monitor_of_sink,
            .latency = info.*.latency,
            .configured_latency = info.*.configured_latency,
        };
        pa_log.debug("Source[{d}] {s} init: {}", .{ info.*.index, info.*.name, result });
        pa_log.debug("Source[{d}] props: {s}", .{ info.*.index, c.pa_proplist_to_string(info.*.proplist) });
        return result;
    }

    pub fn deinit(self: *Self) void {
        pa_log.debug("Source[{d}] {s} deinit", .{ self.index, self.name });
        self.allocator.free(self.description);
        self.allocator.free(self.name);

        self.* = undefined;
    }
};

pub fn init(allocator: std.mem.Allocator, mainloop: *c.pa_threaded_mainloop, context: *c.pa_context) Source {
    return Source{
        .collection = CollectionType.init(
            allocator,
            mainloop,
            context,
        ),
    };
}

pub fn deinit(self: *Source) void {
    self.collection.deinit();
}
