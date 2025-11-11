struct Vertex {
    float2 position;
    uint8_t tex_coord;
};

struct VertOut {
    float4 position : SV_Position;
    float2 tex_coord;
};


[shader("vertex")]
VertOut vertMain(Vertex vertex) {
    VertOut output;
    output.position = float4(2.0 * vertex.position.x - 1.0, 1.0 - 2.0 * vertex.position.y, 0.0, 1.0);
    output.tex_coord = float2(float(vertex.tex_coord & 1), float((vertex.tex_coord >> 1) & 1));
    return output;
}


[shader("fragment")]
float4 concaveMain(VertOut input) : SV_Target {
    float tmp = 1.0 + input.tex_coord.x - input.tex_coord.y;
    if (tmp * tmp < 4.0 * input.tex_coord.x) discard;
    return float4(1.0, 1.0, 1.0, 1.0);
}

[shader("fragment")]
float4 convexMain(VertOut input) : SV_Target {
    float tmp = 1.0 + input.tex_coord.x - input.tex_coord.y;
    if (tmp * tmp > 4.0 * input.tex_coord.x) discard;
    return float4(1.0, 1.0, 1.0, 1.0);
}

