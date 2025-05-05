const std = @import("std");
const Mutex = std.Thread.Mutex;

const ig = @import("imgui");
const sokol = @import("sokol");
const sg = sokol.gfx;
const sapp = sokol.app;
const sglue = sokol.glue;
const slog = sokol.log;
const simgui = sokol.imgui;
const Sokol2d = @import("sokol_2d");

const ChunkColumn = @import("ChunkColumn.zig");
const networking = @import("minecraft_protocol.zig");
const Packet = networking.Packet;
const Renderer = @import("Renderer.zig");
const Timer = @import("Timer.zig");
const World = @import("World.zig");
const Input = @import("Input.zig");

pub const std_options: std.Options = .{
    .log_scope_levels = &.{
        .{
            .scope = .minecraft_protocol,
            .level = .err,
        },
    },
};

const Game = @This();

gpa: std.heap.GeneralPurposeAllocator(.{}),

world_mutex: Mutex,
world: ?World,
network_thread: std.Thread,

running: bool,

graphics: Graphics,
renderer: Renderer,

ui_imgui: UiImgui,
events: Events,

input: Input,

const Graphics = struct {
    clear_action: sg.PassAction,
    load_action: sg.PassAction,
    sokol_2d: Sokol2d,
};

const Events = std.ArrayListUnmanaged(World.Event);

fn sokolInit(user_data: ?*anyopaque) callconv(.c) void {
    const state: *@This() = @ptrCast(@alignCast(user_data));

    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .init;

    // initialize sokol-gfx
    sg.setup(.{
        .environment = sglue.environment(),
        .logger = .{ .func = slog.func },
    });
    // initialize sokol-imgui
    simgui.setup(.{
        .logger = .{ .func = slog.func },
    });
    // initial clear color

    const sokol2d = Sokol2d.init(gpa.allocator()) catch @panic("OOM");

    state.* = .{
        .input = .init,
        .network_thread = undefined,
        .running = true,
        .graphics = .{
            .sokol_2d = sokol2d,
            .clear_action = .{},
            .load_action = .{},
        },
        .renderer = try .init(),
        .gpa = gpa,
        .ui_imgui = .init,
        .world_mutex = .{},
        .world = null,
        .events = .empty,
    };
    state.graphics.clear_action.colors[0] = .{
        .load_action = .CLEAR,
        .clear_value = .{ .r = 0, .g = 0, .b = 0, .a = 1.0 },
    };
    state.graphics.load_action.colors[0] = .{
        .load_action = .LOAD,
    };
}

const UiImgui = struct {
    user_name: [100:0]u8 = ("andrew" ++ "\x00" ** (100 - 6)).*,
    ip_buffer: ["255.255.255.255".len:0]u8 = ("31.56.39.199" ++ "\x00\x00\x00").*,
    port: u16 = 25565,

    send_message: [100:0]u8 = @splat(0),

    const init: UiImgui = .{};
};

fn update(state: *@This()) void {
    if (state.world) |*world| {
        world.tick(state.events.items, 1.0 / 60.0);
        state.events.clearRetainingCapacity();
    }
}

