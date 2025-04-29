const networking = @import("minecraft_network.zig");
const Packet = networking.Packet;

pub fn runClient(gpa: std.mem.Allocator, ip: []const u8, port: u16) !void {
    var full_arena = std.heap.ArenaAllocator.init(gpa);
    defer _ = full_arena.deinit();

    var packet_arena = std.heap.ArenaAllocator.init(gpa);
    defer _ = full_arena.deinit();

    const address = try std.net.Address.parseIp4(ip, port);
    const stream = try std.net.tcpConnectToAddress(address);
    defer stream.close();

    std.log.info("Connected to server", .{});
    try networking.handshake(full_arena.allocator(), stream, "Andrew", ip, port);

    var messages: std.ArrayListUnmanaged([]const u8) = .empty;

    while (true) {
        _ = packet_arena.reset(.retain_capacity);
        const packet = try Packet.read(
            stream.reader(),
            packet_arena.allocator(),
        );
        std.debug.print("\n", .{});
        switch (packet) {
            .@"Keep Alive" => {
                try packet.write(stream.writer());
            },
            .@"Chat Message" => |m| {
                try messages.append(
                    full_arena.allocator(),
                    try full_arena.allocator().dupe(u8, m.message.utf8),
                );
            },
            else => {},
        }
    }
}

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();

    const args = try std.process.argsAlloc(gpa.allocator());
    defer std.process.argsFree(gpa.allocator(), args);

    const program_path = if (args.len > 0) args[0] else "/path/to/program";

    if (args.len < 3) {
        fail("Usage {s} ip port", .{program_path});
    }
    const ip = args[1];
    const port = std.fmt.parseInt(u16, args[2], 10) catch |e| {
        fail("Can't parse port: {s}", .{@errorName(e)});
    };

    std.log.info("connecting to adress {s}:{d}", .{ ip, port });

    try runClient(gpa.allocator(), ip, port);
}

fn fail(comptime fmt: []const u8, args: anytype) noreturn {
    std.log.err(fmt, args);
    std.process.exit(1);
}

const std = @import("std");
