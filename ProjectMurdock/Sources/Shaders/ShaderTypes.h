#ifndef ShaderTypes_h
#define ShaderTypes_h

#include <simd/simd.h>

struct Uniforms {
    vector_float4 eulerianRect;   // Normalized (x, y, width, height) of face/neck ROI
    vector_float2 resolution;     // Screen / texture resolution (width, height)
    float audioEnergy;            // Normalized acoustic energy (0.0 to 1.0)
    float time;                   // Running application time in seconds
    int displayMode;              // 0: Mundo en Llamas, 1: LiDAR/IR 3D, 2: Bajo Puerta 40x, 3: Hiper-Tacto
    float eulerianGain;           // Eulerian chrominance magnification factor (default 15.0)
    float penumbralGain;          // Penumbral micro-shadow amplifier (default 40.0)
    float depthMaxDistance;       // Max depth cutoff in meters (default 5.0)
    int hasDepthTexture;          // 1 if hardware LiDAR depth map is bound, 0 if fallback
    int isTorchActive;            // 1 if torch LED is active
    float motionThreshold;        // Motion sensitivity threshold
    float padding;                // Alignment padding (total 64 bytes)
};

#endif /* ShaderTypes_h */
