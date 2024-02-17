const std = @import("std");
const PulseAudio = @import("pulseaudio/Context.zig");
const Config = @import("Config.zig");

const Args = enum {
    @"-h",
    @"--help",
    @"-c",
    @"-d",
};

const ArgsDefaults = struct {
    const @"-c": []const u8 = "/etc/zar";
    const @"-d": bool = false;
};

pub fn printHelp() noreturn {
    std.debug.print(
        \\Zen Audio Router
        \\
        \\usage: zar [-c dir] [-d] [-h/--help]
        \\
        \\arguments:
        \\  -c          dir : path to the zar configuration directory (default: {s})
        \\  -d              : start as a daemon (default: {})
        \\  -h/--help       : display this help and exit
        \\
    , .{
        ArgsDefaults.@"-c",
        ArgsDefaults.@"-d",
    });
    std.process.exit(1);
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer std.debug.assert(gpa.deinit() == .ok);

    var args = try std.process.ArgIterator.initWithAllocator(gpa.allocator());
    defer args.deinit();

    _ = args.skip(); // executable name

    var config_dir: ?std.fs.Dir = null;

    while (args.next()) |it| {
        const key = std.meta.stringToEnum(Args, it) orelse {
            std.log.err("unexpected argument: {s}\n", .{it});
            printHelp();
        };

        switch (key) {
            .@"-h", .@"--help" => printHelp(),
            .@"-c" => {
                const value = args.next() orelse {
                    std.log.err("missing value for {s}\n", .{it});
                    printHelp();
                };
                config_dir = try std.fs.cwd().openDir(value, .{});

                std.log.debug("key: {s}; value: {s}", .{ it, value });
            },
            else => unreachable,
        }
    }

    var config_arena = std.heap.ArenaAllocator.init(gpa.allocator());
    defer config_arena.deinit();

    const config = try Config.init(config_arena.allocator(), config_dir orelse try std.fs.openDirAbsolute(ArgsDefaults.@"-c", .{}));
    //try config.write(config_dir.?);
    std.log.debug("config: {any}", .{config});

    var pulse = PulseAudio.Context.init(gpa.allocator());
    defer pulse.deinit();

    try pulse.start();

    if (config.outputs.?.len > 0) {
        try pulse.server.setDefaultSink(config.outputs.?[0].device.real);
    }

    var buf: [128]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    _ = try std.io.getStdIn().reader().streamUntilDelimiter(fbs.writer(), '\n', null);
    std.log.debug("input: {s}", .{buf});

    pulse.stop();
}
