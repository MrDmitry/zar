const std = @import("std");
const c = @cImport({
    @cInclude("pulse/pulseaudio.h");
});
const Channel = @import("Channel.zig");
const Utils = @import("Utils.zig");

const Client = @This();
const CollectionType = Utils.Collection(
    Entry,
    c.pa_context_get_client_info,
    c.pa_context_get_client_info_list,
);

const pa_log = std.log.scoped(.pulse_client);

collection: CollectionType,

pub const Entry = struct {
    const Self = @This();

    allocator: std.mem.Allocator,

    index: u32,
    name: []const u8,

    pub fn init(allocator: std.mem.Allocator, info: [*c]const c.pa_client_info) !Self {
        pa_log.debug("Client[{d}] {s} init", .{ info.*.index, info.*.name });
        return Self{
            .allocator = allocator,
            .index = info.*.index,
            .name = try allocator.dupe(u8, std.mem.span(info.*.name)),
        };
    }

    pub fn deinit(self: *Self) void {
        pa_log.debug("Client[{d}] {s} deinit", .{ self.index, self.name });
        self.allocator.free(self.name);

        self.* = undefined;
    }
};

pub fn init(allocator: std.mem.Allocator, mainloop: *c.pa_threaded_mainloop, context: *c.pa_context) Client {
    return Client{
        .collection = CollectionType.init(
            allocator,
            mainloop,
            context,
        ),
    };
}

pub fn deinit(self: *Client) void {
    self.collection.deinit();
}
