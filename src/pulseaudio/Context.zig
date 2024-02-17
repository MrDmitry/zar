const std = @import("std");
const c = @cImport({
    @cInclude("pulse/pulseaudio.h");
});
const Server = @import("Server.zig");
const Client = @import("Client.zig");
const Sink = @import("Sink.zig");
const SinkInput = @import("SinkInput.zig");

const PulseError = error{
    GeneralError,
    ContextError,
};

const pa_log = std.log.scoped(.pulse);

const EventFacility = enum(c_uint) {
    SINK = c.PA_SUBSCRIPTION_EVENT_SINK,
    SOURCE = c.PA_SUBSCRIPTION_EVENT_SOURCE,
    SINK_INPUT = c.PA_SUBSCRIPTION_EVENT_SINK_INPUT,
    SOURCE_OUTPUT = c.PA_SUBSCRIPTION_EVENT_SOURCE_OUTPUT,
    MODULE = c.PA_SUBSCRIPTION_EVENT_MODULE,
    CLIENT = c.PA_SUBSCRIPTION_EVENT_CLIENT,
    SAMPLE_CACHE = c.PA_SUBSCRIPTION_EVENT_SAMPLE_CACHE,
    SERVER = c.PA_SUBSCRIPTION_EVENT_SERVER,
    AUTOLOAD = c.PA_SUBSCRIPTION_EVENT_AUTOLOAD,
    CARD = c.PA_SUBSCRIPTION_EVENT_CARD,

    INVALID,
};

const EventType = enum(c_uint) {
    NEW = c.PA_SUBSCRIPTION_EVENT_NEW,
    CHANGE = c.PA_SUBSCRIPTION_EVENT_CHANGE,
    REMOVE = c.PA_SUBSCRIPTION_EVENT_REMOVE,

    INVALID,
};

const Event = struct {
    const Self = @This();

    facility: EventFacility,
    type: EventType,

    pub fn init(m: c.enum_pa_subscription_event_type) Self {
        return Self{
            .facility = find(EventFacility, m & c.PA_SUBSCRIPTION_EVENT_FACILITY_MASK),
            .type = find(EventType, m & c.PA_SUBSCRIPTION_EVENT_TYPE_MASK),
        };
    }

    fn find(T: anytype, m: c.enum_pa_subscription_event_type) T {
        const fields = @typeInfo(T).Enum.fields;
        inline for (fields) |field| {
            if (field.value == m) return @enumFromInt(m);
        }
        return T.INVALID;
    }
};

