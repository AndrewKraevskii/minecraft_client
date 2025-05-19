@vs vs
@include 3dpga.glsl

layout(binding=0) uniform vs_params {
    // sokol does not allow use of mat2x4
    vec4 mot1;
    vec4 mot2;

    float aspect_ratio;
};

// NOTE: 'vertex' is a reserved name in MSL
struct sb_vertex {
    vec3 pos;
    vec2 uv;
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

out uint typ;
out vec2 uv;


void main() {
    motor motor_ = mat2x4(mot1, mot2);
    vec3 position = vtx[gl_VertexIndex].pos;
    uv = vtx[gl_VertexIndex].uv;

    float x = float(gl_InstanceIndex & 0xf);
    float z = float((gl_InstanceIndex >> 4) & 0xf);
    float y = float((gl_InstanceIndex >> 8) & 0xf);

    uint block_type = ((instance[gl_InstanceIndex >> 2].typ) >> (gl_InstanceIndex & 0x3) * 8) & 0xff;

    const float minfov = 80.0 * PI / 180.0;

    gl_Position = project(0.1, 1000, minfov, 1, sw_mp(motor_, position + vec3(x, y, z)));
    gl_Position.y *= aspect_ratio;
    typ = block_type;
}
@end

@fs fs
flat in uint typ;
in vec2 uv;
out vec4 frag_color;

float max2(vec2 v) {
  return max(v.x, v.y);
}

void main() {
    if (typ == 0) discard;

    vec4 color = vec4(fract(float(typ) * 0.23), fract(float(typ) * 0.33), fract(float(typ) * 0.49), 1);
    float edginess = step(max2(abs(uv - 0.5)), 0.45);
    frag_color = mix(color, vec4(vec3(0.0), 1.0), edginess);
}
@end

@program vertexpull vs fs
