struct Vertex {
    uint32_t position;
    uint8_t tex_coord;
};

struct VertOut {
    float4 position : SV_Position;
    float2 tex_coord;
};

struct Transform {
    float2 offset;
    float scale;
};
[push_constant]
ConstantBuffer<Transform> transform;


[shader("vertex")]
VertOut vertMain(Vertex vertex) {
    VertOut output;

    float2 position = float2(bit_cast<int16_t2, uint32_t>(vertex.position));
    float2 pos = position * transform.scale + transform.offset;

    output.position = float4(pos.x, -pos.y, 0.0, 1.0);
    output.tex_coord = float2(float(vertex.tex_coord & 1), float((vertex.tex_coord >> 1) & 1));
    return output;
}

[shader("fragment")]
float4 curveMain(VertOut input) : SV_Target {
    float tmp = 1.0 + input.tex_coord.x - input.tex_coord.y;
    float3 ccc = float3(225.0, 105.0, 180.0) / 255.0;
    if (input.tex_coord.x + input.tex_coord.y > 1.0) { // concave
        float2 tex_coord = (1.0 - input.tex_coord).yx;
        float tmp = 1.0 + tex_coord.x - tex_coord.y;
        if (tmp * tmp < 4.0 * tex_coord.x) discard;
        return float4(ccc, 1.0);
    } else { // convex
        float tmp = 1.0 + input.tex_coord.x - input.tex_coord.y;
        if (tmp * tmp > 4.0 * input.tex_coord.x) discard;
        return float4(ccc, 1.0);
    }
    return float4(1.0, 1.0, 1.0, 1.0);
}

[shader("fragment")]
float4 solidMain(VertOut input) : SV_Target {
    float3 ccc = float3(225.0, 105.0, 180.0) / 255.0;
    return float4(ccc, 1.0);
}
