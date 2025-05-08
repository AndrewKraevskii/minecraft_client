const std = @import("std");
const ChunkColumn = @This();

chunks: [16]?Chunk,
biome: ?[16][16]u8,

const Chunk = struct {
    /// starting from 0
    ///           Y,  Z,  X
    block_type: [16][16][16]u8,
    block_meta: DataNibble,
    block_light: DataNibble,
    sky_light: ?DataNibble,
    add_array: DataNibble,

    /// TODO: i remember there was packed array type
    const DataNibble = [16][16][8]packed struct {
        @"0": u4,
        @"1": u4,
    };

    comptime {
        std.debug.assert(@sizeOf(DataNibble) == 2048);
    }
};

pub fn parse(
    stream: anytype,
    primary_mask: u16,
    add_mask: u16,
    skylight: bool,
    ground_up_continuous: bool,
) !ChunkColumn {
    var chunk_column: ChunkColumn = .{
        .chunks = @splat(null),
        .biome = null,
    };
    try parseSection(&chunk_column, stream, "block_type", primary_mask);
    try parseSection(&chunk_column, stream, "block_meta", primary_mask);
    try parseSection(&chunk_column, stream, "block_light", primary_mask);
    if (skylight) {
        try parseSection(&chunk_column, stream, "sky_light", primary_mask);
    }
    try parseSection(&chunk_column, stream, "add_array", add_mask);
    if (ground_up_continuous) {
        chunk_column.biome = @bitCast(try stream.readBytesNoEof(256));
    } else {
        chunk_column.biome = null;
    }

    return chunk_column;
}

pub fn parseSection(chunk_column: *ChunkColumn, stream: anytype, comptime section_name: []const u8, mask: u16) !void {
    for (0..16) |i| {
        if (mask & (@as(u16, 1) << @intCast(i)) != 0) {
            if (chunk_column.chunks[i] == null) {
                chunk_column.chunks[i] = Chunk{
                    .block_type = undefined,
                    .block_meta = undefined,
                    .block_light = undefined,
                    .sky_light = undefined,
                    .add_array = undefined,
                };
            }

            const maybe_section = &@field(chunk_column.chunks[i].?, section_name);
            const section = if (@typeInfo(@TypeOf(maybe_section.*)) == .optional)
                &maybe_section.*.?
            else
                maybe_section;
            comptime std.debug.assert(@sizeOf(@TypeOf(section.*)) == 2048 or @sizeOf(@TypeOf(section.*)) == 4096);
            _ = try stream.readAll(@ptrCast(section));
        }
    }
}