fn sokolFrame(user_data: ?*anyopaque) callconv(.c) void {
    const state: *@This() = @ptrCast(@alignCast(user_data));
    defer state.input.newFrame();

    state.world_mutex.lock();
    defer state.world_mutex.unlock();

    state.events.append(state.gpa.allocator(), .{
        .player_look_relative = .{
            .yaw = state.input.mouse_delta[0] / 100,
            .pitch = state.input.mouse_delta[1] / 100,
        },
    }) catch @panic("OOM");

    inline for ([_]Input.Keycode{ .W, .A, .S, .D, .LEFT_SHIFT, .LEFT_CONTROL }) |key| {
        if (state.input.isKeyDown(key)) {
            state.events.append(state.gpa.allocator(), .{
                .player_move = switch (key) {
                    .W => .{ 0, 0, 1 },
                    .A => .{ 1, 0, 0 },
                    .S => .{ 0, 0, -1 },
                    .D => .{ -1, 0, 0 },
                    .LEFT_SHIFT => .{ 0, -1, 0 },
                    .LEFT_CONTROL => .{ 0, 1, 0 },
                    else => comptime unreachable,
                },
            }) catch @panic("OOM");
        }
    }

    state.update();

    if (state.world) |*world| {
        if (world.chunks.count() > World.chunks_height * 8 * 8) {
            clearScreen(&state.graphics);
            state.renderer.renderWorld(world, state.graphics.load_action);
        } else {
            drawLoadingScreen(&state.graphics, world);
        }
    }

    { //=== UI CODE STARTS HERE
        simgui.newFrame(.{
            .width = sapp.width(),
            .height = sapp.height(),
            .delta_time = sapp.frameDuration(),
            .dpi_scale = sapp.dpiScale(),
        });
        if (state.world) |*world| {
            renderChat(&world.chat, &state.ui_imgui);
        } else {
            _ = ig.igInputText("Username", &state.ui_imgui.user_name, state.ui_imgui.user_name.len, 0);
            _ = ig.igInputText("Server IP", &state.ui_imgui.ip_buffer, state.ui_imgui.ip_buffer.len, 0);
            {
                var int: c_int = state.ui_imgui.port;
                _ = ig.igInputInt("Port", &int);
                state.ui_imgui.port = std.math.lossyCast(u16, int);
            }

            if (ig.igButton("Connect")) connect: {
                const ip = std.mem.span(@as([*:0]const u8, &state.ui_imgui.ip_buffer));
                const username = std.mem.span(@as([*:0]const u8, &state.ui_imgui.user_name));
                const port = state.ui_imgui.port;

                const address = std.net.Address.parseIp4(ip, port) catch |e| {
                    std.log.err("Failed to parse address: {s}", .{@errorName(e)});
                    break :connect;
                };
                const stream = std.net.tcpConnectToAddress(address) catch |e| {
                    std.log.err("Failed to handshake with server: {s}", .{@errorName(e)});
                    break :connect;
                };
                const world = worldHandshake(
                    state.gpa.allocator(),
                    stream,
                    username,
                    ip,
                    port,
                ) catch fail("Failed to connect", .{});
                state.world = world;

                state.network_thread = std.Thread.spawn(.{}, networkThread, .{
                    state.gpa.allocator(),
                    stream,
                    &state.world_mutex,
                    &state.world.?,
                    &state.events,
                }) catch @panic("can't spawn thread");
            }
        }
        sg.beginPass(.{ .action = state.graphics.load_action, .swapchain = sglue.swapchain() });
        simgui.render();
        sg.endPass();
        sg.commit();
    } //=== UI CODE ENDS HERE
}

fn drawLoadingScreen(graphics: *Graphics, world: *const World) void {
    const width: f32 = sokol.app.widthf();
    const height: f32 = sokol.app.heightf();

    graphics.sokol_2d.begin(.{
        .viewport = .{
            .start = .zero,
            .end = .{
                .x = width,
                .y = height,
            },
        },
        .coordinates = .{
            .start = .{
                .x = -width / 2,
                .y = -height / 2,
            },
            .end = .{
                .x = width / 2,
                .y = height / 2,
            },
        },
    });

    const spawn_x, _, const spawn_z = world.player().position;
    graphics.sokol_2d.drawRect(
        .fromCenterSize(.{ .x = 0, .y = 0 }, .{
            .x = World.render_distance * World.Chunk.size,
            .y = World.render_distance * World.Chunk.size,
        }),
        .gray,
    );

    for (world.chunks.keys()) |pos| {
        const x: f32 = @floatFromInt(pos.x);
        const y: f32 = @floatFromInt(pos.z);
        const square_size = 10;

        graphics.sokol_2d.drawRect(
            .fromCenterSize(
                .{
                    .x = (x - spawn_x / World.Chunk.size) * square_size,
                    .y = (y - spawn_z / World.Chunk.size) * square_size,
                },
                .{ .x = square_size, .y = square_size },
            ),
            .white,
        );
    }

    {
        sokol.gfx.beginPass(.{
            .action = graphics.clear_action,
            .swapchain = sokol.glue.swapchain(),
        });
        defer sokol.gfx.endPass();

        graphics.sokol_2d.flush();
    }
    sokol.gfx.commit();
}

