const std = @import("std");
const c = @cImport({
    @cInclude("pulse/pulseaudio.h");
});

pub fn Collection(T: anytype, C_PA_GET_INFO: anytype, C_PA_GET_INFO_LIST: anytype) type {
    return struct {
        const Self = @This();

        const C_PA_INFO_CB = @typeInfo(
            @typeInfo(
                @typeInfo(
                    @typeInfo(@TypeOf(C_PA_GET_INFO_LIST)).Fn.params[1].type.?,
                ).Optional.child,
            ).Pointer.child,
        ).Fn.params[1].type.?;

        tsa: std.heap.ThreadSafeAllocator,

        mutex: std.Thread.Mutex = .{},

        mainloop: *c.pa_threaded_mainloop,
        context: *c.pa_context,

        collection: std.AutoHashMapUnmanaged(u32, T),

        pub fn init(
            allocator: std.mem.Allocator,
            mainloop: *c.pa_threaded_mainloop,
            context: *c.pa_context,
        ) Self {
            return Self{
                .tsa = std.heap.ThreadSafeAllocator{
                    .child_allocator = allocator,
                },
                .mainloop = mainloop,
                .context = context,
                .collection = std.AutoHashMapUnmanaged(u32, T){},
            };
        }

        pub fn deinit(self: *Self) void {
            const allocator = self.tsa.allocator();

            var it = self.collection.valueIterator();
            while (it.next()) |v| {
                v.deinit();
            }
            self.collection.deinit(allocator);

            self.* = undefined;
        }

        pub fn setup(self: *Self) void {
            const lock_needed = c.pa_threaded_mainloop_in_thread(self.mainloop) == 0;
            if (lock_needed) {
                c.pa_threaded_mainloop_lock(self.mainloop);
            }
            defer {
                if (lock_needed) {
                    c.pa_threaded_mainloop_unlock(self.mainloop);
                }
            }

            const op = C_PA_GET_INFO_LIST(
                self.context,
                &updateItemCallback,
                @ptrCast(self),
            );

            while (c.pa_operation_get_state(op) == c.PA_OPERATION_RUNNING) {
                c.pa_threaded_mainloop_wait(self.mainloop);
            }

            c.pa_operation_unref(op);
        }

        fn updateItemCallback(ctx: ?*c.pa_context, info: C_PA_INFO_CB, eol: c_int, data: ?*anyopaque) callconv(.C) void {
            const self: *Self = @ptrCast(@alignCast(data.?));
            std.debug.assert(ctx.? == self.context);

            if (eol != 0) {
                c.pa_threaded_mainloop_signal(self.mainloop, 0);
                return;
            }

            self.mutex.lock();
            defer self.mutex.unlock();

            const allocator = self.tsa.allocator();
            var entry = self.collection.getOrPut(allocator, info.*.index) catch @panic("OOM");

            if (entry.found_existing) {
                entry.value_ptr.deinit();
            }
            entry.value_ptr.* = T.init(allocator, info) catch @panic("OOM");
        }

        pub fn updateItem(self: *Self, index: u32) void {
            const lock_needed = c.pa_threaded_mainloop_in_thread(self.mainloop) == 0;
            if (lock_needed) {
                c.pa_threaded_mainloop_lock(self.mainloop);
            }
            defer {
                if (lock_needed) {
                    c.pa_threaded_mainloop_unlock(self.mainloop);
                }
            }

            const op = C_PA_GET_INFO(
                self.context,
                index,
                &updateItemCallback,
                @ptrCast(self),
            );
            c.pa_operation_unref(op);
        }

        pub fn removeItem(self: *Self, index: u32) void {
            self.mutex.lock();
            defer self.mutex.unlock();

            if (self.collection.fetchRemove(index)) |entry| {
                @constCast(&entry.value).deinit();
            }
        }
    };
}
