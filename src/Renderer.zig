const std = @import("std");

const geom = @import("geo_math");
const sokol = @import("sokol");
const sg = sokol.gfx;
const sapp = sokol.app;
const sglue = sokol.glue;
const slog = sokol.log;
const simgui = sokol.imgui;

const shd = @import("cube.glsl.zig");
const World = @import("World.zig");

const Renderer = @This();

pipeline: sg.Pipeline,
bind: sg.Bindings,

pub fn init() !Renderer {
    const pipeline = sg.makePipeline(.{
        .shader = sg.makeShader(shd.vertexpullShaderDesc(sg.queryBackend())),
        .index_type = .UINT16,
        .depth = .{
            .compare = .LESS,
            .write_enabled = true,
        },
        .cull_mode = .BACK,
        .label = "draw chunk",
    });
    const index_buffer = sg.makeBuffer(.{
        .type = .INDEXBUFFER,
        .data = sg.asRange(&[_]u16{
            0,  1,  2,  0,  2,  3,
            6,  5,  4,  7,  6,  4,
            8,  9,  10, 8,  10, 11,
            14, 13, 12, 15, 14, 12,
            16, 17, 18, 16, 18, 19,
            22, 21, 20, 23, 22, 20,
        }),
        .label = "indices",
    }); // a storage buffer with the cube vertex data

    const cube_data = sg.makeBuffer(.{
        .type = .STORAGEBUFFER,
        .data = sg.asRange(&[_]shd.SbVertex{
            // zig fmt: off
            .{ .pos = .{ -0.5, -0.5, -0.5 } },
            .{ .pos = .{  0.5, -0.5, -0.5 } },
            .{ .pos = .{  0.5,  0.5, -0.5 } },
            .{ .pos = .{ -0.5,  0.5, -0.5 } },
            .{ .pos = .{ -0.5, -0.5,  0.5 } },
            .{ .pos = .{  0.5, -0.5,  0.5 } },
            .{ .pos = .{  0.5,  0.5,  0.5 } },
            .{ .pos = .{ -0.5,  0.5,  0.5 } },
            .{ .pos = .{ -0.5, -0.5, -0.5 } },
            .{ .pos = .{ -0.5,  0.5, -0.5 } },
            .{ .pos = .{ -0.5,  0.5,  0.5 } },
            .{ .pos = .{ -0.5, -0.5,  0.5 } },
            .{ .pos = .{  0.5, -0.5, -0.5 } },
            .{ .pos = .{  0.5,  0.5, -0.5 } },
            .{ .pos = .{  0.5,  0.5,  0.5 } },
            .{ .pos = .{  0.5, -0.5,  0.5 } },
            .{ .pos = .{ -0.5, -0.5, -0.5 } },
            .{ .pos = .{ -0.5, -0.5,  0.5 } },
            .{ .pos = .{  0.5, -0.5,  0.5 } },
            .{ .pos = .{  0.5, -0.5, -0.5 } },
            .{ .pos = .{ -0.5,  0.5, -0.5 } },
            .{ .pos = .{ -0.5,  0.5,  0.5 } },
            .{ .pos = .{  0.5,  0.5,  0.5 } },
            .{ .pos = .{  0.5,  0.5, -0.5 } },
            // zig fmt: on
        }),
        .label = "vertices",
    });

    var block_type_buffer: [16 * 16 * 16]u8 = undefined;
    for (&block_type_buffer, 0..) |*block, i| {
        block.* = @truncate(i);
    }

    const cube_types = sg.makeBuffer(.{
        .type = .STORAGEBUFFER,
        .data = sg.asRange(&@as([16 * 16 * 16 / 4]shd.Blocktype, @bitCast(block_type_buffer))),
        .label = "vertices",
    });
    var bind: sg.Bindings = .{};

    bind.index_buffer = index_buffer;
    bind.storage_buffers[shd.SBUF_vertices] = cube_data;
    bind.storage_buffers[shd.SBUF_ssbo_type] = cube_types;

    return .{
        .pipeline = pipeline,
        .bind = bind,
    };
}

pub fn renderWorld(renderer: *Renderer, world: *const World) void {
    var action: sg.PassAction = .{};
    action.colors[0] = .{
        .load_action = .CLEAR,
        .clear_value = .{
            .a = 1,
        },
    };

    const player = world.player();


    const my_pos = geom.Point{
        .e023 = player.position[0],
        .e013 = -player.position[1],
        .e012 = player.position[2],
        .e123 = 1,
    };

    const rotation_around_origin = toRotor(player.yaw, player.pitch);


    sg.beginPass(.{
        .action = action,
        .swapchain = sglue.swapchain(),
    });

    for (world.chunks.keys(), world.chunks.values()) |pos, _| {
        const translation_from_origin = geom.sqrt(geom.product(my_pos, geom.reverse(geom.Point{
            .e123 = 1,
            .e023 = @as(f32, @floatFromInt(pos.x)) * 16,
            .e013 = -@as(f32, @floatFromInt(pos.y)) * 16,
            .e012 = @as(f32, @floatFromInt(pos.z)) * 16,
        })));
        const motor = geom.product(rotation_around_origin, translation_from_origin);

        sg.applyPipeline(renderer.pipeline);
        sg.applyBindings(renderer.bind);
        sg.applyUniforms(shd.UB_vs_params, sg.asRange(&motorToVsParams(motor)));

        sg.draw(0, 36, 16 * 16 * 16);
    }
    sg.endPass();
    sg.commit();
}

fn motorToVsParams(motor: geom.Motor) shd.VsParams {
    return .{
        .mot1 = .{ motor.e, motor.e23, -motor.e13, motor.e12 },
        .mot2 = .{ motor.e01, motor.e02, motor.e03, motor.e0123 },
    };
}

fn toRotor(yaw: f32, pitch: f32) geom.Motor {
    const cp = @cos(pitch * 0.5);
    const sp = @sin(pitch * 0.5);
    const cy = @cos(yaw * 0.5);
    const sy = @sin(yaw * 0.5);

    return .{
        .e = cp * cy,
        .e12 = -sp * sy,
        .e23 = sp * cy,
        .e13 = -cp * sy,
    };
}
