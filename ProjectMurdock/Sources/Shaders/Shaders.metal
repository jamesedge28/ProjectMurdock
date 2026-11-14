#include <metal_stdlib>
#include "ShaderTypes.h"

using namespace metal;

struct VertexInput {
    float4 position [[attribute(0)]];
    float2 texCoord [[attribute(1)]];
};

struct RasterizerData {
    float4 position [[position]];
    float2 texCoord;
};

// Full-screen quad vertex shader
vertex RasterizerData vertexShader(uint vertexID [[vertex_id]]) {
    RasterizerData out;
    
    // Quad coordinates: 0, 1, 2, 3 covering [-1, 1] in clip space
    const float2 positions[4] = {
        float2(-1.0, -1.0),
        float2( 1.0, -1.0),
        float2(-1.0,  1.0),
        float2( 1.0,  1.0)
    };
    
    // Texture coordinates covering [0, 1]
    const float2 texCoords[4] = {
        float2(0.0, 1.0),
        float2(1.0, 1.0),
        float2(0.0, 0.0),
        float2(1.0, 0.0)
    };
    
    out.position = float4(positions[vertexID], 0.0, 1.0);
    out.texCoord = texCoords[vertexID];
    return out;
}

// Convert RGB to perceptual Luminance (Rec. 709)
static inline float rgb2luminance(float3 color) {
    return dot(color, float3(0.2126, 0.7152, 0.0722));
}

