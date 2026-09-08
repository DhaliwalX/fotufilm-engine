// This source is included by HandwrittenSpatial.metal. It is deliberately a separate file so the
// camera endpoint can be maintained independently while reusing the exact development helpers and
// ABI declared by the spatial translation unit.

struct ExactCameraTailParameters {
    float4 minimum;
    float4 inverse_range;
};

// Preserve the composite tail's canonical tetrahedral ordering and two-filtered-read reduction.
// Density is explicitly rounded to half before this lookup, matching the former RGBA16F seam.
static inline float4 exact_camera_tetrahedral(
    texture3d<half, access::sample> cube, float3 point) {
    uint edge = cube.get_width();
    float3 q = clamp(point, 0.0f, 1.0f) * float(edge - 1u);
    uint3 low = min(uint3(q), uint3(edge - 2u));
    float3 f = q - float3(low);
    float largest = max(f.x, max(f.y, f.z));
    float smallest = min(f.x, min(f.y, f.z));
    float middle = max(min(f.x, f.y), min(max(f.x, f.y), f.z));
    bool xLargest = f.x >= f.y && f.x >= f.z;
    bool yLargest = !xLargest && f.y >= f.z;
    bool xSmallest = f.x <= f.y && f.x <= f.z;
    bool ySmallest = !xSmallest && f.y <= f.z;
    uint3 nearStep = uint3(xLargest, yLargest, !xLargest && !yLargest);
    uint3 farStep = uint3(!xSmallest, !ySmallest, xSmallest || ySmallest);
    float firstFraction = middle < 1.0f
        ? (largest - middle) / (1.0f - middle) : 0.0f;
    float secondFraction = middle > 0.0f ? smallest / middle : 0.0f;
    float inverseEdge = 1.0f / float(edge);
    constexpr sampler linearCube(
        coord::normalized, address::clamp_to_edge, filter::linear);
    float3 firstCoordinate = (float3(low) + 0.5f
        + firstFraction * float3(nearStep)) * inverseEdge;
    uint3 far = low + farStep;
    float3 secondCoordinate = (float3(far) + 0.5f
        + secondFraction * float3(1u - farStep)) * inverseEdge;
    float4 first = float4(cube.sample(linearCube, firstCoordinate));
    float4 second = float4(cube.sample(linearCube, secondCoordinate));
    return mix(first, second, middle);
}

