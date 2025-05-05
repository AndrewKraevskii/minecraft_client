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
    vec4 color;
};

layout(binding=0) readonly buffer ssbo {
    sb_vertex vtx[];
};

out vec4 color;

void main() {
    motor motor_ = mat2x4(mot1, mot2);
    vec3 position = vtx[gl_VertexIndex].pos;
    gl_Position = project(0, 100, 90, 1, sw_mp(motor_, position));
   
    color = vtx[gl_VertexIndex].color;
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