fn clearScreen(graphics: *Graphics) void {
    sokol.gfx.beginPass(.{
        .action = graphics.clear_action,
        .swapchain = sokol.glue.swapchain(),
    });
    sokol.gfx.endPass();
    sokol.gfx.commit();
}

fn renderChat(chat: *World.Chat, ui: *UiImgui) void {
    var open = true;
    _ = ig.igSetNextWindowContentSize(.{
        .x = 300,
        .y = 300,
    });
    _ = ig.igBegin("Chat", &open, 0);
    defer _ = ig.igEnd();
    for (chat.messages.items, 0..) |message, index| {
        const is_last = index + 1 == chat.messages.items.len;
        if (!is_last and message.origin == .client) continue;

        var buffer: [message.bytes.buffer.len + 1]u8 = undefined;
        @memcpy(buffer[0..message.bytes.slice().len], message.bytes.slice());
        buffer[message.bytes.slice().len] = 0;

        const red: ig.ImVec4 = .{
            .x = 1,
            .y = 0,
            .z = 0,
            .w = 1,
        };
        const white: ig.ImVec4 = .{
            .x = 1,
            .y = 1,
            .z = 1,
            .w = 1,
        };
        const color: ig.ImVec4, const skip: usize = color: {
            if (message.bytes.slice().len >= 3) {
                if (@import("ChatColor.zig").parse(buffer[1..][0..2].*)) |color| {
                    break :color .{ .{
                        .x = @as(f32, @floatFromInt(color[0])) / 255,
                        .y = @as(f32, @floatFromInt(color[1])) / 255,
                        .z = @as(f32, @floatFromInt(color[2])) / 255,
                        .w = 1,
                    }, 3 };
                }
            }
            break :color .{ switch (message.origin) {
                .client => red,
                .server => white,
            }, 0 };
        };

        ig.igTextColored(color, "%s", buffer[skip..message.bytes.slice().len :0].ptr);
    }

    _ = ig.igInputText("Input", &ui.send_message, ui.send_message.len, 0);
    if (ig.igButton("Send")) {
        _ = chat.send(std.mem.span(@as([*:0]const u8, ui.send_message[0.. :0])), .client);
    }
}

fn sokolEvent(ev: [*c]const sapp.Event, user_data: ?*anyopaque) callconv(.c) void {
    const state: *@This() = @ptrCast(@alignCast(user_data));

    const event = ev.?.*;
    if (simgui.handleEvent(event)) return;

    state.input.consumeEvent(ev.?);

    state.world_mutex.lock();
    defer state.world_mutex.unlock();

    switch (event.type) {
        .MOUSE_MOVE => {},
        .KEY_DOWN => switch (event.key_code) {
            .ESCAPE => {
                state.running = false;
                sapp.requestQuit();
            },
            else => {},
        },
        else => |t| {
            std.log.debug("unhandled {s}", .{@tagName(t)});
        },
    }
}

fn sokolCleanup(user_data: ?*anyopaque) callconv(.c) void {
    const state: *@This() = @ptrCast(@alignCast(user_data));

    state.graphics.sokol_2d.deinit(state.gpa.allocator());
    if (state.world) |*world| {
        world.deinit(state.gpa.allocator());
    }
}

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();

    var state: @This() = undefined;

    sapp.run(.{
        .user_data = &state,
        .init_userdata_cb = &sokolInit,
        .event_userdata_cb = &sokolEvent,
        .frame_userdata_cb = &sokolFrame,
        .cleanup_userdata_cb = &sokolCleanup,
    });
}

fn fail(comptime fmt: []const u8, args: anytype) noreturn {
    std.log.err(fmt, args);
    std.process.exit(1);
}

