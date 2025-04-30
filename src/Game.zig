const std = @import("std");

const rl = @import("raylib");

const ChunkColumn = @import("ChunkColumn.zig");
const networking = @import("minecraft_protocol.zig");
const Packet = networking.Packet;

pub const std_options: std.Options = .{
    .log_scope_levels = &.{
        .{
            .scope = .minecraft_network,
            .level = .debug,
        },
    },
};

const Game = @This();

gpa: std.mem.Allocator,
mutex: std.Thread.Mutex,
position: [3]f64,
yaw: f32 = 0,
pitch: f32 = 0,
running: bool,
direction: rl.Vector3 = .{ .x = 1, .y = 0, .z = 0 },
messages: std.ArrayListUnmanaged([:0]const u8) = .empty,
chunks_pool: std.heap.MemoryPool(ChunkColumn),
chunks: std.AutoArrayHashMapUnmanaged(
    [2]i32,
    *ChunkColumn,
) = .empty,
full_arena: std.heap.ArenaAllocator,
players: std.AutoArrayHashMapUnmanaged(i32, struct {
    name: [:0]const u8,
    pos: rl.Vector3,
}) = .empty,

pub fn gameLoop(game: *Game) void {
    rl.initWindow(1920, 1080, "minecraft");
    defer rl.closeWindow();
    rl.hideCursor();
    defer rl.showCursor();

    while (!rl.windowShouldClose()) {
        {
            game.mutex.lock();
            defer game.mutex.unlock();

            game.yaw -=
                rl.getMouseDelta().x * 0.01;
            game.pitch -=
                rl.getMouseDelta().y * 0.01;
            game.pitch = std.math.clamp(game.pitch, -std.math.pi / 3.0, std.math.pi / 3.0);

            const quat = rl.math.quaternionMultiply(
                rl.math.quaternionFromEuler(0, game.yaw, 0),
                rl.math.quaternionFromEuler(0, 0, game.pitch),
            );
            game.direction = rl.math.vector3RotateByQuaternion(.{
                .x = 1,
                .y = 0,
                .z = 0,
            }, quat);
            std.log.debug("direciton vec {}", .{game.direction});
            const speed: f64 = if (rl.isKeyDown(.left_shift)) 100 else 10;

            const dx = game.direction.x * rl.getFrameTime() * speed;
            const dy = game.direction.y * rl.getFrameTime() * speed;
            const dz = game.direction.z * rl.getFrameTime() * speed;
            if (rl.isKeyDown(.w)) {
                game.position[0] += dx;
                game.position[1] += dy;
                game.position[2] += dz;
            }
            if (rl.isKeyDown(.s)) {
                game.position[0] -= dx;
                game.position[1] -= dy;
                game.position[2] -= dz;
            }
            if (rl.isKeyDown(.a)) {
                game.position[0] += dz;
                game.position[2] -= dx;
            }
            if (rl.isKeyDown(.d)) {
                game.position[0] -= dz;
                game.position[2] += dx;
            }
        }
        {
            rl.beginDrawing();
            defer rl.endDrawing();

            rl.clearBackground(.black);

            game.mutex.lock();
            defer game.mutex.unlock();

            for (game.messages.items, 0..) |message, index| {
                rl.drawText(message, 0, @intCast(index * 20), 20, .red);
            }

            const camera: rl.Camera3D = .{
                .fovy = 80,
                .projection = .perspective,
                .up = .{
                    .x = 0,
                    .y = 1,
                    .z = 0,
                },
                .target = .{
                    .x = @as(f32, @floatCast(game.position[0])) + game.direction.x,
                    .y = @as(f32, @floatCast(game.position[1])) + game.direction.y,
                    .z = @as(f32, @floatCast(game.position[2])) + game.direction.z,
                },
                .position = .{
                    .x = @floatCast(game.position[0]),
                    .y = @floatCast(game.position[1]),
                    .z = @floatCast(game.position[2]),
                },
            };
            {
                camera.begin();
                defer camera.end();

                rl.drawGrid(100, 10);
                var chunk_iter = game.chunks.iterator();
                var rendered: usize = 0;
                while (chunk_iter.next()) |chunk_column| {
                    const direction = (rl.Vector2{ .x = game.direction.x, .y = game.direction.z }).normalize();
                    const dx: f32 = @floatCast(@as(f64, @floatFromInt(chunk_column.key_ptr[0] * 16 + 8)) - game.position[0]);
                    const dz: f32 = @floatCast(@as(f64, @floatFromInt(chunk_column.key_ptr[1] * 16 + 8)) - game.position[2]);
                    const render_distance = 40;
                    const normed = (rl.Vector2{ .x = dx, .y = dz }).normalize();
                    if (normed.dotProduct(direction) < -0.5) continue;

                    if (dx * dx + dz * dz > render_distance * render_distance) continue;

                    for (&chunk_column.value_ptr.*.chunks, 0..) |*maybe_chunk, height| {
                        if (maybe_chunk.*) |*chunk| {
                            for (chunk.block_type, chunk.block_light, 0..) |y, light_y, yi| {
                                for (y, light_y, 0..) |z, light_z, zi| {
                                    for (z, 0..) |block_type, xi| {
                                        const light = if (xi % 2 == 0) light_z[xi / 2].@"0" else light_z[xi / 2].@"1";
                                        if (block_type == 0) continue;

                                        rl.drawCube(.{
                                            .x = @floatFromInt(chunk_column.key_ptr[0] * 16 + @as(i32, @intCast(xi))),
                                            .z = @floatFromInt(chunk_column.key_ptr[1] * 16 + @as(i32, @intCast(zi))),
                                            .y = @floatFromInt(height * 16 + yi),
                                        }, 1, 1, 1, .{
                                            .r = @intCast(@as(u8, light) * 16),
                                            .g = @intCast(block_type *% 123),
                                            .b = @intCast(block_type *% 181),
                                            .a = 255,
                                        });
                                    }
                                }
                            }
                        }
                    }
                    rendered += 1;
                }
                std.log.debug("rendered {d}", .{rendered});
            }
            {
                for (game.players.keys(), game.players.values()) |_, player| {
                    const rl_pos = rl.Vector3{
                        .x = player.pos.x,
                        .y = player.pos.y,
                        .z = player.pos.z,
                    };
                    {
                        camera.begin();
                        defer camera.end();
                        rl.drawSphere(rl_pos, 10, .blue);
                    }
                    const screen_pos = rl.getWorldToScreen(rl_pos, camera);

                    rl.drawText(
                        player.name,
                        @intFromFloat(screen_pos.x),
                        @intFromFloat(screen_pos.y),
                        30,
                        .red,
                    );
                }
            }
            rl.drawCircle(
                @divFloor(rl.getScreenWidth(), 2),
                @divFloor(rl.getScreenHeight(), 2),
                10,
                .red,
            );
            var buf: [0x10000]u8 = undefined;
            rl.drawText(
                std.fmt.bufPrintZ(&buf, "pos ({d:.02}, {d:.02}, {d:.02})", .{
                    game.position[0],
                    game.position[1],
                    game.position[2],
                }) catch unreachable,
                0,
                @divFloor(rl.getScreenHeight(), 2),
                30,
                .red,
            );
            rl.drawText(
                std.fmt.bufPrintZ(&buf, "direction ({d:.02}, {d:.02}, {d:.02})", .{
                    game.direction.x,
                    game.direction.y,
                    game.direction.z,
                }) catch unreachable,
                0,
                @divFloor(rl.getScreenHeight() + 120, 2),
                30,
                .red,
            );
        }
    }
    game.mutex.lock();
    defer game.mutex.unlock();
    game.running = false;
}

