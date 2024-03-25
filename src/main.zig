const std = @import("std");
const StopSource = @import("async/StopSource.zig");
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

var stop_src: *StopSource = undefined;
var pulse_context: ?*PulseAudio.Context = null;

fn interruptHandler(signal: c_int) align(1) callconv(.C) void {
    std.debug.assert(signal == std.os.linux.SIG.INT);

    stop_src.requestStop();
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer std.debug.assert(gpa.deinit() == .ok);

    stop_src = try StopSource.init(gpa.allocator());
    defer stop_src.deinit();

    // Process SIGINT
    const sa = std.os.Sigaction{
        .handler = .{ .handler = &interruptHandler },
        .mask = std.os.empty_sigset,
        .flags = (std.os.SA.SIGINFO | std.os.SA.RESTART),
    };
    try std.os.sigaction(std.os.linux.SIG.INT, &sa, null);

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

    var pulse = PulseAudio.Context.init(gpa.allocator(), stop_src);
    defer pulse.deinit();

    pulse_context = &pulse;

    try pulse.start();

    try pulse.setup(config);

    while (!stop_src.stopRequested()) {
        try pulse.update();
    }

    pulse.stop();
}
