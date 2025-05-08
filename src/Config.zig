const std = @import("std");

const Config = @This();

username: ?[]const u8 = null,
server_ip: ?[]const u8 = null,
server_port: ?u16 = null,
password: ?[]const u8 = null,

const megabyte = 1024 * 1024;

pub fn load(gpa: std.mem.Allocator, file_path: []const u8) Config {
    const default: Config = .{};

    const slice = std.fs.cwd().readFileAllocOptions(
        gpa,
        file_path,
        megabyte,
        null,
        .@"1",
        0,
    ) catch |e| {
        std.log.err("failed to load config file: {s}", .{@errorName(e)});
        return default;
    };
    defer gpa.free(slice);

    const config = std.zon.parse.fromSlice(
        Config,
        gpa,
        slice,
        null,
        .{},
    ) catch |e| {
        std.log.err("failed parse config file: {s}", .{@errorName(e)});
        return default;
    };
    return config;
}

pub fn save(config: Config, file_path: []const u8) void {
    saveFallable(config, file_path) catch |e| {
        std.log.err("failed to save config: {s}", .{@errorName(e)});
    };
}

fn saveFallable(config: Config, file_path: []const u8) !void {
    const file = try std.fs.cwd().createFile(file_path, .{});
    try std.zon.stringify.serialize(config, .{}, file.writer());
}
