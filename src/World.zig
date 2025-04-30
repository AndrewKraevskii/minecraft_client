const networking = @import("minecraft_protocol.zig");
const std = @import("std");
const Allocator = std.mem.Allocator;
const Mutex = std.Thread.Mutex;

const World = @This();

arena: std.heap.ArenaAllocator,

username: []const u8,
player: Player,
chat: Chat,

const Player = struct {
    position: [3]f32,
    yaw: f32 = 0,
    pitch: f32 = 0,
    direction: [3]f32 = .{ 1, 0, 0 },
};

const Chat = struct {
    messages: std.ArrayListUnmanaged([]const u8) = .empty,
};

const Event = union(enum) {
    player_move_forward,
};

pub fn init(
    gpa: std.mem.Allocator,
    username: []const u8,
    player_position: [3]f32,
) Allocator.Error!World {
    var arena = std.heap.ArenaAllocator.init(gpa);
    const duped_username = try arena.allocator().dupe(u8, username);
    return .{
        .arena = arena,
        .username = duped_username,
        .player = .{
            .position = player_position,
        },
        .chat = .{},
    };
}

pub fn update(
    world: *World,
    delta_t: f32,
    events: []const Event,
) void {
    for (events) |event| {
        switch (event) {
            .player_moved_forward => {
                world.player.position[0] += delta_t * 0.5;
            },
        }
    }
}

pub fn loadChunk(world: *World) void {
    _ = world;
    @panic("TODO");
}

pub fn unloadChunk(world: *World) void {
    _ = world;
    @panic("TODO");
}

pub fn deinit(world: *World) void {
    world.arena.deinit();
}
