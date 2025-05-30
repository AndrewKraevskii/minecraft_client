const std = @import("std");

const geom = @import("geo_math");
const sokol = @import("sokol");
const sg = sokol.gfx;
const sglue = sokol.glue;

const shd = @import("cube.glsl.zig");
const World = @import("World.zig");

const Renderer = @This();

pipeline: sg.Pipeline,
bind: sg.Bindings,
chunks: Chunks,

const Chunks = std.AutoArrayHashMapUnmanaged(World.Chunk.Pos, struct { gen: u64, buffer: sg.Buffer });

pub fn init(gpa: std.mem.Allocator) !Renderer {
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
            .{ .pos = .{ 0, 0, 0 }, .uv = .{ 0, 0 } },
            .{ .pos = .{ 1, 0, 0 }, .uv = .{ 1, 0 } },
            .{ .pos = .{ 1, 1, 0 }, .uv = .{ 1, 1 } },
            .{ .pos = .{ 0, 1, 0 }, .uv = .{ 0, 1 } },

            .{ .pos = .{ 0, 0, 1 }, .uv = .{ 0, 0 } },
            .{ .pos = .{ 1, 0, 1 }, .uv = .{ 1, 0 } },
            .{ .pos = .{ 1, 1, 1 }, .uv = .{ 1, 1 } },
            .{ .pos = .{ 0, 1, 1 }, .uv = .{ 0, 1 } },

            .{ .pos = .{ 0, 0, 0 }, .uv = .{ 0, 0 } },
            .{ .pos = .{ 0, 1, 0 }, .uv = .{ 1, 0 } },
            .{ .pos = .{ 0, 1, 1 }, .uv = .{ 1, 1 } },
            .{ .pos = .{ 0, 0, 1 }, .uv = .{ 0, 1 } },

            .{ .pos = .{ 1, 0, 0 }, .uv = .{ 0, 0 } },
            .{ .pos = .{ 1, 1, 0 }, .uv = .{ 1, 0 } },
            .{ .pos = .{ 1, 1, 1 }, .uv = .{ 1, 1 } },
            .{ .pos = .{ 1, 0, 1 }, .uv = .{ 0, 1 } },

            .{ .pos = .{ 0, 0, 0 }, .uv = .{ 0, 0 } },
            .{ .pos = .{ 0, 0, 1 }, .uv = .{ 1, 0 } },
            .{ .pos = .{ 1, 0, 1 }, .uv = .{ 1, 1 } },
            .{ .pos = .{ 1, 0, 0 }, .uv = .{ 0, 1 } },

            .{ .pos = .{ 0, 1, 0 }, .uv = .{ 0, 0 } },
            .{ .pos = .{ 0, 1, 1 }, .uv = .{ 1, 0 } },
            .{ .pos = .{ 1, 1, 1 }, .uv = .{ 1, 1 } },
            .{ .pos = .{ 1, 1, 0 }, .uv = .{ 0, 1 } },
        }),
        .label = "vertices",
    });

    var bind: sg.Bindings = .{};

    bind.index_buffer = index_buffer;
    bind.storage_buffers[shd.SBUF_vertices] = cube_data;

    var chunks: Chunks = .empty;
    try chunks.ensureTotalCapacity(gpa, World.max_chunks);

    return .{
        .pipeline = pipeline,
        .bind = bind,
        .chunks = chunks,
    };
}

/// Load chunk or replace existing one.
pub fn loadChunk(r: *Renderer, pos: World.Chunk.Pos, chunk: World.Chunk) sg.Buffer {
    const gop = r.chunks.getOrPutAssumeCapacity(pos);
    if (gop.found_existing) {
        if (gop.value_ptr.gen == chunk.gen)
            return gop.value_ptr.buffer;

        sg.destroyBuffer(gop.value_ptr.buffer);
    }
    gop.value_ptr.* = .{
        .buffer = sg.makeBuffer(.{
            .type = .STORAGEBUFFER,
            .data = sg.asRange(&@as([16 * 16 * 16 / 4]shd.Blocktype, @bitCast(chunk.block_type))),
            .label = "chunk",
        }),
        .gen = chunk.gen,
    };

    return gop.value_ptr.buffer;
}

pub fn deinit(r: *const Renderer, gpa: std.mem.Allocator) void {
    @constCast(r).chunks.deinit(gpa);
}

pub fn renderWorld(renderer: *Renderer, world: *const World) void {
    const width: f32 = sokol.app.widthf();
    const height: f32 = sokol.app.heightf();
    const aspect_ratio = width / height;

    var action: sg.PassAction = .{};
    action.colors[0] = .{
        .load_action = .CLEAR,
        .clear_value = .{
            .a = 1,
        },
    };

    const player = world.player();

    const my_pos = geom.Point{
        .e023 = @floatCast(player.position.x),
        .e013 = @floatCast(-player.position.y),
        .e012 = @floatCast(player.position.z),
        .e123 = 1,
    };

    const rotation_around_origin = toRotor(player.yaw, player.pitch);

    sg.beginPass(.{
        .action = action,
        .swapchain = sglue.swapchain(),
    });

    for (world.chunks.keys(), world.chunks.values()) |pos, chunk| {
        const buffer = renderer.loadChunk(pos, chunk);

        renderer.bind.storage_buffers[shd.SBUF_ssbo_type] = buffer;

        const float_pos = pos.toFloat();

        const translation_from_origin = geom.sqrt(geom.product(my_pos, geom.reverse(geom.Point{
            .e123 = 1,
            .e023 = float_pos[0],
            .e013 = -float_pos[1],
            .e012 = float_pos[2],
        })));
        const motor = geom.product(rotation_around_origin, translation_from_origin);

        sg.applyPipeline(renderer.pipeline);
        sg.applyBindings(renderer.bind);
        sg.applyUniforms(shd.UB_vs_params, sg.asRange(&motorToVsParams(motor, aspect_ratio)));

        sg.draw(0, 36, 16 * 16 * 16);
    }
    sg.endPass();
    sg.commit();
}

fn motorToVsParams(motor: geom.Motor, aspect_ratio: f32) shd.VsParams {
    return .{
        .aspect_ratio = aspect_ratio,
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
