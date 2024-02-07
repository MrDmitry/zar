const std = @import("std");
const c = @cImport({
    @cInclude("pulse/pulseaudio.h");
});

const PulseError = error{
    GeneralError,
    ContextError,
};

const pa_log = std.log.scoped(.pulse);

const PulseContext = struct {
    const Self = @This();

    mainloop: *c.pa_threaded_mainloop,
    mainloop_api: *c.pa_mainloop_api,
    context: *c.pa_context,

    fn init() Self {
        const mainloop = c.pa_threaded_mainloop_new().?;
        errdefer c.pa_threaded_mainloop_new(mainloop);

        c.pa_threaded_mainloop_set_name(mainloop, "zar_pa");

        const api = c.pa_threaded_mainloop_get_api(mainloop);

        const ctx = c.pa_context_new(api, "ZenAudioRouter").?;
        errdefer {
            c.pa_context_unref(ctx);
        }

        return Self{
            .mainloop = mainloop,
            .mainloop_api = api,
            .context = ctx,
        };
    }

    fn deinit(self: *Self) void {
        c.pa_context_disconnect(self.context);
        c.pa_context_unref(self.context);
        c.pa_threaded_mainloop_stop(self.mainloop);
        c.pa_threaded_mainloop_free(self.mainloop);
    }

    fn contextCallback(ctx: ?*c.pa_context, data: ?*anyopaque) callconv(.C) void {
        const self: *Self = @ptrCast(@alignCast(data.?));
        std.debug.assert(ctx.? == self.context);

        switch (c.pa_context_get_state(self.context)) {
            c.PA_CONTEXT_READY => {
                pa_log.debug("pulse context ready", .{});
            },
            c.PA_CONTEXT_FAILED, c.PA_CONTEXT_TERMINATED => {
                pa_log.debug("pulse context terminated", .{});
            },
            else => |state| {
                pa_log.debug("pulse context changed: {any}", .{state});
            },
        }
    }

    fn start(self: *Self) !void {
        c.pa_context_set_state_callback(
            self.context,
            &contextCallback,
            @ptrCast(self),
        );

        if (c.pa_context_connect(self.context, null, 0, null) != 0) {
            pa_log.warn("failed to connect context to pulse server", .{});
            return PulseError.ContextError;
        }
        errdefer c.pa_context_disconnect(self.context);

        pa_log.debug("starting pulse", .{});
        if (c.pa_threaded_mainloop_start(self.mainloop) != 0) {
            pa_log.warn("failed to start pulse", .{});
            return PulseError.GeneralError;
        }
    }

    fn stop(self: *Self) void {
        pa_log.debug("stopping pulse", .{});
        c.pa_threaded_mainloop_stop(self.mainloop);
    }
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer std.debug.assert(gpa.deinit() == .ok);

    var pulse = PulseContext.init();
    defer pulse.deinit();

    try pulse.start();

    var buf: [128]u8 = undefined;
    _ = try std.io.getStdIn().reader().readUntilDelimiterOrEof(buf[0..], '\n');
    std.log.debug("input: {s}", .{buf});

    pulse.stop();
}
