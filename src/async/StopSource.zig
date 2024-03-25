const std = @import("std");

const StopSource = @This();

stopped: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

allocator: std.mem.Allocator,

mutex: std.Thread.Mutex = .{},
parent: std.atomic.Value(?*StopSource) = std.atomic.Value(?*StopSource).init(null),
children: std.ArrayList(*StopSource),

pub const StopToken = struct {
    const Self = @This();

    parent: *const StopSource,

    pub fn stopRequested(self: *const Self) bool {
        return self.parent.stopRequested();
    }
};

pub fn init(alloc: std.mem.Allocator) !*StopSource {
    const result = try alloc.create(StopSource);

    result.* = StopSource{
        .allocator = alloc,
        .children = std.ArrayList(*StopSource).init(alloc),
    };

    return result;
}

pub fn deinit(self: *StopSource) void {
    if (self.parent.load(.Acquire)) |parent| {
        parent.forgetChild(self);
    }

    for (self.children.items) |child| {
        child.forgetParent(self);
    }

    self.children.deinit();
    self.allocator.destroy(self);
}

pub fn requestStop(self: *StopSource) void {
    self.stopped.store(true, .Release);

    self.mutex.lock();
    defer self.mutex.unlock();

    for (self.children.items) |child| {
        child.requestStop();
    }
}

pub fn stopRequested(self: *const StopSource) bool {
    return self.stopped.load(.Acquire);
}

pub fn getToken(self: *StopSource) StopToken {
    return StopToken{
        .parent = self,
    };
}

pub fn spawnChild(self: *StopSource, alloc: std.mem.Allocator) !*StopSource {
    const result = try init(alloc);

    result.stopped.store(self.stopped.load(.Acquire), .Release);
    result.parent.store(self, .Release);

    {
        self.mutex.lock();
        defer self.mutex.unlock();

        try self.children.append(result);
    }

    return result;
}

fn forgetChild(self: *StopSource, child: *StopSource) void {
    self.mutex.lock();
    defer self.mutex.unlock();

    for (0.., self.children.items) |i, c| {
        if (c == child) {
            const got = self.children.swapRemove(i);
            std.debug.assert(got == child);
            return;
        }
    }

    unreachable;
}

fn forgetParent(self: *StopSource, parent: *StopSource) void {
    std.debug.assert(self.parent.load(.Monotonic) == parent);

    self.mutex.lock();
    defer self.mutex.unlock();

    self.parent.store(null, .Release);
}

test "dummy" {
    var src = try StopSource.init(std.testing.allocator);
    defer src.deinit();
}

test "simple requestStop" {
    var src = try StopSource.init(std.testing.allocator);
    defer src.deinit();

    const token = src.getToken();

    try std.testing.expectEqual(false, src.stopRequested());
    try std.testing.expectEqual(false, token.stopRequested());

    src.requestStop();

    try std.testing.expectEqual(true, src.stopRequested());
    try std.testing.expectEqual(true, token.stopRequested());
}

test "spawn child" {
    var src = try StopSource.init(std.testing.allocator);
    defer src.deinit();

    var child_src = try src.spawnChild(std.testing.allocator);
    defer child_src.deinit();
}

test "spawn child from stopped parent" {
    var src = try StopSource.init(std.testing.allocator);
    defer src.deinit();

    src.requestStop();
    try std.testing.expectEqual(true, src.stopRequested());

    var child_src = try src.spawnChild(std.testing.allocator);
    defer child_src.deinit();

    try std.testing.expectEqual(true, child_src.stopRequested());
}

test "child requestStop" {
    var src = try StopSource.init(std.testing.allocator);
    defer src.deinit();

    var child_src = try src.spawnChild(std.testing.allocator);
    defer child_src.deinit();

    try std.testing.expectEqual(false, src.stopRequested());
    try std.testing.expectEqual(false, child_src.stopRequested());

    child_src.requestStop();

    try std.testing.expectEqual(false, src.stopRequested());
    try std.testing.expectEqual(true, child_src.stopRequested());
}

test "parent requestStop" {
    var src = try StopSource.init(std.testing.allocator);
    defer src.deinit();

    var child_src = try src.spawnChild(std.testing.allocator);
    defer child_src.deinit();

    try std.testing.expectEqual(false, src.stopRequested());
    try std.testing.expectEqual(false, child_src.stopRequested());

    src.requestStop();

    try std.testing.expectEqual(true, src.stopRequested());
    try std.testing.expectEqual(true, child_src.stopRequested());
}

test "mixed allocators" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer std.debug.assert(gpa.deinit() == .ok);

    var src = try StopSource.init(std.testing.allocator);
    defer src.deinit();

    var child_src = try src.spawnChild(gpa.allocator());
    defer child_src.deinit();

    try std.testing.expectEqual(false, src.stopRequested());
    try std.testing.expectEqual(false, child_src.stopRequested());

    src.requestStop();

    try std.testing.expectEqual(true, src.stopRequested());
    try std.testing.expectEqual(true, child_src.stopRequested());
}

test "child destroyed before parent is stopped" {
    var src = try StopSource.init(std.testing.allocator);
    defer src.deinit();

    var child_src = try src.spawnChild(std.testing.allocator);
    child_src.deinit();

    src.requestStop();

    try std.testing.expectEqual(true, src.stopRequested());
}

test "parent destroyed before child" {
    var src = try StopSource.init(std.testing.allocator);

    var child_src = try src.spawnChild(std.testing.allocator);
    defer child_src.deinit();

    src.deinit();
}
