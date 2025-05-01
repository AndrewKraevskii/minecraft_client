const networking = @import("minecraft_protocol.zig");
const std = @import("std");
const Allocator = std.mem.Allocator;
const Mutex = std.Thread.Mutex;

const World = @This();

const max_events = 64;

const render_distance = 32;
const loaded_diameter = render_distance * 2 + 1;
const chunks_height = 16;
const max_chunks = loaded_diameter * loaded_diameter * chunks_height;
const max_message_len = 128;
const message_history_len = 128;

arena: std.heap.ArenaAllocator,

username: []const u8,
player: Player,
chat: Chat,
chunks: std.AutoArrayHashMapUnmanaged(ChunkPos, Chunk),
events: std.ArrayListUnmanaged(Event),

const ChunkPos = struct {
    x: i32,
    y: u8,
    z: i32,
};

const Chunk = struct {
    block_type: [16][16][16]u8,

    const BlockType = enum(u8) {
        empty = 0,
        _,
    };
};

const Player = struct {
    speed: f32,

    position: [3]f32,
    yaw: f32 = 0,
    pitch: f32 = 0,
    direction: [3]f32 = .{ 1, 0, 0 },
};

const Chat = struct {
    messages: std.fifo.LinearFifo(Message, .{
        .Static = message_history_len,
    }),

    pub fn send(chat: *Chat, msg: []const u8) void {
        const trimmed = msg[0..@min(max_message_len, msg.len)];
        var bounded_message: Chat.Message = .{};
        bounded_message.appendSliceAssumeCapacity(trimmed);
        if (chat.messages.count == chat.messages.buf.len) {
            chat.messages.discard(1);
        }
        chat.messages.writeItem(bounded_message) catch unreachable;
    }

    const Message = std.BoundedArray(u8, max_message_len);
};

pub const Event = union(enum) {
    player_move: [3]f32,
    player_look_absolute: struct { yaw: f32, pitch: f32 },
    player_look_relative: struct { yaw: f32, pitch: f32 },
};

pub fn init(
    gpa: std.mem.Allocator,
    username: []const u8,
    player_position: [3]f32,
) Allocator.Error!World {
    var arena = std.heap.ArenaAllocator.init(gpa);
    const duped_username = try arena.allocator().dupe(u8, username);

    var world: World = .{
        .arena = arena,
        .username = duped_username,
        .player = .{
            .position = player_position,
            .speed = 1,
        },
        .chat = .{
            .messages = .init(),
        },
        .chunks = .empty,
        .events = .empty,
    };
    try world.chunks.ensureTotalCapacity(gpa, max_chunks);
    try world.events.ensureTotalCapacity(gpa, max_events);

    return world;
}

pub fn addEvent(world: *World, event: Event) void {
    world.events.appendAssumeCapacity(event);
}

pub fn update(
    world: *World,
    delta_t: f32,
) void {
    for (world.events.items) |event| {
        switch (event) {
            .player_move => |m| {
                world.player.position[0] += m[0] * delta_t;
                world.player.position[1] += m[1] * delta_t;
                world.player.position[2] += m[2] * delta_t;
            },
            .player_look_absolute => |l| {
                world.player.pitch = l.pitch;
                world.player.yaw = l.yaw;
            },
            .player_look_relative => |l| {
                world.player.pitch += l.pitch;
                world.player.yaw += l.yaw;
            },
        }
    }
    world.events.clearRetainingCapacity();
}

pub fn loadChunk(world: *World, position: [2]i32, chunk: Chunk) void {
    world.chunks.putAssumeCapacity(world.gpa, position, chunk);
}

pub fn unloadChunk(world: *World, position: [2]i32) void {
    world.chunks.swapRemove(world.gpa, position);
}

pub fn deinit(world: *World, gpa: Allocator) void {
    world.arena.deinit();
    world.chunks.deinit(gpa);
    world.events.deinit(gpa);
}
