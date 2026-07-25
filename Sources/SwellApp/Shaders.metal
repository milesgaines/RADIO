#include <metal_stdlib>
#include <SwiftUI/SwiftUI_Metal.h>
using namespace metal;

// Post-processing for the plate: print-like texture, not screen-like polish.

/// Time-invariant film grain — static hash noise, like paper tooth or press
/// grain. Moving grain reads as TV static; still grain reads as material.
[[ stitchable ]] half4 filmGrain(float2 position, half4 color, float intensity) {
    float n = fract(sin(dot(floor(position), float2(12.9898, 78.233))) * 43758.5453);
    half g = half((n - 0.5) * intensity);
    return half4(color.rgb + g * color.a, color.a);
}

/// Radial chromatic aberration — the red and blue channels part ways toward
/// the edges, like a cheap lens or misregistered print pass. `amount` is the
/// max offset in points at the corners; feed it a whisper of bass so the
/// music physically smears the image on hits.
[[ stitchable ]] half4 aberration(float2 position, SwiftUI::Layer layer,
                                  float2 size, float amount) {
    float2 center = size * 0.5;
    float2 dir = (position - center) / max(size.x, size.y);
    float2 offset = dir * amount;
    half r = layer.sample(position + offset).r;
    half4 c = layer.sample(position);
    half b = layer.sample(position - offset).b;
    return half4(r, c.g, b, c.a);
}