pub fn networkThread(
    gpa: std.mem.Allocator,
    stream: std.net.Stream,
    mutex: *Mutex,
    world: *World,
    events: *Events,
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

    while (true) {
        {
            mutex.lock();
            defer mutex.unlock();

            if (world.chat.messages.getLastOrNull()) |last| {
                if (last.id != last_message_id) {
                    try networking.write(.{
                        .@"Chat Message" = .{
                            .message = .fromUtf8(last.bytes.slice()),
                        },
                    }, stream.writer());
                    last_message_id = last.id;
                }
            }
        }
        const player_pos = player_pos: {
            mutex.lock();
            defer mutex.unlock();

            break :player_pos world.player().position;
        };
        inline for (@typeInfo(@TypeOf(timers)).@"struct".fields) |field| {
            if (@field(timers, field.name).justFinished()) {
                const timer = @field(std.meta.FieldEnum(@TypeOf(timers)), field.name);
                switch (timer) {
                    .send_position => {
                        try networking.write(.{
                            .@"Player Position" = .{
                                .x = player_pos[0],
                                .y = player_pos[1],
                                .z = player_pos[2],
                                .stance = player_pos[1] + 1.6,
                                .on_ground = true,
                            },
                        }, stream.writer());
                    },
                }
            }
        }

        const packet = try networking.read(stream.reader(), packet_arena.allocator());
        switch (packet) {
            // send same back
            .@"Keep Alive" => try networking.write(networking.changeDirection(packet), stream.writer()),
            .@"Chat Message" => |chat| {
                mutex.lock();
                defer mutex.unlock();

                last_message_id = world.chat.send(chat.message.utf8, .server);
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
                            }, .{ .block_type = chunk.block_type });
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
                            .y = @intCast(y * 16),
                            .z = cd.z,
                        }, .{ .block_type = chunk.block_type });
                    }
                }
            },
            else => {
                // std.log.debug("got packet {s}", .{@tagName(packet)});
            },
        }

        // switch (packet) {
        //     inline .@"Entity Look and Relative Move", .@"Entity Relative Move" => |p| blk: {
        //         const player = game.players.getPtr(p.entity_id) orelse break :blk;

        //         player.pos.x += @as(f32, @floatFromInt(p.dx)) / 32.0;
        //         player.pos.y += @as(f32, @floatFromInt(p.dy)) / 32.0;
        //         player.pos.z += @as(f32, @floatFromInt(p.dz)) / 32.0;

        //         // game.position[0] = @floatCast(player.pos.x);
        //         // game.position[1] = @floatCast(player.pos.y);
        //         // game.position[2] = @floatCast(player.pos.z);

        //         std.debug.print(
        //             "moved player {s} {any}\n",
        //             .{ player.name, player.pos },
        //         );
        //     },
        //     .@"Entity Teleport" => |p| blk: {
        //         const player = game.players.getPtr(p.entity_id) orelse break :blk;
        //         player.pos = .{
        //             .x = (@as(f32, @floatFromInt(p.x))),
        //             .y = (@as(f32, @floatFromInt(p.y))),
        //             .z = (@as(f32, @floatFromInt(p.z))),
        //         };
        //         std.debug.print(
        //             "moved player {s} {any}\n",
        //             .{ player.name, player.pos },
        //         );
        //     },
        //     inline .@"Player Position", .@"Player Position and Look", .@"Player Look", .Player => |p| {
        //         if (@hasField(@TypeOf(p), "x")) {
        //             game.position = .{ p.x, p.y, p.z };
        //         }

        //         if (@hasField(@TypeOf(p), "yaw")) game.yaw = p.yaw;
        //         if (@hasField(@TypeOf(p), "pitch")) game.pitch = p.pitch;

        //         std.debug.print(
        //             "update position {any}\n",
        //             .{game.position},
        //         );
        //     },
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

    try networking.write(
        .{ .Handshake = .{
            .protocol_version = 61,
            .username = .fromUtf8(username),
            .server_host = .fromUtf8(ip),
            .server_port = port,
        } },
        stream.writer(),
    );

    _ = try networking.readExpectedPacket(
        stream.reader(),
        connect_arena.allocator(),
        .@"Encryption Key Request",
    );

    // Client Statuses (0xCD)
    try networking.write(.{ .@"Client Statuses" = .{
        .payload = .innitial_spawn,
    } }, stream.writer());

    // Login Request (0x01)
    const login_request = try networking.readExpectedPacket(
        stream.reader(),
        connect_arena.allocator(),
        .@"Login Request",
    );
    std.debug.print("{}", .{login_request});

    // Spawn Position (0x06)
    const spawn_position: [3]f32 = blk: {
        const spawn_pos = try networking.readExpectedPacket(
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
