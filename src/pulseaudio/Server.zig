const std = @import("std");
const c = @cImport({
    @cInclude("pulse/pulseaudio.h");
});

const pa_log = std.log.scoped(.pulse_server);
const Server = @This();

tsa: std.heap.ThreadSafeAllocator,
default_sink: ?[]const u8 = null,
default_source: ?[]const u8 = null,

mutex: std.Thread.Mutex = .{},

mainloop: *c.pa_threaded_mainloop,
context: *c.pa_context,

const NewValue = union(enum) {
    default_sink: []const u8,
    default_source: []const u8,
};

const UpdatePayload = struct {
    server: *Server,
    data: NewValue,
};

pub fn init(allocator: std.mem.Allocator, mainloop: *c.pa_threaded_mainloop, context: *c.pa_context) Server {
    return Server{
        .tsa = std.heap.ThreadSafeAllocator{
            .child_allocator = allocator,
        },
        .mainloop = mainloop,
        .context = context,
    };
}

pub fn deinit(self: *Server) void {
    var allocator = self.tsa.allocator();

    if (self.default_sink) |ptr| {
        allocator.free(ptr);
    }

    if (self.default_source) |ptr| {
        allocator.free(ptr);
    }

    self.* = undefined;
}

pub fn update(self: *Server, info: [*c]const c.pa_server_info) !void {
    pa_log.debug("updating server: {s}, {s}", .{
        info.*.default_sink_name,
        info.*.default_source_name,
    });
    self.mutex.lock();
    defer self.mutex.unlock();

    var allocator = self.tsa.allocator();

    if (self.default_sink) |ptr| {
        allocator.free(ptr);
    }
    self.default_sink = try allocator.dupe(u8, std.mem.span(info.*.default_sink_name));

    if (self.default_source) |ptr| {
        allocator.free(ptr);
    }
    self.default_source = try allocator.dupe(u8, std.mem.span(info.*.default_source_name));
}

fn printServer(_: ?*c.pa_context, info: [*c]const c.pa_server_info, _: ?*anyopaque) callconv(.C) void {
    pa_log.debug("server: {s}:{s}; sink: {s}; source: {s}", .{
        info.*.server_name,
        info.*.server_version,
        info.*.default_sink_name,
        info.*.default_source_name,
    });
}

fn dataUpdateCallback(ctx: ?*c.pa_context, success: c_int, data: ?*anyopaque) callconv(.C) void {
    _ = ctx;

    pa_log.debug("dataUpdateCallback success {d}", .{success});

    const payload: *UpdatePayload = @ptrCast(@alignCast(data.?));
    var self = payload.server;
    var allocator = self.tsa.allocator();
    defer allocator.destroy(payload);

    if (success == 0) {
        switch (payload.data) {
            .default_sink, .default_source => |value| {
                allocator.free(value);
            },
        }
        return;
    }

    const op = c.pa_context_get_server_info(
        self.context,
        &printServer,
        @ptrCast(self),
    );
    c.pa_operation_unref(op);

    self.mutex.lock();
    defer self.mutex.unlock();

    switch (payload.data) {
        .default_sink => |value| {
            if (self.default_sink) |ptr| {
                allocator.free(ptr);
            }
            self.default_sink = value;
        },
        .default_source => |value| {
            if (self.default_source) |ptr| {
                allocator.free(ptr);
            }
            self.default_source = value;
        },
    }
}

pub fn setDefaultSink(self: *Server, name: []const u8) !void {
    var allocator = self.tsa.allocator();

    var payload = try allocator.create(UpdatePayload);
    payload.server = self;
    payload.data = .{
        .default_sink = try allocator.dupe(u8, name),
    };
    errdefer allocator.destroy(payload);

    {
        const lock_needed = c.pa_threaded_mainloop_in_thread(self.mainloop) == 0;
        if (lock_needed) {
            c.pa_threaded_mainloop_lock(self.mainloop);
        }
        defer {
            if (lock_needed) {
                c.pa_threaded_mainloop_unlock(self.mainloop);
            }
        }

        pa_log.debug("set default sink to {s}", .{name});
        const op = c.pa_context_set_default_sink(
            self.context,
            name.ptr,
            &dataUpdateCallback,
            @ptrCast(payload),
        );

        if (op) |o| {
            c.pa_operation_unref(o);
        } else {
            pa_log.warn("failed attempt to set sink", .{});
            allocator.destroy(payload);
        }
    }
}

pub fn setDefaultSource(self: *Server, name: []const u8) !void {
    var allocator = self.tsa.allocator();

    var payload = try allocator.create(UpdatePayload);
    payload.server = self;
    payload.data = .{
        .default_source = try allocator.dupe(u8, name),
    };

    {
        const lock_needed = c.pa_threaded_mainloop_in_thread(self.mainloop) == 0;
        if (lock_needed) {
            c.pa_threaded_mainloop_lock(self.mainloop);
        }
        defer {
            if (lock_needed) {
                c.pa_threaded_mainloop_unlock(self.mainloop);
            }
        }

        pa_log.debug("set default source to {s}", .{name});
        const op = c.pa_context_set_default_source(
            self.context,
            name.ptr,
            &dataUpdateCallback,
            @ptrCast(payload),
        );

        if (op) |o| {
            c.pa_operation_unref(o);
        } else {
            pa_log.warn("failed attempt to set source", .{});
            allocator.destroy(payload);
        }
    }
}
