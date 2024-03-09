const std = @import("std");
const c = @cImport({
    @cInclude("pulse/pulseaudio.h");
});
const Channel = @import("Channel.zig");
const Utils = @import("Utils.zig");

const SourceOutput = @This();
const CollectionType = Utils.Collection(
    Entry,
    c.pa_context_get_source_output_info,
    c.pa_context_get_source_output_info_list,
);

const pa_log = std.log.scoped(.pulse_source_output);

collection: CollectionType,

pub const Entry = struct {
    const Self = @This();

    allocator: std.mem.Allocator,

    index: u32,
    client: u32,
    source: u32,
    name: []const u8,
    channel_map: ?Channel.Map = null,

    pub fn init(allocator: std.mem.Allocator, info: [*c]const c.pa_source_output_info) !Self {
        pa_log.debug("SourceOutput[{d}] {s} init", .{ info.*.index, info.*.name });
        return Self{
            .allocator = allocator,
            .index = info.*.index,
            .client = info.*.client,
            .source = info.*.source,
            .name = try allocator.dupe(u8, std.mem.span(info.*.name)),
            .channel_map = Channel.Map.init(info.*.channel_map),
        };
    }

    pub fn deinit(self: *Self) void {
        pa_log.debug("SourceOutput[{d}] {s} deinit", .{ self.index, self.name });
        self.allocator.free(self.name);

        self.* = undefined;
    }
};

pub fn init(allocator: std.mem.Allocator, mainloop: *c.pa_threaded_mainloop, context: *c.pa_context) SourceOutput {
    return SourceOutput{
        .collection = CollectionType.init(
            allocator,
            mainloop,
            context,
        ),
    };
}

pub fn deinit(self: *SourceOutput) void {
    self.collection.deinit();
}