/// Exact no-grain camera endpoint. Development remains scene-referred and operates on the same
/// half log-exposure and decimated optical fields as fotufilm_spatial_develop. Its density result is
/// rounded to RGBA16F in registers, then immediately evaluated by the Digital Reference HDR print
/// cube. This removes the full-frame density write and reread without removing a precision seam.
kernel void fotufilm_spatial_develop_linear_hdr(
    texture2d<float, access::read> curves [[texture(0)]],
    texture2d<half, access::read> couplerGrid [[texture(1)]],
    texture2d<half, access::read> adjacencyGrid [[texture(2)]],
    texture2d<half, access::read> logarithmicInput [[texture(3)]],
    texture2d_array<float, access::read> halfResponse [[texture(5)]],
    texture3d<half, access::sample> printCube [[texture(6)]],
    texture2d<half, access::write> output [[texture(7)]],
    const device float *configuration [[buffer(0)]],
    constant DevelopParameters &p [[buffer(7)]],
    constant ExactCameraTailParameters &tail [[buffer(8)]],
    threadgroup half4 *scratch [[threadgroup(0)]],
    uint2 group [[threadgroup_position_in_grid]],
    uint lane [[thread_index_in_threadgroup]]) {
    constexpr int tileSize = 16;
    constexpr int couplerSpan = 6;
    constexpr int adjacencySpan = 10;
    threadgroup half4 *couplerTile = scratch;
    threadgroup half4 *adjacencyTile = couplerTile + couplerSpan * couplerSpan;
    int2 tileOrigin = int2(group) * tileSize;
    int2 couplerBase = int2(group) * (tileSize / int(p.coupler.z)) - 1;
    int2 adjacencyBase = int2(group) * (tileSize / int(p.adjacency.z)) - 1;

    for (int cell = int(lane); cell < couplerSpan * couplerSpan;
         cell += tileSize * tileSize) {
        int2 local = int2(cell % couplerSpan, cell / couplerSpan);
        int2 sample = couplerBase + local;
        couplerTile[cell] = all(sample >= 0) && all(uint2(sample) < p.coupler.xy)
            ? couplerGrid.read(uint2(sample)) : half4(0.0h);
    }
    for (int cell = int(lane); cell < adjacencySpan * adjacencySpan;
         cell += tileSize * tileSize) {
        int2 local = int2(cell % adjacencySpan, cell / adjacencySpan);
        int2 sample = adjacencyBase + local;
        adjacencyTile[cell] = all(sample >= 0) && all(uint2(sample) < p.adjacency.xy)
            ? adjacencyGrid.read(uint2(sample)) : half4(0.0h);
    }
    threadgroup_barrier(mem_flags::mem_threadgroup);

    int x = int(lane) % tileSize;
    int y = int(lane) / tileSize;
    uint2 position = uint2(tileOrigin + int2(x, y));
    if (any(position >= p.extent.xy)) return;

    half4 logarithmicHalf = logarithmicInput.read(position);
    float3 logarithmic = float3(logarithmicHalf.rgb);
    float3 activation = float3(
        half_response(halfResponse, logarithmicHalf.x, 0u).x,
        half_response(halfResponse, logarithmicHalf.y, 1u).x,
        half_response(halfResponse, logarithmicHalf.z, 2u).x);

    float2 couplerCoordinate = (float2(position)
            + float2(p.coupler.w, p.phases.x) + 0.5f)
        / float(max(p.coupler.z, 1u)) - 0.5f;
    float4 released = threadgroup_grid_sample(
        couplerTile, couplerSpan, couplerBase,
        couplerCoordinate, p.coupler.xy);

    float3 effective = logarithmic;
    for (uint channel = 0u; channel < 3u; ++channel) {
        uint row = kCoupler + channel * 3u;
        float inhibition = dot(
            float3(configuration[row], configuration[row + 1u],
                   configuration[row + 2u]), released.rgb)
            * configuration[kCouplerScale];
        if (DEVELOP_DONOR) {
            inhibition += configuration[kDonorRelease + channel] * released.w
                * configuration[kCouplerScale];
        }
        float shifted = logarithmic[channel] - inhibition;
        effective[channel] = shifted + coupler_warp(configuration, channel, shifted);
    }

    float2 adjacencyCoordinate = (float2(position)
            + float2(p.adjacency.w, p.phases.y) + 0.5f)
        / float(max(p.adjacency.z, 1u)) - 0.5f;
    float3 adjacent = threadgroup_grid_sample(
        adjacencyTile, adjacencySpan, adjacencyBase,
        adjacencyCoordinate, p.adjacency.xy).rgb;
    effective -= configuration[kAdjacencyStrength] * (adjacent - activation);

    float3 density;
    for (uint channel = 0u; channel < 3u; ++channel) {
        float formed = sample_film_curve(configuration, curves, effective[channel], channel);
        float dMin = configuration[kCurves + channel * 6u];
        float range = film_curve_range(configuration, channel);
        density[channel] = DEVELOP_COMPLEMENT
            ? dMin + range - (formed - dMin) : formed;
    }

    half4 densityStored = half4(half3(density), 1.0h);
    float3 coordinate = (float3(densityStored.rgb) - tail.minimum.xyz)
        * tail.inverse_range.xyz;
    float3 linear = exact_camera_tetrahedral(printCube, coordinate).rgb;
    output.write(half4(half3(max(linear, 0.0f)), densityStored.w), position);
}
