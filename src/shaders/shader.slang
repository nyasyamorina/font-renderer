struct Vertex {
    uint32_t position;
    uint8_t tex_coord;
};

struct VertOut {
    float4 position : SV_Position;
    float2 tex_coord;
};


[shader("vertex")]
VertOut vertMain(Vertex vertex) {
    VertOut output;
    float scale = 1.0 / 1000.0;

    int16_t2 position = bit_cast<int16_t2, uint32_t>(vertex.position);

    output.position = float4(2.0 * scale * float(position.x) - 1.0, 1.0 - 2.0 * scale * float(position.y), 0.0, 1.0);
    output.tex_coord = float2(float(vertex.tex_coord & 1), float((vertex.tex_coord >> 1) & 1));
    return output;
}


[shader("fragment")]
float4 curveMain(VertOut input) : SV_Target {
    float tmp = 1.0 + input.tex_coord.x - input.tex_coord.y;
    if (input.tex_coord.x + input.tex_coord.y > 1.0) { // concave
        float2 tex_coord = (1.0 - input.tex_coord).yx;
        float tmp = 1.0 + tex_coord.x - tex_coord.y;
        if (tmp * tmp < 4.0 * tex_coord.x) discard;
        return float4(1.0, 0.0, 0.0, 1.0);
    } else { // convex
        float tmp = 1.0 + input.tex_coord.x - input.tex_coord.y;
        if (tmp * tmp > 4.0 * input.tex_coord.x) discard;
        return float4(0.0, 1.0, 0.0, 1.0);
    }
    return float4(1.0, 1.0, 1.0, 1.0);
}

[shader("fragment")]
float4 solidMain(VertOut input) : SV_Target {
    return float4(0.0, 0.0, 1.0, 1.0);
}

