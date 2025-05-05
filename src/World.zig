const std = @import("std");
const Allocator = std.mem.Allocator;
const log = std.log.scoped(.world);

const World = @This();

pub const max_events = 64;

pub const render_distance = 32;
pub const loaded_diameter = render_distance * 2 + 1;
pub const chunks_height = 16;
pub const max_chunks = loaded_diameter * loaded_diameter * chunks_height;

pub const max_message_len = 128;
pub const message_history_len = 128;

pub const max_entities = 200;
pub const max_entity_name_len = 16;

player_id: Player.Id,
chat: Chat,
chunks: std.AutoArrayHashMapUnmanaged(Chunk.Pos, Chunk),
players: std.AutoArrayHashMapUnmanaged(Player.Id, Player),

time: struct {
    of_world: u64,
    of_day: u64,
},

pub const Chunk = struct {
    ///          Y     Z     X
    block_type: [size][size][size]u8,

    pub const size = 16;

    const BlockType = enum(u8) {
        empty = 0,
        _,
    };

    const Pos = struct {
        x: i32,
        y: u4,
        z: i32,
    };
};

const Player = struct {
    id: Id,
    name: Name,
    position: [3]f32,
    velocity: [3]f32 = @splat(0),
    yaw: f32 = 0,
    pitch: f32 = 0,

    const Name = std.BoundedArray(u8, max_entity_name_len);
    const Id = enum(i32) { _ };

    const eye_height = 1.62;
    const eneaking_eye_height = 1.27;

    const ground_acceleration = 0.1;
    const bounds_acceleration = 0.5;
    const air_acceleration = 0.02;

    const speed = 4.317;

    /// Sprint speed
    const fast_speed = 5.612;

    /// Crouch speed
    const slow_speed = 1.295;
};

pub const Chat = struct {
    next_id: Message.Id = @enumFromInt(1),
    last_my_message: Message.Id = .none,

    messages: std.ArrayListUnmanaged(Message),

    pub fn send(chat: *Chat, msg: []const u8, from: @FieldType(Message, "origin")) Message.Id {
        const trimmed = msg[0..@min(max_message_len, msg.len)];
        var bounded_message: @FieldType(Chat.Message, "bytes") =
            .{};
        bounded_message.appendSliceAssumeCapacity(trimmed);
        if (chat.messages.unusedCapacitySlice().len == 0) {
            _ = chat.messages.orderedRemove(0);
        }
        chat.messages.appendAssumeCapacity(.{
            .bytes = bounded_message,
            .origin = from,
            .id = chat.next_id,
        });
        defer chat.next_id = chat.next_id.next();

        return chat.next_id;
    }

    pub const Message = struct {
        id: Id,
        bytes: std.BoundedArray(u8, max_message_len),
        origin: enum {
            client,
            server,
        },

        pub const Id = enum(u64) {
            none = 0,
            _,

            fn next(id: Id) Id {
                return @enumFromInt(@intFromEnum(id) + 1);
            }
        };
    };
};

pub const Event = union(enum) {
    player_move: [3]f32,
    player_look_absolute: struct { yaw: f32, pitch: f32 },
    player_look_relative: struct { yaw: f32, pitch: f32 },
    update_health: struct {
        /// <= 0 -> dead, == 20 -> full HP
        health: f32,
        /// 0 - 20
        food: i16,
        food_starvation: f32,
    },
    spawn_player: struct {
        id: Player.Id,
        name: Player.Name,
        position: [3]f32,
    },
};

pub fn init(
    gpa: std.mem.Allocator,
    username: []const u8,
    player_position: [3]f32,
    player_id: Player.Id,
) Allocator.Error!World {
    var world: World = .{
        .time = .{ .of_day = 0, .of_world = 0 },
        .player_id = player_id,
        .chat = .{
            .messages = try .initCapacity(gpa, message_history_len),
        },
        .chunks = .empty,
        .players = .empty,
    };
    try world.chunks.ensureUnusedCapacity(gpa, max_chunks);
    try world.players.ensureUnusedCapacity(gpa, max_entities);
    world.players.putAssumeCapacity(player_id, .{
        .name = Player.Name.fromSlice(username) catch @panic("name to long"),
        .position = player_position,
        .id = player_id,
    });

    return world;
}

pub fn player(world: *World) *Player {
    std.debug.assert(world.players.getIndex(world.player_id) == 0);

    return &world.players.values()[0];
}

/// Processe one tick of game
pub fn tick(
    world: *World,
    events: []const Event,
    delta_t: f32,
) void {
    for (events) |event| {
        switch (event) {
            else => {
                std.log.err("got event {s}", .{@tagName(event)});
            },
            .player_move => |m| {
                world.player().velocity[0] += m[0] * delta_t * Player.ground_acceleration;
                world.player().velocity[1] += m[1] * delta_t * Player.ground_acceleration;
                world.player().velocity[2] += m[2] * delta_t * Player.ground_acceleration;
            },
            .player_look_absolute => |l| {
                world.player().pitch = l.pitch;
                world.player().yaw = l.yaw;
            },
            .player_look_relative => |l| {
                world.player().pitch += l.pitch;
                world.player().yaw += l.yaw;
            },
        }
    }
}

pub fn loadChunk(world: *World, position: Chunk.Pos, chunk: Chunk) void {
    world.chunks.putAssumeCapacity(position, chunk);
    log.debug("Loaded chunk total: {d}", .{world.chunks.count()});
}

pub fn unloadChunk(world: *World, position: Chunk.Pos) void {
    world.chunks.swapRemove(position);
}

pub fn deinit(world: *World, gpa: Allocator) void {
    world.chunks.deinit(gpa);
    world.players.deinit(gpa);
    world.chat.messages.deinit(gpa);
}
