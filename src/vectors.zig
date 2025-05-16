//! Different ways to refer to positions in world.
//! Y axis points up.

const std = @import("std");

pub const EntityPosition = struct {
    x: f64,
    y: f64,
    z: f64,

    pub const zero: @This() = .{ .x = 0, .y = 0, .z = 0 };
};

pub const ChunkBlockPosition = struct {
    x: u4,
    y: u4,
    z: u4,
};

pub const WorldBlockPosition = struct {
    x: i32,
    y: u8,
    z: i32,
};

pub const WorldBlockPosition2d = struct {
    x: i32,
    z: i32,
};

pub const ChunkPosition = struct {
    x: i32,
    y: u4,
    z: i32,

    const chunk_size = 16;

    pub fn fromEntityPos(pos: EntityPosition) ChunkPosition {
        return .{
            .x = @intFromFloat(@floor(pos.x / chunk_size)),
            .y = @intFromFloat(@floor(pos.y / chunk_size)),
            .z = @intFromFloat(@floor(pos.z / chunk_size)),
        };
    }

    pub fn relativeToChunk(pos: ChunkPosition, world_pos: EntityPosition) ChunkBlockPosition {
        return .{
            @intFromFloat(world_pos[0] - @as(f32, @floatFromInt(pos.x)) * chunk_size),
            @intFromFloat(world_pos[1] - @as(f32, @floatFromInt(pos.y)) * chunk_size),
            @intFromFloat(world_pos[2] - @as(f32, @floatFromInt(pos.z)) * chunk_size),
        };
    }

    pub fn toFloat(pos: ChunkPosition) [3]f32 {
        return .{
            @as(f32, @floatFromInt(pos.x)) * chunk_size,
            @as(f32, @floatFromInt(pos.y)) * chunk_size,
            @as(f32, @floatFromInt(pos.z)) * chunk_size,
        };
    }
};
