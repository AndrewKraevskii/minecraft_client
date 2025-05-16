const std = @import("std");
const Mutex = std.Thread.Mutex;
const World = @import("World.zig");
const Timer = @import("Timer.zig");
const protocol = @import("minecraft_protocol.zig");
const ChunkColumn = @import("ChunkColumn.zig");

pub fn networkThread(
    gpa: std.mem.Allocator,
    running: *std.atomic.Value(bool),
    stream: std.net.Stream,
    password: []const u8,
    mutex: *Mutex,
    world: *World,
    events: *std.ArrayListUnmanaged(World.Event),
) void {
    errdefer |e| {
        std.log.err("Networking thread failed with {s}", .{@errorName(e)});
        std.process.exit(1);
    }

    var packet_arena = std.heap.ArenaAllocator.init(gpa);
    defer _ = packet_arena.deinit();

    std.log.info("Connected to server", .{});

    const ms = std.time.ns_per_ms;

    var timers: struct {
        send_position: Timer,
    } = .{
        .send_position = .start(50 * ms, true),
    };

    var last_message_id: World.Chat.Message.Id = .none;

    while (running.load(.acquire)) {
        {
            mutex.lock();
            defer mutex.unlock();

            if (world.chat.messages.getLastOrNull()) |last| {
                if (last.id != last_message_id) {
                    try protocol.write(.{
                        .@"Chat Message" = .{
                            .message = .fromUtf8(last.bytes.slice()),
                        },
                    }, stream.writer());
                    last_message_id = last.id;
                }
            }
        }
        const player = player_pos: {
            mutex.lock();
            defer mutex.unlock();

            break :player_pos world.player();
        };
        inline for (@typeInfo(@TypeOf(timers)).@"struct".fields) |field| {
            if (@field(timers, field.name).justFinished()) {
                const timer = @field(std.meta.FieldEnum(@TypeOf(timers)), field.name);
                switch (timer) {
                    .send_position => {
                        std.log.debug(
                            \\sending position
                            \\ yaw       = {[yaw]d:.02}
                            \\ pitch     = {[pitch]d:.02}
                            \\ x         = {[x]d:.02}
                            \\ y         = {[y]d:.02}
                            \\ z         = {[z]d:.02}
                            \\ stance    = {[stance]d:.02}
                            \\ on_ground = {[on_ground]}
                        , .{
                            .yaw = player.yaw,
                            .pitch = player.pitch,
                            .x = player.position[0],
                            .y = player.position[1],
                            .z = player.position[2],
                            .stance = player.stance,
                            .on_ground = player.on_ground,
                        });
                        try protocol.write(.{
                            .@"Player Position and Look" = .{
                                .yaw = player.yaw,
                                .pitch = player.pitch,
                                .x = player.position[0],
                                .y = player.position[1],
                                .z = player.position[2],
                                .stance = player.stance,
                                .on_ground = player.on_ground,
                            },
                        }, stream.writer());
                    },
                }
            }
        }

        const packet = try protocol.read(stream.reader(), packet_arena.allocator());
        switch (packet) {
            // send same packet back
            .@"Keep Alive" => try protocol.write(protocol.changeDirection(packet), stream.writer()),
            .@"Chat Message" => |chat| {
                mutex.lock();
                defer mutex.unlock();

                last_message_id = world.chat.send(chat.message.utf8, .server);

                if (std.mem.containsAtLeast(u8, chat.message.utf8, 1, "Please login with \"")) {
                    var buffer: [World.max_message_len]u8 = undefined;
                    _ = world.chat.send(std.fmt.bufPrint(&buffer, "/login {s}", .{password}) catch buffer[0..], .client);
                }
            },
            .@"Spawn Named Entity" => |sp| {
                mutex.lock();
                defer mutex.unlock();
                try events.append(gpa, .{
                    .spawn_player = .{
                        .id = @enumFromInt(sp.entity_id),
                        .name = try .fromSlice(sp.player_name.utf8),
                        .position = .{
                            @floatFromInt(sp.x),
                            @floatFromInt(sp.y),
                            @floatFromInt(sp.z),
                        },
                    },
                });
            },
            .@"Map Chunk Bulk" => |mcb| {
                var reader = std.io.fixedBufferStream(mcb.data);
                var dcm_buf: [1000 * 1024]u8 = undefined;
                var writer = std.io.fixedBufferStream(&dcm_buf);
                try std.compress.zlib.decompress(reader.reader(), writer.writer());
                var fbr = std.io.fixedBufferStream(&dcm_buf);
                for (mcb.chunk_column) |chunk_column_meta| {
                    const chunk_column = try ChunkColumn.parse(
                        fbr.reader(),
                        chunk_column_meta.primary_bitmap,
                        chunk_column_meta.add_bitmap,
                        mcb.sky_light_sent,
                        true,
                    );
                    mutex.lock();
                    defer mutex.unlock();
                    for (chunk_column.chunks, 0..) |maybe_chunks, y| {
                        if (maybe_chunks) |chunk| {
                            world.loadChunk(.{
                                .x = chunk_column_meta.chunk_x,
                                .y = @intCast(y),
                                .z = chunk_column_meta.chunk_z,
                            }, .{ .block_type = @bitCast(chunk.block_type) });
                        }
                    }
                }
            },
            .@"Chunk Data" => |cd| {
                var reader = std.io.fixedBufferStream(cd.data);
                var dcm_buf: [1000 * 1024]u8 = undefined;
                var writer = std.io.fixedBufferStream(&dcm_buf);
                try std.compress.zlib.decompress(reader.reader(), writer.writer());
                var fbr = std.io.fixedBufferStream(&dcm_buf);
                const chunk_column = try ChunkColumn.parse(
                    fbr.reader(),
                    cd.primary_bitmap,
                    cd.add_bitmap,
                    true,
                    cd.ground_up_continuous,
                );
                mutex.lock();
                defer mutex.unlock();
                for (chunk_column.chunks, 0..) |maybe_chunks, y| {
                    if (maybe_chunks) |chunk| {
                        world.loadChunk(.{
                            .x = cd.x,
                            .y = @intCast(y),
                            .z = cd.z,
                        }, .{ .block_type = @bitCast(chunk.block_type) });
                    }
                }
            },
            .@"Time Update", .@"Player List Item", .@"Update Tile Entity" => {},
            inline .@"Entity Head Look", .@"Entity Look", .@"Entity Relative Move", .@"Entity Look and Relative Move", .@"Entity Status", .@"Entity Teleport", .@"Entity Velocity" => |e| {
                std.debug.assert(e.entity_id != @intFromEnum(player.id));
            },
            .@"Player Position and Look" => |pl| {
                std.log.debug(
                    \\💥💥💥💥💥💥💥💥💥💥server updated our position
                    \\ yaw       = {[yaw]d:.02}
                    \\ pitch     = {[pitch]d:.02}
                    \\ x         = {[x]d:.02}
                    \\ y         = {[y]d:.02}
                    \\ z         = {[z]d:.02}
                    \\ stance    = {[stance]d:.02}
                    \\ on_ground = {[on_ground]}
                , .{
                    .yaw = pl.yaw,
                    .pitch = pl.pitch,
                    .x = pl.x,
                    .y = pl.y,
                    .z = pl.z,
                    .stance = pl.stance,
                    .on_ground = pl.on_ground,
                });

                try protocol.write(protocol.changeDirection(packet), stream.writer());
                const new_player: World.Player = .{
                    .on_ground = pl.on_ground,
                    .id = player.id,
                    .name = player.name,
                    .pitch = pl.pitch,
                    .position = .{ @floatCast(pl.x), @floatCast(pl.y), @floatCast(pl.z) },
                    .stance = @floatCast(pl.stance),
                    .velocity = player.velocity,
                    .yaw = pl.yaw,
                };
                mutex.lock();
                defer mutex.unlock();
                world.playerPtr().* = new_player;
            },
            else => {
                std.log.debug("got packet {s}", .{@tagName(packet)});
            },
        }
    }
}