pub fn handshake(arena: std.mem.Allocator, game: *Game, stream: std.net.Stream, username: []const u8, ip: []const u8, port: u16) !void {
    try (Packet{ .Handshake = .{
        .protocol_version = 61,
        .username = .fromUtf8(username),
        .server_host = .fromUtf8(ip),
        .server_port = port,
    } }).write(stream.writer());

    {
        const packet = try Packet.read(stream.reader(), arena);
        std.debug.print("{s}", .{@tagName(packet)});
    }
    // Client Statuses (0xCD)
    try Packet.write(.{ .@"Client Statuses" = .{
        .payload = .innitial_spawn,
    } }, stream.writer());

    // Login Request (0x01)
    {
        const packet = try Packet.read(stream.reader(), arena);
        std.debug.print("{}", .{packet});
    }
    // Spawn Position (0x06)
    {
        const packet = try Packet.read(stream.reader(), arena);
        game.position[0] = @floatFromInt(packet.@"Spawn Position".x);
        game.position[1] = @floatFromInt(packet.@"Spawn Position".y);
        game.position[2] = @floatFromInt(packet.@"Spawn Position".z);
        std.debug.print("pos {}", .{packet.@"Spawn Position"});
    }
}

pub fn runClient(gpa: std.mem.Allocator, game: *Game, ip: []const u8, port: u16) void {
    errdefer |e| {
        std.log.err("Networking thread failed with {s}", .{@errorName(e)});
        // std.debug.dumpStackTrace(@errorReturnTrace().?.*);
        std.process.exit(1);
    }

    var packet_arena = std.heap.ArenaAllocator.init(gpa);
    defer _ = packet_arena.deinit();

    const address = try std.net.Address.parseIp4(ip, port);
    const stream = try std.net.tcpConnectToAddress(address);
    defer stream.close();

    std.log.info("Connected to server", .{});
    try handshake(packet_arena.allocator(), game, stream, "Andrew", ip, port);

    // const Timer = struct {

    //     pub fn check(t: *Timer) bool {}
    // };

    // var send_pos_time:
    //             try Packet.write(.{ .@"Player Position and Look" = .{
    //                 .x = player.pos.x * 32,
    //                 .y = player.pos.y * 32,
    //                 .z = player.pos.z * 32,
    //                 .on_ground = true,
    //                 .stance = 1,
    //                 .yaw = if (@hasField(@TypeOf(p), "yaw")) (@as(f32, @floatFromInt(p.yaw)) / 256) - 0.5 else game.yaw,
    //                 .pitch = if (@hasField(@TypeOf(p), "yaw")) (@as(f32, @floatFromInt(p.pitch)) / 256) - 0.5 else game.pitch,
    //             } }, stream.writer());

    while (blk: {
        game.mutex.lock();
        defer game.mutex.unlock();
        break :blk game.running;
    }) {
        _ = packet_arena.reset(.retain_capacity);
        const packet = try Packet.read(
            stream.reader(),
            packet_arena.allocator(),
        );
        game.mutex.lock();
        defer game.mutex.unlock();

        switch (packet) {
            .@"Spawn Named Entity" => |p| {
                try game.players.put(game.gpa, p.entity_id, .{
                    .name = try game.full_arena.allocator().dupeZ(u8, p.player_name.utf8),
                    .pos = .{
                        .x = (@as(f32, @floatFromInt(p.x))) / 32.0,
                        .y = (@as(f32, @floatFromInt(p.y))) / 32.0,
                        .z = (@as(f32, @floatFromInt(p.z))) / 32.0,
                    },
                });
            },
            inline .@"Entity Look and Relative Move", .@"Entity Relative Move" => |p| blk: {
                const player = game.players.getPtr(p.entity_id) orelse break :blk;

                player.pos.x += @as(f32, @floatFromInt(p.dx)) / 32.0;
                player.pos.y += @as(f32, @floatFromInt(p.dy)) / 32.0;
                player.pos.z += @as(f32, @floatFromInt(p.dz)) / 32.0;

                // game.position[0] = @floatCast(player.pos.x);
                // game.position[1] = @floatCast(player.pos.y);
                // game.position[2] = @floatCast(player.pos.z);

                std.debug.print(
                    "moved player {s} {any}\n",
                    .{ player.name, player.pos },
                );
            },
            .@"Entity Teleport" => |p| blk: {
                const player = game.players.getPtr(p.entity_id) orelse break :blk;
                player.pos = .{
                    .x = (@as(f32, @floatFromInt(p.x))),
                    .y = (@as(f32, @floatFromInt(p.y))),
                    .z = (@as(f32, @floatFromInt(p.z))),
                };
                std.debug.print(
                    "moved player {s} {any}\n",
                    .{ player.name, player.pos },
                );
            },
            .@"Keep Alive" => {
                try packet.write(stream.writer());
            },
            .@"Chat Message" => |m| {
                try game.messages.append(
                    game.full_arena.allocator(),
                    try game.full_arena.allocator().dupeZ(u8, m.message.utf8),
                );
            },
            inline .@"Player Position", .@"Player Position and Look", .@"Player Look", .Player => |p| {
                if (@hasField(@TypeOf(p), "x")) {
                    game.position = .{ p.x, p.y, p.z };
                }

                if (@hasField(@TypeOf(p), "yaw")) game.yaw = p.yaw;
                if (@hasField(@TypeOf(p), "pitch")) game.pitch = p.pitch;

                std.debug.print(
                    "update position {any}\n",
                    .{game.position},
                );
            },
            .@"Map Chunk Bulk" => |mcb| {
                var reader = std.io.fixedBufferStream(mcb.data);
                var dcm_buf: [1000 * 1024]u8 = undefined;
                var writer = std.io.fixedBufferStream(&dcm_buf);
                try std.compress.zlib.decompress(reader.reader(), writer.writer());
                var fbr = std.io.fixedBufferStream(&dcm_buf);
                for (mcb.chunk_column) |chunk_column_meta| {
                    const chunk_column = try game.chunks_pool.create();
                    try game.chunks.put(
                        game.gpa,
                        .{
                            chunk_column_meta.chunk_x,
                            chunk_column_meta.chunk_z,
                        },
                        chunk_column,
                    );
                    try ChunkColumn.parse(
                        chunk_column,
                        fbr.reader(),
                        chunk_column_meta.primary_bitmap,
                        chunk_column_meta.add_bitmap,
                        mcb.sky_light_sent,
                        true,
                    );
                }
            },
            else => |p| {
                std.log.debug("{s}", .{@tagName(p)});
            },
        }
    }
}

pub fn deinit(game: *Game) void {
    game.mutex.lock();
    defer game.mutex.unlock();
    game.chunks_pool.deinit();
    game.chunks.deinit(game.gpa);
    game.full_arena.deinit();
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

    var game: Game = .{
        .gpa = gpa.allocator(),
        .mutex = .{},
        .position = undefined,
        .running = true,
        .chunks_pool = .init(gpa.allocator()),
        .full_arena = .init(gpa.allocator()),
    };
    defer game.deinit();

    const thread = try std.Thread.spawn(.{}, runClient, .{
        gpa.allocator(),
        &game,
        ip,
        port,
    });
    game.gameLoop();
    defer thread.join();
}

fn fail(comptime fmt: []const u8, args: anytype) noreturn {
    std.log.err(fmt, args);
    std.process.exit(1);
}
