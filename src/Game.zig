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

const Config = @import("Config.zig");
const Input = @import("Input.zig");
const networking = @import("networking.zig");
const Renderer = @import("Renderer.zig");
const World = @import("World.zig");

pub const std_options: std.Options = .{
    .log_scope_levels = &.{
        .{
            .scope = .minecraft_protocol,
            .level = .err,
        },
    },
};

const config_path = "config.zon";

gpa: std.heap.GeneralPurposeAllocator(.{}),
config: Config,

/// used to close networking thread
running: std.atomic.Value(bool),

world_mutex: Mutex,
world: ?World,

network_thread: ?std.Thread,

graphics: Graphics,
renderer: Renderer,

ui_imgui: UiImgui,

input: Input,

const Graphics = struct {
    clear_action: sg.PassAction,
    load_action: sg.PassAction,
    sokol_2d: Sokol2d,
};

fn sokolInit(user_data: ?*anyopaque) callconv(.c) void {
    const state: *@This() = @ptrCast(@alignCast(user_data));

    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .init;

    // initialize sokol-gfx
    sg.setup(.{
        .buffer_pool_size = 10000,
        .environment = sglue.environment(),
        .logger = .{ .func = slog.func },
    });
    // initialize sokol-imgui
    simgui.setup(.{
        .logger = .{ .func = slog.func },
    });
    // initial clear color

    const sokol2d = Sokol2d.init(gpa.allocator()) catch @panic("OOM");
    const renderer = Renderer.init(gpa.allocator()) catch @panic("OOM");

    const config = Config.load(gpa.allocator(), config_path);

    state.* = .{
        .config = config,
        .running = .init(true),
        .input = .init,
        .network_thread = null,
        .graphics = .{
            .sokol_2d = sokol2d,
            .clear_action = .{},
            .load_action = .{},
        },
        .renderer = renderer,
        .gpa = gpa,
        .ui_imgui = .init(config.username, config.server_ip, config.server_port, config.password),
        .world_mutex = .{},
        .world = null,
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
    username: [100:0]u8,
    ip_buffer: ["255.255.255.255".len:0]u8,
    port: u16 = 0,
    password: [100:0]u8,

    send_message: [100:0]u8,

    pub fn init(
        username: ?[]const u8,
        ip: ?[]const u8,
        port: ?u16,
        password: ?[]const u8,
    ) UiImgui {
        var ui: UiImgui = .{
            .username = @splat(0),
            .ip_buffer = @splat(0),
            .port = port orelse 0,
            .send_message = @splat(0),
            .password = @splat(0),
        };
        if (username) |un| {
            @memcpy(ui.username[0..un.len], un);
        }
        if (password) |pswd| {
            @memcpy(ui.password[0..pswd.len], pswd);
        }
        if (ip) |_ip| {
            @memcpy(ui.ip_buffer[0.._ip.len], _ip);
        }
        return ui;
    }
};

fn updateClientInput(
    world: *World,
    input: Input,
    delta_t: f32,
) void {
    const yaw = world.player().yaw;

    // move
    var velocity: [3]f32 = @splat(0);
    inline for ([_]Input.Keycode{ .W, .A, .S, .D, .LEFT_SHIFT, .LEFT_CONTROL }) |key| {
        if (input.isKeyDown(key)) {
            switch (key) {
                .W => velocity[2] += 1,
                .S => velocity[2] -= 1,
                .A => velocity[0] += 1,
                .D => velocity[0] -= 1,
                .LEFT_SHIFT => velocity[1] += 1,
                .LEFT_CONTROL => velocity[1] -= 1,
                else => comptime unreachable,
            }
        }
    }

    world.playerPtr().position.x += @cos(-yaw) * velocity[0] * delta_t * World.Player.debug_speed + @sin(yaw) * velocity[2] * delta_t * World.Player.debug_speed;
    world.playerPtr().position.y += velocity[1] * delta_t * World.Player.debug_speed;
    world.playerPtr().position.z += @sin(-yaw) * velocity[0] * delta_t * World.Player.debug_speed + @cos(yaw) * velocity[2] * delta_t * World.Player.debug_speed;

    // rotate
    world.playerPtr().yaw -= input.mouse_delta[0] / 100;
    world.playerPtr().pitch += input.mouse_delta[1] / 100;
    world.playerPtr().pitch = std.math.clamp(world.playerPtr().pitch, -std.math.pi / 2.0, std.math.pi / 2.0);
}

fn sokolFrame(user_data: ?*anyopaque) callconv(.c) void {
    const state: *@This() = @ptrCast(@alignCast(user_data));
    defer state.input.newFrame();

    state.world_mutex.lock();
    defer state.world_mutex.unlock();

    if (state.world) |*world| {
        updateClientInput(world, state.input, 1.0 / 60.0);

        clearScreen(&state.graphics);
        state.renderer.renderWorld(world);
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
            _ = ig.igInputText("Username", &state.ui_imgui.username, state.ui_imgui.username.len, 0);
            _ = ig.igInputText("Server IP", &state.ui_imgui.ip_buffer, state.ui_imgui.ip_buffer.len, 0);
            {
                var int: c_int = state.ui_imgui.port;
                _ = ig.igInputInt("Port", &int);
                state.ui_imgui.port = std.math.lossyCast(u16, int);
            }
            _ = ig.igInputText("Password", &state.ui_imgui.password, state.ui_imgui.password.len, 0);

            if (ig.igButton("Connect")) connect: {
                const ip = std.mem.span(@as([*:0]const u8, &state.ui_imgui.ip_buffer));
                const username = std.mem.span(@as([*:0]const u8, &state.ui_imgui.username));
                const port = state.ui_imgui.port;

                const address = std.net.Address.parseIp4(ip, port) catch |e| {
                    std.log.err("Failed to parse address: {s}", .{@errorName(e)});
                    break :connect;
                };
                const stream = std.net.tcpConnectToAddress(address) catch |e| {
                    std.log.err("Failed to handshake with server: {s}", .{@errorName(e)});
                    break :connect;
                };
                const world = networking.worldHandshake(
                    state.gpa.allocator(),
                    stream,
                    username,
                    ip,
                    port,
                ) catch |e| fail("Failed to connect {s}", .{@errorName(e)});
                state.world = world;

                state.network_thread = std.Thread.spawn(.{}, networking.networkThread, .{
                    state.gpa.allocator(),
                    &state.running,
                    stream,
                    state.config.password orelse "",
                    &state.world_mutex,
                    &state.world.?,
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
        .QUIT_REQUESTED => {
            state.running.store(false, .release);
            sapp.quit();
        },
        .KEY_DOWN => switch (event.key_code) {
            .ESCAPE => {
                sapp.requestQuit();
            },
            else => {},
        },
        else => |t| {
            _ = t;
            // std.log.debug("unhandled {s}", .{@tagName(t)});
        },
    }
}

fn sokolCleanup(user_data: ?*anyopaque) callconv(.c) void {
    const state: *@This() = @ptrCast(@alignCast(user_data));

    if (state.network_thread) |thread| thread.join();
    state.config.username = std.mem.span(@as([*:0]const u8, &state.ui_imgui.username));
    state.config.server_ip = std.mem.span(@as([*:0]const u8, &state.ui_imgui.ip_buffer));
    state.config.server_port = state.ui_imgui.port;
    state.config.password = std.mem.span(@as([*:0]const u8, &state.ui_imgui.password));

    state.config.save(config_path);

    state.renderer.deinit(state.gpa.allocator());

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
        .width = 640,
        .height = 480,
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