// Fragment shader containing all 4 Murdock modes + Eulerian magnification
fragment float4 fragmentShader(RasterizerData in [[stage_in]],
                               texture2d<float, access::sample> colorTexture [[texture(0)]],
                               texture2d<float, access::sample> previousTexture [[texture(1)]],
                               texture2d<float, access::sample> depthTexture [[texture(2)]],
                               constant Uniforms &uniforms [[buffer(0)]]) {
    constexpr sampler linearSampler(coord::normalized,
                                    address::clamp_to_edge,
                                    filter::linear);

    float2 uv = in.texCoord;
    float2 texel = 1.0 / uniforms.resolution;

    // Sample current and previous frames
    float4 currSample = colorTexture.sample(linearSampler, uv);
    float4 prevSample = previousTexture.sample(linearSampler, uv);
    float3 currCol = currSample.rgb;
    float3 prevCol = prevSample.rgb;

    // Apply Eulerian Magnification if inside ROI (Face / Neck)
    bool inEulerian = (uv.x >= uniforms.eulerianRect.x &&
                       uv.x <= (uniforms.eulerianRect.x + uniforms.eulerianRect.z) &&
                       uv.y >= uniforms.eulerianRect.y &&
                       uv.y <= (uniforms.eulerianRect.y + uniforms.eulerianRect.w));

    if (inEulerian && uniforms.eulerianGain > 1.0) {
        float deltaG = currCol.g - prevCol.g;
        currCol.r = clamp(currCol.r + deltaG * uniforms.eulerianGain * 1.5, 0.0, 1.0);
        currCol.g = clamp(currCol.g - deltaG * uniforms.eulerianGain * 0.7, 0.0, 1.0);
    }

    float3 finalRGB = float3(0.0);

    // =========================================================================
    // MODO 0: MUNDO EN LLAMAS (Ecolocalización Reactiva)
    // =========================================================================
    if (uniforms.displayMode == 0) {
        // 3D Sobel spatial edge detection
        float c00 = rgb2luminance(colorTexture.sample(linearSampler, uv + float2(-texel.x, -texel.y)).rgb);
        float c10 = rgb2luminance(colorTexture.sample(linearSampler, uv + float2( 0.0,     -texel.y)).rgb);
        float c20 = rgb2luminance(colorTexture.sample(linearSampler, uv + float2( texel.x, -texel.y)).rgb);
        float c01 = rgb2luminance(colorTexture.sample(linearSampler, uv + float2(-texel.x,  0.0)).rgb);
        float c21 = rgb2luminance(colorTexture.sample(linearSampler, uv + float2( texel.x,  0.0)).rgb);
        float c02 = rgb2luminance(colorTexture.sample(linearSampler, uv + float2(-texel.x,  texel.y)).rgb);
        float c12 = rgb2luminance(colorTexture.sample(linearSampler, uv + float2( 0.0,      texel.y)).rgb);
        float c22 = rgb2luminance(colorTexture.sample(linearSampler, uv + float2( texel.x,  texel.y)).rgb);

        float gx = (-1.0 * c00) + (1.0 * c20) + (-2.0 * c01) + (2.0 * c21) + (-1.0 * c02) + (1.0 * c22);
        float gy = (-1.0 * c00) + (-2.0 * c10) + (-1.0 * c20) + (1.0 * c02) + (2.0 * c12) + (1.0 * c22);
        float edge = sqrt(gx * gx + gy * gy);

        // Temporal difference (movement tracking)
        float motion = length(currCol - prevCol);
        float motionActive = smoothstep(uniforms.motionThreshold, uniforms.motionThreshold + 0.12, motion);

        // Acoustic radial sweep
        float distCenter = distance(uv, float2(0.5, 0.5));
        float acousticWave = sin(distCenter * 40.0 - uniforms.time * 12.0) * 0.5 + 0.5;
        float acousticPulse = uniforms.audioEnergy * (0.3 + 0.7 * acousticWave);

        // Geometric edge illumination from sound
        float edgeIllumination = smoothstep(0.06, 0.28, edge) * acousticPulse;

        // Daredevil Palette: Blood Red (#8B0000) to Incandescent Orange (#FF4500)
        const float3 bloodRed = float3(0.545, 0.0, 0.0);
        const float3 flameOrange = float3(1.0, 0.271, 0.0);
        const float3 movingGlow = float3(1.0, 0.85, 0.15); // Neon orange/yellow for kinetic targets

        float3 flameColor = mix(bloodRed, flameOrange, clamp(edgeIllumination * 2.0, 0.0, 1.0));

        // Moving targets are always illuminated even in complete silence
        if (motionActive > 0.01) {
            finalRGB = mix(flameColor * edgeIllumination, movingGlow, motionActive);
        } else {
            // Absolute darkness in silence
            finalRGB = flameColor * edgeIllumination;
        }

        // Add subtle tactical noise floor
        finalRGB += bloodRed * (uniforms.audioEnergy * 0.05);
    }

    // =========================================================================
    // MODO 1: LIDAR / INFRARROJO 3D NOCTURNO (Oscuridad Total)
    // =========================================================================
    else if (uniforms.displayMode == 1) {
        if (uniforms.hasDepthTexture == 1) {
            // Hardware LiDAR Depth Buffer (values in meters)
            float depth = depthTexture.sample(linearSampler, uv).r;

            if (depth > 0.05 && depth <= uniforms.depthMaxDistance) {
                // Topographic isolines (every 15 cm)
                float contour = abs(sin(depth * 3.14159265 * 6.66));
                float isoLine = smoothstep(0.85, 0.98, contour);

                // Screen-space depth gradient for 3D surface normals
                float dX = dfdx(depth);
                float dY = dfdy(depth);
                float3 normal = normalize(float3(-dX * 80.0, -dY * 80.0, 1.0));
                float shading = clamp(dot(normal, normalize(float3(0.3, 0.4, 0.87))), 0.2, 1.0);

                // Distance color grading:
                // Close (0.3m - 1.5m): Incandescent orange-red (#FF4500)
                // Mid (1.5m - 3.5m): Tactical Crimson (#8B0000)
                // Far (3.5m - 5.0m): Deep Night Maroon (#200000)
                float normDist = clamp(depth / uniforms.depthMaxDistance, 0.0, 1.0);
                float3 closeColor = float3(1.0, 0.32, 0.05);
                float3 midColor   = float3(0.65, 0.05, 0.0);
                float3 farColor   = float3(0.15, 0.01, 0.0);

                float3 depthColor = (normDist < 0.35)
                    ? mix(closeColor, midColor, normDist / 0.35)
                    : mix(midColor, farColor, (normDist - 0.35) / 0.65);

                finalRGB = depthColor * shading + float3(1.0, 0.6, 0.2) * (isoLine * 0.7);
            } else {
                // Out of range: Tactical void
                finalRGB = float3(0.01, 0.0, 0.0);
            }
        } else {
            // Fallback for non-LiDAR / TrueDepth front camera:
            // High-gain night vision IR look + Sobel edges
            float lum = rgb2luminance(currCol);
            float boostedLum = pow(lum, 0.4) * 2.5;

            float c00 = rgb2luminance(colorTexture.sample(linearSampler, uv + float2(-texel.x, -texel.y)).rgb);
            float c20 = rgb2luminance(colorTexture.sample(linearSampler, uv + float2( texel.x, -texel.y)).rgb);
            float c02 = rgb2luminance(colorTexture.sample(linearSampler, uv + float2(-texel.x,  texel.y)).rgb);
            float c22 = rgb2luminance(colorTexture.sample(linearSampler, uv + float2( texel.x,  texel.y)).rgb);
            float edge = length(float2(c20 - c00, c22 - c02));

            float3 irPalette = mix(float3(0.1, 0.0, 0.0), float3(1.0, 0.2, 0.05), boostedLum);
            finalRGB = irPalette + float3(1.0, 0.7, 0.2) * smoothstep(0.08, 0.25, edge);
        }
    }

    // =========================================================================
    // MODO 2: ESCÁNER BAJO LA PUERTA (Amplificación Penumbral 40x)
    // =========================================================================
    else if (uniforms.displayMode == 2) {
        float lumCurr = rgb2luminance(currCol);
        float lumPrev = rgb2luminance(prevCol);
        float deltaL = abs(lumCurr - lumPrev);

        // Amplify micro-variations (< 1%) by 40x
        // Discard sensor noise floor (< 0.002)
        float microShadow = clamp((deltaL - 0.002) * uniforms.penumbralGain, 0.0, 1.0);

        // Low-key charcoal monochrome base floor
        float3 baseFloor = float3(0.03, 0.03, 0.035) + currCol * 0.04;

        // Micro-shadows flare in radiant tactical laser crimson
        float3 laserRed = float3(1.0, 0.05, 0.02);
        finalRGB = mix(baseFloor, laserRed, microShadow);
    }

    // =========================================================================
    // MODO 3: HIPER-TACTO ÓPTICO (Lectura de Relieves y Papel en Blanco)
    // =========================================================================
    else if (uniforms.displayMode == 3) {
        // High-pass directional normal map filter
        float c00 = rgb2luminance(colorTexture.sample(linearSampler, uv + float2(-texel.x, -texel.y)).rgb);
        float c10 = rgb2luminance(colorTexture.sample(linearSampler, uv + float2( 0.0,     -texel.y)).rgb);
        float c20 = rgb2luminance(colorTexture.sample(linearSampler, uv + float2( texel.x, -texel.y)).rgb);
        float c01 = rgb2luminance(colorTexture.sample(linearSampler, uv + float2(-texel.x,  0.0)).rgb);
        float c21 = rgb2luminance(colorTexture.sample(linearSampler, uv + float2( texel.x,  0.0)).rgb);
        float c02 = rgb2luminance(colorTexture.sample(linearSampler, uv + float2(-texel.x,  texel.y)).rgb);
        float c12 = rgb2luminance(colorTexture.sample(linearSampler, uv + float2( 0.0,      texel.y)).rgb);
        float c22 = rgb2luminance(colorTexture.sample(linearSampler, uv + float2( texel.x,  texel.y)).rgb);

        // Scharr high-frequency gradients
        float gx = (-3.0 * c00) + (3.0 * c20) + (-10.0 * c01) + (10.0 * c21) + (-3.0 * c02) + (3.0 * c22);
        float gy = (-3.0 * c00) + (-10.0 * c10) + (-3.0 * c20) + (3.0 * c02) + (10.0 * c12) + (3.0 * c22);

        // Synthetic normal vector
        float3 normal = normalize(float3(-gx * 14.0, -gy * 14.0, 1.0));

        // Grazing directional light vector (simulates glancing torch angle)
        float3 grazingLight = normalize(float3(0.85, 0.35, 0.38));
        float diffuse = dot(normal, grazingLight);

        // Steep high-pass contrast curve to cancel out uniform paper white
        float relief = clamp((diffuse - 0.45) * 6.5, 0.0, 1.0);

        // Highlight paper indentations, microscopic grooves and latent ridges
        const float3 paperNoir = float3(0.04, 0.04, 0.04);
        const float3 grooveHighlight = float3(1.0, 0.35, 0.05);

        finalRGB = mix(paperNoir, grooveHighlight, relief);
    }

    // Reticle boundary for Eulerian ROI (subtle red tactical brackets)
    if (inEulerian) {
        float2 relUV = (uv - uniforms.eulerianRect.xy) / uniforms.eulerianRect.zw;
        float borderDist = min(min(relUV.x, 1.0 - relUV.x), min(relUV.y, 1.0 - relUV.y));
        if (borderDist < 0.02) {
            finalRGB = mix(finalRGB, float3(1.0, 0.1, 0.1), 0.7);
        }
    }

    return float4(finalRGB, 1.0);
}