pub fn worldHandshake(
    gpa: std.mem.Allocator,
    stream: std.net.Stream,
    username: []const u8,
    ip: []const u8,
    port: u16,
) !World {
    var connect_arena = std.heap.ArenaAllocator.init(gpa);
    defer connect_arena.deinit();

    try protocol.write(
        .{ .Handshake = .{
            .protocol_version = 61,
            .username = .fromUtf8(username),
            .server_host = .fromUtf8(ip),
            .server_port = port,
        } },
        stream.writer(),
    );

    _ = try protocol.readExpectedPacket(
        stream.reader(),
        connect_arena.allocator(),
        .@"Encryption Key Request",
    );

    // Client Statuses (0xCD)
    try protocol.write(.{ .@"Client Statuses" = .{
        .payload = .innitial_spawn,
    } }, stream.writer());

    // Login Request (0x01)
    const login_request = try protocol.readExpectedPacket(
        stream.reader(),
        connect_arena.allocator(),
        .@"Login Request",
    );
    std.debug.print("{}", .{login_request});

    // Spawn Position (0x06)
    const spawn_position: [3]f32 = blk: {
        const spawn_pos = try protocol.readExpectedPacket(
            stream.reader(),
            connect_arena.allocator(),
            .@"Spawn Position",
        );

        break :blk .{
            @floatFromInt(spawn_pos.x),
            @floatFromInt(spawn_pos.y),
            @floatFromInt(spawn_pos.z),
        };
    };

    return World.init(
        gpa,
        username,
        spawn_position,
        @enumFromInt(login_request.player_id),
    );
}