pub const Context = struct {
    const Self = @This();

    mainloop: *c.pa_threaded_mainloop,
    mainloop_api: *c.pa_mainloop_api,
    context: *c.pa_context,

    server: Server,
    client: Client,
    sink: Sink,
    sink_input: SinkInput,
    mutex: std.Thread.Mutex = .{},
    cv: std.Thread.Condition = .{},
    ready: bool = false,

    pub fn init(allocator: std.mem.Allocator) Self {
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
            .server = Server.init(allocator, mainloop, ctx),
            .client = Client.init(allocator, mainloop, ctx),
            .sink = Sink.init(allocator, mainloop, ctx),
            .sink_input = SinkInput.init(allocator, mainloop, ctx),
        };
    }

    pub fn deinit(self: *Self) void {
        self.sink_input.deinit();
        self.sink.deinit();
        self.client.deinit();
        self.server.deinit();

        c.pa_context_disconnect(self.context);
        c.pa_context_unref(self.context);
        c.pa_threaded_mainloop_stop(self.mainloop);
        c.pa_threaded_mainloop_free(self.mainloop);
    }

    fn initServer(_: ?*c.pa_context, info: [*c]const c.pa_server_info, data: ?*anyopaque) callconv(.C) void {
        const self: *Self = @ptrCast(@alignCast(data.?));
        self.server.update(info) catch unreachable;
        c.pa_threaded_mainloop_signal(self.mainloop, 0);
    }

    fn eventSubscribeCallback(ctx: ?*c.pa_context, event_type: c.pa_subscription_event_type_t, id: u32, data: ?*anyopaque) callconv(.C) void {
        const self: *Self = @ptrCast(@alignCast(data.?));
        std.debug.assert(ctx.? == self.context);
        const event = Event.init(event_type);
        pa_log.debug("{} event[{d}] {any}", .{ std.time.timestamp(), id, event });
        switch (event.facility) {
            EventFacility.SINK => {
                switch (event.type) {
                    EventType.REMOVE => {
                        self.sink.collection.removeItem(id);
                    },
                    EventType.NEW, EventType.CHANGE => {
                        self.sink.collection.updateItem(id);
                    },
                    EventType.INVALID => unreachable,
                }
            },
            EventFacility.SOURCE => {},
            EventFacility.SINK_INPUT => {
                switch (event.type) {
                    EventType.REMOVE => {
                        self.sink_input.collection.removeItem(id);
                    },
                    EventType.NEW, EventType.CHANGE => {
                        self.sink_input.collection.updateItem(id);
                    },
                    EventType.INVALID => unreachable,
                }
            },
            EventFacility.SOURCE_OUTPUT => {},
            EventFacility.MODULE => {},
            EventFacility.CLIENT => {
                switch (event.type) {
                    EventType.REMOVE => {
                        self.client.collection.removeItem(id);
                    },
                    EventType.NEW, EventType.CHANGE => {
                        self.client.collection.updateItem(id);
                    },
                    EventType.INVALID => unreachable,
                }
            },
            EventFacility.SAMPLE_CACHE => {},
            EventFacility.SERVER => {},
            EventFacility.AUTOLOAD => {},
            EventFacility.CARD => {},
            else => {},
        }
    }

    fn eventCallback(ctx: ?*c.pa_context, flag: c_int, data: ?*anyopaque) callconv(.C) void {
        const self: *Self = @ptrCast(@alignCast(data.?));
        std.debug.assert(ctx.? == self.context);
        pa_log.debug("event callback: {d}", .{flag});
        c.pa_threaded_mainloop_signal(self.mainloop, 0);
    }

    fn contextCallback(ctx: ?*c.pa_context, data: ?*anyopaque) callconv(.C) void {
        const self: *Self = @ptrCast(@alignCast(data.?));
        std.debug.assert(ctx.? == self.context);

        switch (c.pa_context_get_state(self.context)) {
            c.PA_CONTEXT_UNCONNECTED => {},
            c.PA_CONTEXT_CONNECTING => {},
            c.PA_CONTEXT_AUTHORIZING => {},
            c.PA_CONTEXT_SETTING_NAME => {},
            c.PA_CONTEXT_READY => {
                self.mutex.lock();
                defer self.mutex.unlock();

                c.pa_context_set_subscribe_callback(
                    self.context,
                    &eventSubscribeCallback,
                    @ptrCast(self),
                );

                pa_log.debug("pulse context ready", .{});

                self.ready = true;
                self.cv.signal();
            },
            c.PA_CONTEXT_FAILED, c.PA_CONTEXT_TERMINATED => {
                pa_log.debug("pulse context terminated", .{});
            },
            else => |state| {
                pa_log.debug("unexpected pulse context change: {any}", .{state});
            },
        }
    }

    pub fn start(self: *Self) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

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

        pa_log.debug("starting pulse {d}.{d}.{d}", .{ c.PA_MAJOR, c.PA_MINOR, c.PA_MICRO });
        if (c.pa_threaded_mainloop_start(self.mainloop) != 0) {
            pa_log.warn("failed to start pulse", .{});
            return PulseError.GeneralError;
        }

        while (!self.ready) {
            self.cv.wait(&self.mutex);
        }

        c.pa_threaded_mainloop_lock(self.mainloop);

        {
            const op = c.pa_context_subscribe(
                self.context,
                c.PA_SUBSCRIPTION_MASK_ALL,
                &eventCallback,
                @ptrCast(self),
            );

            while (c.pa_operation_get_state(op) == c.PA_OPERATION_RUNNING) {
                c.pa_threaded_mainloop_wait(self.mainloop);
            }

            c.pa_operation_unref(op);
        }

        c.pa_threaded_mainloop_unlock(self.mainloop);

        self.client.collection.setup();
        self.sink.collection.setup();
        self.sink_input.collection.setup();
    }

    pub fn stop(self: *Self) void {
        pa_log.debug("stopping pulse", .{});
        c.pa_threaded_mainloop_stop(self.mainloop);
    }
};
