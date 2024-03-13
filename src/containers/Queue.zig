const std = @import("std");

pub fn Queue(T: anytype) type {
    return struct {
        const Self = @This();

        const Node = struct {
            next: ?*Node,
            data: T,
        };

        pool: std.heap.MemoryPool(Node),

        head: ?*Node = null,
        tail: ?*Node = null,

        len: usize = 0,

        pub fn init(allocator: std.mem.Allocator) Self {
            return Self{
                .pool = std.heap.MemoryPool(Node).init(allocator),
            };
        }

        pub fn deinit(self: *Self) void {
            self.pool.deinit();
        }

        pub fn empty(self: *Self) bool {
            return self.len == 0;
        }

        pub fn push(self: *Self, data: T) !void {
            const node = try self.pool.create();
            node.* = Node{
                .next = null,
                .data = data,
            };

            if (self.tail) |tail| {
                tail.next = node;
            }

            self.tail = node;

            if (self.head == null) {
                self.head = node;
            }

            self.len += 1;
        }

        pub fn pop(self: *Self) ?T {
            if (self.len == 0) {
                return null;
            }

            if (self.head) |node| {
                defer self.pool.destroy(node);

                self.head = node.next;

                if (self.tail) |tail| {
                    if (tail == node) {
                        self.tail = null;
                    }
                }

                self.len -= 1;

                return node.data;
            }
            return null;
        }
    };
}

test "operations on empty queue" {
    var queue = Queue(u32).init(std.testing.allocator);
    defer queue.deinit();

    try std.testing.expectEqual(0, queue.len);
    try std.testing.expect(queue.empty());

    // pops from empty queue are `null`
    const val = queue.pop();
    try std.testing.expectEqual(null, val);
    try std.testing.expectEqual(0, queue.len);
    try std.testing.expect(queue.empty());
}

test "single push/pop" {
    var queue = Queue(u32).init(std.testing.allocator);
    defer queue.deinit();

    // simple push
    try queue.push(0);
    try std.testing.expectEqual(1, queue.len);
    try std.testing.expect(!queue.empty());

    // simple pop
    const val = queue.pop();
    try std.testing.expectEqual(0, val.?);
    try std.testing.expectEqual(0, queue.len);
    try std.testing.expect(queue.empty());
}

test "double push/pop" {
    var queue = Queue(u32).init(std.testing.allocator);
    defer queue.deinit();

    const limit: usize = 2;
    for (0..limit) |i| {
        try queue.push(@intCast(i));
        try std.testing.expectEqual(i + 1, queue.len);
    }

    // pop preserves order
    for (0..limit) |i| {
        const val = queue.pop();
        try std.testing.expectEqual(i, val.?);
        try std.testing.expectEqual(limit - i - 1, queue.len);
    }
    try std.testing.expect(queue.empty());
}

test "multiple push/pop" {
    var queue = Queue(u32).init(std.testing.allocator);
    defer queue.deinit();

    const limit = 5;
    for (0..limit) |i| {
        try queue.push(@intCast(i));
        try std.testing.expectEqual(i + 1, queue.len);
    }

    // pop preserves order
    for (0..limit) |i| {
        const val = queue.pop();
        try std.testing.expectEqual(i, val.?);
        try std.testing.expectEqual(limit - i - 1, queue.len);
    }
    try std.testing.expect(queue.empty());
}
