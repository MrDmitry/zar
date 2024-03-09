const std = @import("std");
const c = @cImport({
    @cInclude("pulse/pulseaudio.h");
});
const Channel = @import("Channel.zig");
const Client = @import("Client.zig");
const Config = @import("../Config.zig");
const Server = @import("Server.zig");
const Sink = @import("Sink.zig");
const SinkInput = @import("SinkInput.zig");
const Source = @import("Source.zig");
const SourceOutput = @import("SourceOutput.zig");

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

const RemapModuleType = enum {
    sink,
    source,
};

const LoadModulePayload = struct {
    const Self = @This();

    allocator: std.mem.Allocator,

    context: *Context,
    args: [:0]const u8,

    pub fn deinit(self: *Self) void {
        self.allocator.free(self.args);
    }
};

pub const Context = struct {
    const Self = @This();

    allocator: std.mem.Allocator,

    mainloop: *c.pa_threaded_mainloop,
    mainloop_api: *c.pa_mainloop_api,
    context: *c.pa_context,

    server: Server,
    client: Client,
    sink: Sink,
    sink_input: SinkInput,
    source: Source,
    source_output: SourceOutput,
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
            .allocator = allocator,
            .mainloop = mainloop,
            .mainloop_api = api,
            .context = ctx,
            .server = Server.init(allocator, mainloop, ctx),
            .client = Client.init(allocator, mainloop, ctx),
            .sink = Sink.init(allocator, mainloop, ctx),
            .sink_input = SinkInput.init(allocator, mainloop, ctx),
            .source = Source.init(allocator, mainloop, ctx),
            .source_output = SourceOutput.init(allocator, mainloop, ctx),
        };
    }

    pub fn deinit(self: *Self) void {
        self.source_output.deinit();
        self.source.deinit();
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
            EventFacility.SOURCE => {
                switch (event.type) {
                    EventType.REMOVE => {
                        self.source.collection.removeItem(id);
                    },
                    EventType.NEW, EventType.CHANGE => {
                        self.source.collection.updateItem(id);
                    },
                    EventType.INVALID => unreachable,
                }
            },
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
            EventFacility.SOURCE_OUTPUT => {
                switch (event.type) {
                    EventType.REMOVE => {
                        self.source_output.collection.removeItem(id);
                    },
                    EventType.NEW, EventType.CHANGE => {
                        self.source_output.collection.updateItem(id);
                    },
                    EventType.INVALID => unreachable,
                }
            },
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

    fn loadModuleCallback(ctx: ?*c.pa_context, idx: u32, data: ?*anyopaque) callconv(.C) void {
        const payload: *LoadModulePayload = @ptrCast(@alignCast(data.?));
        const self: *Self = payload.context;
        defer {
            payload.deinit();
            self.allocator.destroy(payload);
        }

        std.debug.assert(ctx.? == self.context);
        pa_log.debug("load module callback: {d} for {s}", .{ idx, payload.args });

        c.pa_threaded_mainloop_signal(self.mainloop, 0);
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
        self.source.collection.setup();
        self.source_output.collection.setup();
    }

    pub fn stop(self: *Self) void {
        pa_log.debug("stopping pulse", .{});
        c.pa_threaded_mainloop_stop(self.mainloop);
    }

    pub fn setup(self: *Self, config: Config) !void {
        if (config.outputs) |outputs| {
            try self.setupOutputs(outputs);
        }

        if (config.inputs) |inputs| {
            try self.setupInputs(inputs);
        }
    }

    fn setupOutputs(self: *Self, outputs: []const Config.DeviceType) !void {
        var defaultSet = false;

        loop: for (outputs) |output| {
            const name = blk: {
                switch (output) {
                    .existing => |u| {
                        break :blk u;
                    },
                    .remap => |m| {
                        try self.setupRemapModule(.sink, m);
                        break :blk m.name;
                    },
                    .empty => {
                        continue :loop;
                    },
                }
            };

            if (defaultSet == false) {
                try self.server.setDefaultSink(name);
                defaultSet = true;
            }
        }
    }

    fn setupRemapModule(self: *Self, comptime module: RemapModuleType, remap: Config.RemapDevice) !void {
        var args: [1024]u8 = undefined;
        var fbs = std.io.fixedBufferStream(&args);
        var writer = fbs.writer();
        try writer.print(
            @tagName(module) ++ "_name={s} " ++ @tagName(module) ++ "_properties=device.description=\"{s}\" master={s} channels={d}",
            .{
                remap.name,
                remap.name,
                remap.existing,
                remap.channels.remap.len,
            },
        );

        try writer.writeAll(" master_channel_map=");
        for (0.., remap.channels.existing) |i, channel| {
            if (i > 0) {
                try writer.writeAll(",");
            }
            const position: Channel.Position = @enumFromInt(channel);
            try writer.writeAll(position.pulseName());
        }

        try writer.writeAll(" channel_map=");
        for (0.., remap.channels.remap) |i, channel| {
            if (i > 0) {
                try writer.writeAll(",");
            }
            const position: Channel.Position = @enumFromInt(channel);
            try writer.writeAll(position.pulseName());
        }

        var payload = try self.allocator.create(LoadModulePayload);
        payload.allocator = self.allocator;
        payload.context = self;
        payload.args = try payload.allocator.dupeZ(u8, args[0..fbs.pos]);
        errdefer {
            payload.deinit();
            self.allocator.destroy(payload);
        }

        const lock_needed = c.pa_threaded_mainloop_in_thread(self.mainloop) == 0;
        if (lock_needed) {
            c.pa_threaded_mainloop_lock(self.mainloop);
        }
        defer {
            if (lock_needed) {
                c.pa_threaded_mainloop_unlock(self.mainloop);
            }
        }

        const op = c.pa_context_load_module(
            self.context,
            "module-remap-" ++ @tagName(module),
            payload.args.ptr,
            &loadModuleCallback,
            @ptrCast(payload),
        );

        // sync
        if (lock_needed) {
            while (c.pa_operation_get_state(op) == c.PA_OPERATION_RUNNING) {
                c.pa_threaded_mainloop_wait(self.mainloop);
            }
        }

        if (op) |o| {
            c.pa_operation_unref(o);
        } else {
            pa_log.warn("failed attempt to load module", .{});
            payload.deinit();
            self.allocator.destroy(payload);
        }
    }

    fn setupInputs(self: *Self, inputs: []const Config.DeviceType) !void {
        var defaultSet = false;

        loop: for (inputs) |input| {
            const name = blk: {
                switch (input) {
                    .existing => |u| {
                        break :blk u;
                    },
                    .remap => |m| {
                        try self.setupRemapModule(.source, m);
                        break :blk m.name;
                    },
                    .empty => {
                        continue :loop;
                    },
                }
            };

            if (defaultSet == false) {
                try self.server.setDefaultSource(name);
                defaultSet = true;
            }
        }
    }
};
