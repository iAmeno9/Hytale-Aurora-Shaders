// Aurora Shaders for Hytale - ground-truth ambient occlusion (horizon-based; Jimenez et al. 2016,
// "Practical Realtime Strategies for Accurate Indirect Occlusion").
// The alternative to Hytale's SSAO (Lighting -> Ambient occlusion method). Per pixel, a few
// screen-space slices through the view direction; along each, the highest horizon on either side
// of the surface (from the depth buffer, within a world-space radius that fades out) bounds the
// part of the hemisphere the sky and the room can light, integrated analytically against the
// cosine. Slices and steps are rotated per pixel and frame (blue noise) for the temporal AA or
// DLSS to resolve. DeferredFS traces it in the hook's half-resolution pass and upsamples it
// (AU_UpsampleHalfRes), or per pixel when the hook doesn't run that pass.
// Requires the deferred pass's includes (SceneData, Reconstruction_inc, AU_Temporal).

#ifndef AU_GTAO
#define AU_GTAO

#if AU_GTAO_QUALITY <= 1
#define AU_GTAO_SLICES 2
#define AU_GTAO_STEPS 4
#elif AU_GTAO_QUALITY == 2
#define AU_GTAO_SLICES 2
#define AU_GTAO_STEPS 6
#else
#define AU_GTAO_SLICES 3
#define AU_GTAO_STEPS 8
#endif

// View depth in blocks at uv; -1 for the sky.
float AU_GTAOLinearDepth(sampler2D depthTex, vec2 uv)
{
    float d = textureLod(depthTex, uv, 0.0).r;
    if (d >= 1.0) return -1.0;
#if USE_LINEAR_Z
    return d * FarClip;
#else
    return GetLinearDepthFromDepthHW(d, ProjectionMatrix);
#endif
}

// Rotation taking +z (toward the camera, in a slice's own frame) to viewVec, applied to v
// (Rodrigues' formula; the view vector is never opposite to +z in GL view space).
vec3 AU_GTAOFromViewFrame(vec3 viewVec, vec3 v)
{
    float e = viewVec.z;
    vec3 axis = vec3(-viewVec.y, viewVec.x, 0.0);   // cross(+z, viewVec)
    return v * e + cross(axis, v) + axis * (dot(axis, v) / max(1.0 + e, 1e-4));
}

