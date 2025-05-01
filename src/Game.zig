const std = @import("std");
const Mutex = std.Thread.Mutex;

const ig = @import("imgui");
const sokol = @import("sokol");
const sg = sokol.gfx;
const sapp = sokol.app;
const sglue = sokol.glue;
const slog = sokol.log;
const simgui = sokol.imgui;

const ChunkColumn = @import("ChunkColumn.zig");
const networking = @import("minecraft_protocol.zig");
const Packet = networking.Packet;
const Timer = @import("Timer.zig");
const World = @import("World.zig");

pub const std_options: std.Options = .{
    .log_scope_levels = &.{
        .{
            .scope = .minecraft_network,
            .level = .debug,
        },
    },
};

const Game = @This();

gpa: std.heap.GeneralPurposeAllocator(.{}),

world_mutex: Mutex,
world: ?World,
network_thread: std.Thread,

running: bool,
pass_action: sg.PassAction,

ui_imgui: UiImgui,

fn sokolInit(user_data: ?*anyopaque) callconv(.c) void {
    const state: *@This() = @ptrCast(@alignCast(user_data));

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

    state.* = .{
        .network_thread = undefined,
        .running = true,
        .pass_action = .{},
        .gpa = .init,
        .ui_imgui = .init,
        .world_mutex = .{},
        .world = null,
    };

    state.pass_action.colors[0] = .{
        .load_action = .CLEAR,
        .clear_value = .{ .r = 0.0, .g = 0.5, .b = 1.0, .a = 1.0 },
    };
}

const UiImgui = struct {
    user_name: [100:0]u8 = ("andrew" ++ "\x00" ** (100 - 6)).*,
    ip_buffer: ["255.255.255.255".len:0]u8 = ("144.76.153.125" ++ "\x00").*,
    port: u16 = 25633,

    const init: UiImgui = .{};
};

fn update(state: *@This()) void {
    if (state.world) |*world| {
        world.update(1.0 / 60.0);
    }
}

fn sokolFrame(user_data: ?*anyopaque) callconv(.c) void {
    const state: *@This() = @ptrCast(@alignCast(user_data));

    state.update();

    { //=== UI CODE STARTS HERE
        simgui.newFrame(.{
            .width = sapp.width(),
            .height = sapp.height(),
            .delta_time = sapp.frameDuration(),
            .dpi_scale = sapp.dpiScale(),
        });
        if (state.world) |*world| {
            for (0..world.chat.messages.count) |message_index| {
                const message = world.chat.messages.peekItem(message_index);
                var buffer: [message.buffer.len + 1]u8 = undefined;
                @memcpy(buffer[0..message.slice().len], message.slice());
                buffer[message.slice().len] = 0;
                ig.igText("%s", buffer[0..message.slice().len :0].ptr);
            }
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
                }) catch @panic("can't spawn thread");
            }
        }
        sg.beginPass(.{ .action = state.pass_action, .swapchain = sglue.swapchain() });
        simgui.render();
        sg.endPass();
        sg.commit();
    } //=== UI CODE ENDS HERE
}

fn sokolEvent(ev: [*c]const sapp.Event, user_data: ?*anyopaque) callconv(.c) void {
    const state: *@This() = @ptrCast(@alignCast(user_data));

    const event = ev.?.*;
    if (simgui.handleEvent(event)) return;

    switch (event.type) {
        .MOUSE_MOVE => {},
        .KEY_DOWN => switch (event.key_code) {
            inline .W, .A, .S, .D => |key| {
                if (state.world) |*world| {
                    world.addEvent(.{ .player_move = switch (key) {
                        .W => .{ 1, 0, 0 },
                        .A => .{ 0, -1, 0 },
                        .S => .{ -1, 0, 0 },
                        .D => .{ 0, 1, 0 },
                        .LEFT_SHIFT => .{ 0, 1, 0 },
                        .LEFT_CONTROL => .{ 0, -1, 0 },
                        else => comptime unreachable,
                    } });
                }
            },
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

    while (true) {
        mutex.lock();
        defer mutex.unlock();

        inline for (@typeInfo(@TypeOf(timers)).@"struct".fields) |field| {
            if (@field(timers, field.name).justFinished()) {
                const timer = @field(std.meta.FieldEnum(@TypeOf(timers)), field.name);
                switch (timer) {
                    .send_position => {
                        try networking.write(.{
                            .@"Player Position" = .{
                                .x = world.player.position[0],
                                .y = world.player.position[1],
                                .z = world.player.position[2],
                                .stance = world.player.position[1] + 1.6,
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
            .@"Keep Alive" => try networking.write(packet, stream.writer()),
            .@"Chat Message" => |chat| {
                world.chat.send(chat.message.utf8);
            },
            else => {
                std.log.debug("got packet {s}", .{@tagName(packet)});
            },
        }

        // switch (packet) {
        //     .@"Spawn Named Entity" => |p| {
        //         try game.players.put(game.gpa, p.entity_id, .{
        //             .name = try game.full_arena.allocator().dupeZ(u8, p.player_name.utf8),
        //             .pos = .{
        //                 .x = (@as(f32, @floatFromInt(p.x))) / 32.0,
        //                 .y = (@as(f32, @floatFromInt(p.y))) / 32.0,
        //                 .z = (@as(f32, @floatFromInt(p.z))) / 32.0,
        //             },
        //         });
        //     },
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
        //     .@"Chat Message" => |m| {
        //         try game.messages.append(
        //             game.full_arena.allocator(),
        //             try game.full_arena.allocator().dupeZ(u8, m.message.utf8),
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
        //     .@"Map Chunk Bulk" => |mcb| {
        //         var reader = std.io.fixedBufferStream(mcb.data);
        //         var dcm_buf: [1000 * 1024]u8 = undefined;
        //         var writer = std.io.fixedBufferStream(&dcm_buf);
        //         try std.compress.zlib.decompress(reader.reader(), writer.writer());
        //         var fbr = std.io.fixedBufferStream(&dcm_buf);
        //         for (mcb.chunk_column) |chunk_column_meta| {
        //             const chunk_column = try game.chunks_pool.create();
        //             try game.chunks.put(
        //                 game.gpa,
        //                 .{
        //                     chunk_column_meta.chunk_x,
        //                     chunk_column_meta.chunk_z,
        //                 },
        //                 chunk_column,
        //             );
        //             try ChunkColumn.parse(
        //                 chunk_column,
        //                 fbr.reader(),
        //                 chunk_column_meta.primary_bitmap,
        //                 chunk_column_meta.add_bitmap,
        //                 mcb.sky_light_sent,
        //                 true,
        //             );
        //         }
        //     },
        //     else => |p| {
        //         std.log.debug("{s}", .{@tagName(p)});
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

    return World.init(gpa, username, spawn_position);
}
