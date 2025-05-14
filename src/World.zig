const std = @import("std");
const Allocator = std.mem.Allocator;

const World = @This();

pub const max_events = 64;

pub const render_distance = 32;
pub const loaded_diameter = render_distance * 2 + 1;
pub const chunks_in_column = 16;
pub const max_chunks = loaded_diameter * loaded_diameter * chunks_in_column;

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
    block_type: [size][size][size]BlockType,
    // generation
    gen: u64 = 0,

    pub const size = 16;

    const BlockType = enum(u8) {
        empty = 0,
        _,
    };

    pub const Pos = struct {
        x: i32,
        y: u4,
        z: i32,

        pub fn fromFloatPos(pos: [3]f32) Pos {
            return .{
                .x = @intFromFloat(@floor(pos[0] / size)),
                .y = @intFromFloat(@floor(pos[1] / size)),
                .z = @intFromFloat(@floor(pos[2] / size)),
            };
        }

        pub fn relativeToChunk(pos: Pos, world_pos: [3]f32) [3]u4 {
            return .{
                @intFromFloat(world_pos[0] - @as(f32, @floatFromInt(pos.x)) * size),
                @intFromFloat(world_pos[1] - @as(f32, @floatFromInt(pos.y)) * size),
                @intFromFloat(world_pos[2] - @as(f32, @floatFromInt(pos.z)) * size),
            };
        }

        pub fn toFloat(pos: Pos) [3]f32 {
            return .{
                @as(f32, @floatFromInt(pos.x)) * size,
                @as(f32, @floatFromInt(pos.y)) * size,
                @as(f32, @floatFromInt(pos.z)) * size,
            };
        }
    };
};

pub const Player = struct {
    id: Id,
    name: Name,
    position: [3]f32,
    stance: f32 = 1.74,
    velocity: [3]f32 = @splat(0),
    yaw: f32 = 0,
    pitch: f32 = 0,
    on_ground: bool,

    const Name = std.BoundedArray(u8, max_entity_name_len);
    const Id = enum(i32) { _ };

    const debug_speed = speed * 2;

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

    pub fn setPosition(pl: *Player, pos: [3]f32) void {
        pl.position = pos;
        pl.stance = pos[1] - 1.62;
    }

    pub fn setHeight(pl: *Player, height: f32) void {
        pl.setPosition(.{
            pl.position[0],
            height,
            pl.position[2],
        });
    }
};

pub const Chat = struct {
    next_id: Message.Id = @enumFromInt(1),
    last_my_message: Message.Id = .none,

    messages: std.ArrayListUnmanaged(Message),

    pub fn send(chat: *Chat, msg: []const u8, from: @FieldType(Message, "origin")) Message.Id {
        const trimmed = msg[0..@min(max_message_len, msg.len)];
        var bounded_message: @FieldType(Message, "bytes") =
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
        .on_ground = true,
        .name = Player.Name.fromSlice(username) catch @panic("name to long"),
        .position = player_position,
        .id = player_id,
    });

    return world;
}

pub fn playerPtr(world: *World) *Player {
    std.debug.assert(world.players.getIndex(world.player_id) == 0);

    return &world.players.values()[0];
}

pub fn player(world: *const World) Player {
    return @constCast(world).playerPtr().*;
}

/// Process one tick of game
pub fn tick(
    world: *World,
    events: []const Event,
    delta_t: f32,
) void {
    const yaw = world.player().yaw;
    for (events) |event| {
        switch (event) {
            else => {
                std.log.err("got event {s}", .{@tagName(event)});
            },
            .player_move => |m| {
                world.playerPtr().position[0] += @cos(-yaw) * m[0] * delta_t * Player.debug_speed + @sin(yaw) * m[2] * delta_t * Player.debug_speed;
                world.playerPtr().position[1] += m[1] * delta_t * Player.debug_speed;
                world.playerPtr().position[2] += @sin(-yaw) * m[0] * delta_t * Player.debug_speed + @cos(yaw) * m[2] * delta_t * Player.debug_speed;
            },
            .player_look_absolute => |l| {
                world.playerPtr().pitch = l.pitch;
                world.playerPtr().yaw = l.yaw;
            },
            .player_look_relative => |l| {
                world.playerPtr().pitch += l.pitch;
                world.playerPtr().yaw += l.yaw;
            },
        }
    }

    // make sure player is always at the top block
    // const top = world.firstNonEmptyBlockAtTheTop(world.player().position[0], world.player().position[2]);
    // world.playerPtr().on_ground = true;
    // world.playerPtr().setHeight(@as(f32, @floatFromInt(top)) + 4.62);
}

fn firstNonEmptyBlockAtTheTop(world: *const World, x: f32, z: f32) u8 {
    const chunk_pos = Chunk.Pos.fromFloatPos(.{ x, 0, z });
    const rel = chunk_pos.relativeToChunk(world.player().position);
    const height = outer: for (0..16) |chunk_height| {
        const chunk = world.chunks.get(.{
            .x = chunk_pos.x,
            .z = chunk_pos.z,
            .y = @intCast(15 - chunk_height),
        }) orelse continue;
        for (0..16) |index| {
            if (chunk.block_type[15 - index][rel[2]][rel[0]] != .empty) {
                break :outer (15 - chunk_height) * 16 + 15 - index;
            }
        } else continue :outer;
    } else return 0;

    return @intCast(height);
}

pub fn loadChunk(world: *World, position: Chunk.Pos, chunk: Chunk) void {
    world.chunks.putAssumeCapacity(position, chunk);
    // log.debug("Loaded chunk total: {d}", .{world.chunks.count()});
}

pub fn unloadChunk(world: *World, position: Chunk.Pos) void {
    world.chunks.swapRemove(position);
}

pub fn deinit(world: *World, gpa: Allocator) void {
    world.chunks.deinit(gpa);
    world.players.deinit(gpa);
    world.chat.messages.deinit(gpa);
}