// posVS / normalVS: the surface in view space. noise: two blue-noise values for this pixel+frame.
// bentNormalVS: the open part of the hemisphere's mean direction (where the sky and the room are
// visible from), from the same horizons - the cosine-weighted integral per slice.
float AU_GTAOVisibilityBent(sampler2D depthTex, vec2 uv, vec3 posVS, vec3 normalVS, vec2 noise, out vec3 bentNormalVS)
{
    bentNormalVS = normalVS;
    const float halfPi = 1.5707963;
    vec2 viewport = vec2(textureSize(depthTex, 0));
    float viewDepth = -posVS.z;
    // The radius on screen, in pixels: bounded so a wall right in front of the camera doesn't
    // sample half the screen, and far terrain still gets a couple of pixels.
    float pixelsPerBlock = 0.5 * viewport.y * abs(ProjectionMatrix[1][1]) / max(viewDepth, 0.05);
    float radiusPixels = min(AU_GTAO_RADIUS * pixelsPerBlock, 0.12 * viewport.y);
    if (radiusPixels < 1.5) return 1.0;
    // Occluders fade out over the outer 60% of the radius (no hard cut-off ring).
    float falloffRange = 0.615 * AU_GTAO_RADIUS;
    float falloffMul = -1.0 / falloffRange;
    float falloffAdd = (AU_GTAO_RADIUS - falloffRange) / falloffRange + 1.0;
    vec3 viewVec = normalize(-posVS);
    float minStep = 1.3 / radiusPixels;
    float visibility = 0.0;
    vec3 bent = vec3(0.0);
    for (int slice = 0; slice < AU_GTAO_SLICES; slice++) {
        float phi = (float(slice) + noise.x) * (3.14159265 / float(AU_GTAO_SLICES));
        vec2 omega = vec2(cos(phi), sin(phi));
        vec3 directionVec = vec3(omega, 0.0);
        vec3 orthoDirectionVec = directionVec - dot(directionVec, viewVec) * viewVec;
        vec3 axisVec = normalize(cross(orthoDirectionVec, viewVec));
        vec3 projectedNormal = normalVS - axisVec * dot(normalVS, axisVec);
        float projectedLength = length(projectedNormal);
        if (projectedLength < 1e-4) continue;
        float cosNorm = clamp(dot(projectedNormal, viewVec) / projectedLength, 0.0, 1.0);
        float n = sign(dot(orthoDirectionVec, projectedNormal)) * acos(cosNorm);
        // Without occluders the horizons lie on the surface's own plane.
        float lowCos0 = cos(n + halfPi), lowCos1 = cos(n - halfPi);
        float horizonCos0 = lowCos0, horizonCos1 = lowCos1;
        for (int step = 0; step < AU_GTAO_STEPS; step++) {
            float s = (float(step) + fract(noise.y + float(slice) * 0.618034)) / float(AU_GTAO_STEPS);
            s = s * s + minStep;   // denser close to the pixel, never the pixel itself
            vec2 offset = omega * (s * radiusPixels) / viewport;
            for (int side = 0; side < 2; side++) {
                vec2 sampleUV = side == 0 ? uv + offset : uv - offset;
                if (any(lessThan(sampleUV, vec2(0.0))) || any(greaterThan(sampleUV, vec2(1.0)))) continue;
                float sampleDepth = AU_GTAOLinearDepth(depthTex, sampleUV);
                // Sky and the first-person hand/held item never occlude.
                if (sampleDepth < AU_NEAR_IGNORE) continue;
                vec3 delta = AU_ViewPosition(sampleUV, sampleDepth) - posVS;
                float distance = length(delta);
                float horizonCos = dot(delta, viewVec) / max(distance, 1e-4);
                float weight = clamp(distance * falloffMul + falloffAdd, 0.0, 1.0);
                if (side == 0) horizonCos0 = max(horizonCos0, mix(lowCos0, horizonCos, weight));
                else horizonCos1 = max(horizonCos1, mix(lowCos1, horizonCos, weight));
            }
        }
        float h0 = -acos(clamp(horizonCos1, -1.0, 1.0));
        float h1 = acos(clamp(horizonCos0, -1.0, 1.0));
        h0 = n + clamp(h0 - n, -halfPi, halfPi);
        h1 = n + clamp(h1 - n, -halfPi, halfPi);
        float arc0 = cosNorm + 2.0 * h0 * sin(n) - cos(2.0 * h0 - n);
        float arc1 = cosNorm + 2.0 * h1 * sin(n) - cos(2.0 * h1 - n);
        visibility += projectedLength * 0.25 * (arc0 + arc1);
        float t0 = (6.0 * sin(h0 - n) - sin(3.0 * h0 - n) + 6.0 * sin(h1 - n) - sin(3.0 * h1 - n)
                  + 16.0 * sin(n) - 3.0 * (sin(h0 + n) + sin(h1 + n))) / 12.0;
        float t1 = (-cos(3.0 * h0 - n) - cos(3.0 * h1 - n) + 8.0 * cos(n) - 3.0 * (cos(h0 + n) + cos(h1 + n))) / 12.0;
        bent += AU_GTAOFromViewFrame(viewVec, vec3(directionVec.xy * t0, t1)) * projectedLength;
    }
    if (dot(bent, bent) > 1e-8) bentNormalVS = normalize(bent);
    return clamp(visibility / float(AU_GTAO_SLICES), 0.0, 1.0);
}

float AU_GTAOVisibility(sampler2D depthTex, vec2 uv, vec3 posVS, vec3 normalVS, vec2 noise)
{
    vec3 bentNormalVS;
    return AU_GTAOVisibilityBent(depthTex, uv, posVS, normalVS, noise, bentNormalVS);
}

// Light bounces between the occluding surfaces: bright materials lose less than the single-bounce
// visibility says (Jimenez et al.'s fit, against the linear albedo's luminance).
float AU_GTAOMultiBounce(float visibility, vec3 albedo)
{
    float a = clamp(dot(pow(clamp(albedo, 0.0, 1.0), vec3(2.2)), vec3(0.299, 0.587, 0.114)), 0.0, 1.0);
    float x = visibility;
    float A = 2.0404 * a - 0.3324, B = -4.7951 * a + 0.6417, C = 2.7552 * a + 0.6903;
    return max(x, ((x * A + B) * x + C) * x);
}

#endif // AU_GTAO
