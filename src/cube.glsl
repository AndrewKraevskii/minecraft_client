@vs vs
@include 3dpga.glsl

layout(binding=0) uniform vs_params {
    // sokol does not allow use of mat2x4
    vec4 mot1;
    vec4 mot2;
};

// NOTE: 'vertex' is a reserved name in MSL
struct sb_vertex {
    vec3 pos;
};

struct BlockType {
    /// stores cube type for 4 cubes at once
    uint typ;
};

layout(binding=0) readonly buffer ssbo_type {
    BlockType instance[];
};

layout(binding=1) readonly buffer vertices {
    sb_vertex vtx[];
};

out vec4 color;

void main() {
    motor motor_ = mat2x4(mot1, mot2);
    vec3 position = vtx[gl_VertexIndex].pos;

    float x = float(gl_InstanceIndex & 0xf);
    float y = float((gl_InstanceIndex >> 4) & 0xf);
    float z = float((gl_InstanceIndex >> 8) & 0xf);

    float block_type = ((instance[gl_InstanceIndex >> 2].typ) >> (gl_InstanceIndex & 0x3)) & 0xff;

    gl_Position = project(0, 100, 90, 1, sw_mp(motor_, position + vec3(x, y, z)));
   
    color = vec4(fract(block_type * 0.23), fract(block_type * 0.33), fract(block_type * 0.49),1);
}
@end

@fs fs
in vec4 color;
out vec4 frag_color;

void main() {
    frag_color = color;
}
@end

@program vertexpull vs fs
