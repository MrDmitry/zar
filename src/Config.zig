const std = @import("std");

const config_filename = "config.json";

const Config = @This();

pub const RemapDevice = struct {
    name: [:0]const u8,
    existing: [:0]const u8,
    channels: struct {
        existing: []i8,
        remap: []i8,
    },
};

pub const DeviceType = union(enum) {
    existing: [:0]const u8,
    remap: RemapDevice,
    empty,
};

outputs: ?[]const DeviceType = null,
inputs: ?[]const DeviceType = null,

fn default() Config {
    return Config{
        .outputs = &[_]DeviceType{
            DeviceType{
                .existing = "alsa_output.pci-0000_2f_00.4.iec958-stereo",
            },
            DeviceType{
                .existing = "alsa_output.usb-Allen___Heath_ZEDi10-00.analog-surround-40",
            },
        },
    };
}

pub fn init(allocator: std.mem.Allocator, dir: std.fs.Dir) !Config {
    const file: std.fs.File = dir.openFile(config_filename, .{}) catch |err| switch (err) {
        error.FileNotFound => return createDefaultConfig(dir),
        else => return err,
    };
    defer file.close();

    const config_json = try file.reader().readAllAlloc(allocator, 4096);
    defer allocator.free(config_json);

    return std.json.parseFromSliceLeaky(Config, allocator, config_json, .{
        .allocate = .alloc_always,
        .ignore_unknown_fields = true,
    }) catch |err| switch (err) {
        else => {
            var buf: [256]u8 = undefined;
            const realpath = try dir.realpath(config_filename, &buf);
            std.log.warn("error encountered while parsing {s}: {}", .{ realpath, err });
            std.log.warn("falling back to the default configuration", .{});
            return default();
        },
    };
}

fn createDefaultConfig(dir: std.fs.Dir) !Config {
    const file = try dir.createFile(config_filename, .{});
    defer file.close();

    try std.json.stringify(default(), .{}, file.writer());

    return default();
}

pub fn write(self: *const Config, dir: std.fs.Dir) !void {
    const file: std.fs.File = try dir.createFile(config_filename, .{});
    defer file.close();

    try std.json.stringify(self, .{
        .whitespace = .indent_2,
        .emit_null_optional_fields = false,
    }, file.writer());
}
