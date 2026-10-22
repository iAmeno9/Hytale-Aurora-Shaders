#version 410 core
#extension GL_ARB_shader_image_load_store : enable
#extension GL_ARB_shader_image_size : enable

// Aurora Shaders for Hytale - deferred lighting.
// Replaces Hytale's albedo * (light + ambient) * shadow with a full lighting model,
// atmospheric/border fog and volumetric light shafts.

#include "SceneData_inc.glsl"
#include "Deferred_inc.glsl"
#include "Reconstruction_inc.glsl"
#include "Fog_inc.glsl"
#include "AU_Lighting.glsl"
#include "AU_Material.glsl"
#include "AU_Tonemap.glsl"
#include "AU_Temporal.glsl"
#if AU_AO_METHOD == 1
#include "AU_GTAO.glsl"
#endif
#include "AU_VL.glsl"
#include "AU_Mist.glsl"
#include "AU_Clouds.glsl"
#include "AU_Caustics.glsl"
#include "AU_Rainbow.glsl"
#if AU_PRESET >= 2 || AU_RAIN_PUDDLES
#include "AU_RTX.glsl"
#endif

#ifndef INPUT_NORMALS_IN_WS
#define INPUT_NORMALS_IN_WS 1
#endif
#if AU_VOXEL_WORLD
#define AU_LIGHT_LIST_CACHED 1   // its passes are separate draws with barriers (hook gi_draw)
#include "AU_Voxel.glsl"
#endif
#if AU_GI_DENOISE
#include "AU_DenoiseLegacy.glsl"
#elif AU_VOXEL_WORLD
uniform int uHookPTPass;
#endif

uniform sampler2D uColorTexture;
uniform sampler2D uNormalTexture;
uniform sampler2D uDepthTexture;
uniform sampler2D uSSAOTexture;
uniform sampler2D uLightTexture;
uniform sampler2D uTopDownProjectionTexture;
uniform sampler2D uShadowTexture;
#if USE_FOG
uniform sampler2D uFogNoiseTexture;
#endif

in vec3 fragFrustumRay;
in vec2 fragTexCoords;
#if AU_SKY_LIGHTING == 1
flat in vec3 auSkyLightCube[6];   // the sky's ambient light per facing (ScreenVS, AU_SkyLight.glsl)
#endif

layout(location = 0) out vec4 outColor;

#define AU_HALF_RES_CLOUDS (AU_CLOUDS && AU_CLOUD_SHADOWS)
#define AU_HALF_RES_GI (AU_PRESET >= 2 && !AU_VOXELS && !AU_GI_DENOISE)   // the denoiser filters per pixel
#if AU_LIGHTSHAFTS || AU_AO_METHOD == 1 || AU_HALF_RES_CLOUDS || AU_HALF_RES_GI
uniform int uHookVLPass;    // 1: this draw only traces the light shafts, GTAO, cloud shadows and GI, at half resolution; 2: they are in uHookVL / uHookAO / uHookGI
#if AU_HALF_RES_GI
layout(location = 2) out vec4 outGI;   // half-resolution pass: screen-space GI (rgb) and its occlusion (a)
uniform sampler2D uHookGI;
uniform sampler2D uHookHitLight;       // the light each surface gives off, cached by pass 3 for the GI's rays
#endif
#if AU_AO_METHOD == 1 || AU_HALF_RES_CLOUDS || AU_HALF_RES_GI
layout(location = 1) out vec4 outAO;   // half-resolution pass: GTAO bent normal (octahedral, rg), visibility (b), cloud shadow (a)
uniform sampler2D uHookAO;

// A unit vector in two [0, 1] values (octahedral mapping), for the 8-bit target.
vec2 AU_OctEncode(vec3 n)
{
    n /= abs(n.x) + abs(n.y) + abs(n.z);
    vec2 e = n.z >= 0.0 ? n.xy : (1.0 - abs(n.yx)) * vec2(n.x >= 0.0 ? 1.0 : -1.0, n.y >= 0.0 ? 1.0 : -1.0);
    return e * 0.5 + 0.5;
}

vec3 AU_OctDecode(vec2 e)
{
    e = e * 2.0 - 1.0;
    vec3 n = vec3(e, 1.0 - abs(e.x) - abs(e.y));
    float t = max(-n.z, 0.0);
    n.xy += vec2(n.x >= 0.0 ? -t : t, n.y >= 0.0 ? -t : t);
    return normalize(n);
}

// The half-resolution GTAO, cloud shadow and GI for a full-resolution pixel: the four nearest
// texels, weighted like the shafts by how close the distance each one traced is to this pixel's.
// GTAO's and the GI are also weighted by how well the bent normal fits this pixel's normal (texels
// of the other face at a crease). xyz: bent normal, w: visibility; gi: GI (rgb) and its occlusion.
vec4 AU_UpsampleAO(vec2 uv, float lViewPos, vec3 normal, out float cloudShadow, out vec4 gi)
{
    ivec2 size = textureSize(uHookAO, 0);
    vec2 position = uv * vec2(size) - 0.5;
    ivec2 base = ivec2(floor(position));
    vec2 f = position - vec2(base);
    vec4 sum = vec4(0.0), giSum = vec4(0.0);
    float total = 0.0, cloudSum = 0.0, cloudTotal = 0.0;
    for (int k = 0; k < 4; k++) {
        ivec2 offset = ivec2(k & 1, k >> 1);
        ivec2 texel = clamp(base + offset, ivec2(0), size - 1);
        float traced = texelFetch(uHookVL, texel, 0).a;
        if (traced < 0.0) continue;   // sky
        vec4 packed = texelFetch(uHookAO, texel, 0);
        vec3 bent = AU_OctDecode(packed.rg);
        float weight = (offset.x == 1 ? f.x : 1.0 - f.x) * (offset.y == 1 ? f.y : 1.0 - f.y) + 0.001;
        weight /= 0.001 + abs(traced - lViewPos) / max(lViewPos, 1.0);
        cloudSum += packed.a * weight;
        cloudTotal += weight;
#if AU_AO_METHOD == 1
        weight *= max(dot(bent, normal), 0.05);
#endif
        sum += vec4(bent, packed.b) * weight;
        total += weight;
#if AU_HALF_RES_GI
        giSum += texelFetch(uHookGI, texel, 0) * weight;
#endif
    }
    cloudShadow = cloudTotal > 0.0 ? cloudSum / cloudTotal : 1.0;
    gi = total > 0.0 ? giSum / total : vec4(0.0, 0.0, 0.0, 1.0);
    return total > 0.0 && dot(sum.xyz, sum.xyz) > 1e-8 ? vec4(normalize(sum.xyz), sum.w / total) : vec4(normal, 1.0);
}
#endif

// Half-resolution pass: each texel traces the nearest of the four pixels it covers, so thin
// geometry in front of the sky still gets a sample; all-sky texels trace the sky for SkyFS.
vec4 AU_TraceHalfResVL()
{
    ivec2 size = textureSize(uDepthTexture, 0);
    ivec2 corner = ivec2(gl_FragCoord.xy) * 2, pixel = corner;
    float depth = 2.0;
    for (int k = 0; k < 4; k++) {
        ivec2 candidate = min(corner + ivec2(k & 1, k >> 1), size - 1);
        float candidateDepth = texelFetch(uDepthTexture, candidate, 0).r;
        if (candidateDepth < depth) { depth = candidateDepth; pixel = candidate; }
    }
#if AU_HALF_RES_GI && AU_SSGI_SELF_HIT_FIX
    // The surface's own plane for the GI's self-hit test: screen derivatives, before any return.
    vec2 planeUV = (vec2(pixel) + 0.5) / vec2(size);
#if USE_LINEAR_Z
    vec3 geometricNormal = fastNormalFromPosition(mat3(InvViewMatrix) * AU_ViewPosition(planeUV, min(depth, 1.0) * FarClip));
#else
    vec3 geometricNormal = fastNormalFromPosition(PositionFromDepth(min(depth, 1.0), planeUV, InvViewProjectionMatrix));
#endif
#endif
    if (depth >= 1.0) {
        // All sky: trace the sky's shafts here for SkyFS (a = -1), along this texel's view ray.
        vec2 skyUV = (vec2(corner) + 1.0) / vec2(size);
#if USE_LINEAR_Z
        vec3 ray = mat3(InvViewMatrix) * AU_ViewPosition(skyUV, FarClip * 0.5);
#else
        vec3 ray = PositionFromDepth(0.5, skyUV, InvViewProjectionMatrix);
#endif
        return vec4(GetVolumetricLight(normalize(ray), 100000.0, true, GetDither(gl_FragCoord.xy)), -1.0);
    }
    vec2 uv = (vec2(pixel) + 0.5) / vec2(size);
#if USE_LINEAR_Z
    vec3 playerPos = mat3(InvViewMatrix) * AU_ViewPosition(uv, depth * FarClip);
#else
    vec3 playerPos = PositionFromDepth(depth, uv, InvViewProjectionMatrix);
#endif
    float lViewPos = length(playerPos);
#if AU_AO_METHOD == 1 || AU_HALF_RES_CLOUDS || AU_HALF_RES_GI
    vec4 halfRes = vec4(0.5, 0.5, 1.0, 1.0);
#if AU_AO_METHOD == 1 || AU_HALF_RES_GI
    vec3 normal = decodeNormal(texelFetch(uNormalTexture, pixel, 0).rg);
#if !INPUT_NORMALS_IN_WS
    normal = mat3(InvViewMatrix) * normal;
#endif
#endif
#if AU_AO_METHOD == 1
    vec3 bentNormalVS;
    float visibility = AU_GTAOVisibilityBent(uDepthTexture, uv, (ViewMatrix * vec4(playerPos, 1.0)).xyz, normalize(mat3(ViewMatrix) * normal),
                                             GetDither2(gl_FragCoord.xy + vec2(37.0, 71.0)), bentNormalVS);
    halfRes.rgb = vec3(AU_OctEncode(normalize(mat3(InvViewMatrix) * bentNormalVS)), visibility);
#endif
#if AU_HALF_RES_CLOUDS
    halfRes.a = GetCloudShadow(playerPos);
#endif
    outAO = halfRes;
#endif
#if AU_HALF_RES_GI
#if !AU_SSGI_SELF_HIT_FIX
    vec3 geometricNormal = normal;
#endif
    float giVisibility;
    vec3 gi = AU_GetSSGI(uDepthTexture, playerPos, normal, geometricNormal, GetDither(gl_FragCoord.xy), giVisibility);
    outGI = vec4(gi, giVisibility);
#endif
    return vec4(GetVolumetricLight(playerPos / max(lViewPos, 0.0001), lViewPos, false, GetDither(gl_FragCoord.xy)), lViewPos);
}

#endif

float getShadowFactor(vec2 texCoords)
{
#if USE_DEFERRED_SHADOW
#if USE_DEFERRED_SHADOW_BLURRED && USE_SSAO
    return textureLod(uSSAOTexture, texCoords, 0.0).a;
#else
    return textureLod(uShadowTexture, texCoords, 0.0).r;
#endif
#else
    return 1.0;
#endif
}

#if AU_PRESET >= 2
// One-bounce source for the RTX GI: the sun light a surface receives this frame (albedo x
// shadow-mapped sun x N.L), plus emissive blocks, read straight from the G-buffer.
vec3 AU_GIHitLightData(vec2 uv, out vec2 albedoSky)
{
    vec4 g0 = textureLod(uColorTexture, uv, 0.0);
    vec4 g1 = textureLod(uNormalTexture, uv, 0.0);
    bool hitSSAO, hitBloom;
    unpackGBufferMeta(g0.a, hitSSAO, hitBloom);
    vec3 alb = g0.rgb * AU_ALBEDO_MULT;
    albedoSky = vec2(GetLuminance(alb), g1.b);
    if (hitBloom) return alb * textureLod(uLightTexture, uv, 0.0).rgb * AU_RTX_GI_EMISSIVE;
    // Glowing ore crystals light up what is around them in their colour (the same evened-out
    // tint as their glow).
    float hitOre = AU_MaterialClass(g0.a) == 0u ? AU_OreGlowLevel(g0.a) : 0.0;
    vec3 oreLight = hitOre > 0.0 ? alb * pow(max(GetLuminance(alb), 0.002), -0.5)
        * (hitOre * AU_ORE_TORCH_RATIO * (AU_ORE_LIGHT / 8.0) * AU_OrePulse(g0.rgb)) : vec3(0.0);
    vec3 n = decodeNormal(g1.rg);
    // Foliage is lit flat (no N.L) by Hytale's shading.
    float NdotL = hitSSAO ? max(dot(n, lightVec), 0.0) : 0.6;
    vec3 sunlightBounce = AU_SunBounce(alb, lightColor, getShadowFactor(uv) * NdotL, g1.b,
                                       sunVisibility2 * (1.0 - clamp(IsCameraUnderwater, 0.0, 1.0)), shadowTime);
#if AU_VOXELS
    // Path tracing: plus the torch light it gets (Hytale's glow), so that bounces too.
    vec3 hitStatic = textureLod(uLightTexture, uv, 0.0).rgb;
    vec3 hitGlow = (uint(round(g0.a * 255.0)) & AU_GBUFFER_PURE_GLOW) != 0u
                 ? AU_GlowToBlockLight(hitStatic, n, !hitSSAO)
                 : AU_ExtractBlockLight(hitStatic, g1.b, n, !hitSSAO);
    // And the sky light it gets, for the further bounces (what fills a room with light):
    // Hytale's sky light there, through the same curve as the ambient term.
    float hitSky = smoothstep1(clamp(g1.b, 0.0, 1.0));
    return sunlightBounce + alb * (hitGlow * 0.5 + ambientColor * (hitSky * AU_PT_AMBIENT_BOUNCE)) + oreLight;
#else
    return sunlightBounce + oreLight;
#endif
}

vec3 AU_GIHitLight(vec2 uv)
{
#if AU_HALF_RES_GI
    // The half-resolution GI pass reads it from the cache pass 3 filled, once per texel, instead of
    // working it out again for each of its rays.
    if (uHookVLPass == 1) return textureLod(uHookHitLight, uv, 0.0).rgb;
#endif
    vec2 albedoSky;
    return AU_GIHitLightData(uv, albedoSky);
}

#if AU_HALF_RES_GI
// Pass 3: the light the nearest of the four pixels each texel covers gives off, as a GI ray that
// hits it sees it.
vec4 AU_TraceHitLight()
{
    ivec2 size = textureSize(uDepthTexture, 0);
    ivec2 corner = ivec2(gl_FragCoord.xy) * 2, pixel = corner;
    float depth = 2.0;
    for (int k = 0; k < 4; k++) {
        ivec2 candidate = min(corner + ivec2(k & 1, k >> 1), size - 1);
        float candidateDepth = texelFetch(uDepthTexture, candidate, 0).r;
        if (candidateDepth < depth) { depth = candidateDepth; pixel = candidate; }
    }
    if (depth >= 1.0) return vec4(0.0);
    vec2 albedoSky;
    return vec4(min(AU_GIHitLightData((vec2(pixel) + 0.5) / vec2(size), albedoSky), vec3(1.5)), 1.0);
}
#endif

// For the path tracer's sky light: albedo luminance and Hytale sky light of an on-screen
// surface (the sky light it passes on when a ray hits it).
vec2 AU_GIHitAlbedoSky(vec2 uv)
{
    vec3 alb = textureLod(uColorTexture, uv, 0.0).rgb * AU_ALBEDO_MULT;
    return vec2(GetLuminance(alb), textureLod(uNormalTexture, uv, 0.0).b);
}
#endif

#if AU_PRESET >= 2 || AU_RAIN_PUDDLES
vec3 AU_SSRHitNormal(vec2 uv)
{
    vec3 n = decodeNormal(textureLod(uNormalTexture, uv, 0.0).rg);
#if !INPUT_NORMALS_IN_WS
    n = mat3(InvViewMatrix) * n;
#endif
    return n;
}
#endif

float getSSAOValue(vec2 texCoords, float depth)
{
#if USE_SSAO
#if USE_EDGE_AWARE_UPSAMPLING
    float totalWeight = 0.0;
    float resultValue = 0.0;
    const float depth_epsilon = 0.0001;
    for (int x = 0; x <= 1; x++) {
        for (int y = 0; y <= 1; y++) {
            vec4 value = textureOffset(uSSAOTexture, texCoords, ivec2(x, y));
            float lowResDepth = unpackDepth(value.gb);
            float weight = 1.0 / (depth_epsilon + abs(depth - lowResDepth));
            resultValue += value.r * weight;
            totalWeight += weight;
        }
    }
    return resultValue / totalWeight;
#else
    return texture(uSSAOTexture, texCoords).r;
#endif
#else
    return 1.0;
#endif
}

void main()
{
#if AU_LOCAL_LIGHTS
    if (uHookPTPass == 2) {
        AU_BuildLocalLightTile(min(textureSize(uDepthTexture, 0).y, 2048));
        discard;
    }
#endif
    AU_InitCommon();
#if AU_LIGHTSHAFTS || AU_AO_METHOD == 1 || AU_HALF_RES_CLOUDS || AU_HALF_RES_GI
    if (uHookVLPass == 1) { outColor = AU_TraceHalfResVL(); return; }
#endif
#if AU_HALF_RES_GI
    if (uHookVLPass == 3) { outColor = AU_TraceHitLight(); return; }
#endif
#if AU_SKY_LIGHTING == 1
    for (int face = 0; face < 6; face++) auSkyCube[face] = auSkyLightCube[face];
    auSkyCubeValid = true;
#endif

    vec2 texCoords = fragTexCoords;
    float depth = texture(uDepthTexture, texCoords).r;
    if (depth >= 1.0) {
#if AU_GI_DENOISE
#if AU_GI_TEMPORAL_FILTER
        if (uHookPTPass == 3) {
            // The history read texture has the write image's size. Not imageSize(): AMD's
            // compiler does not offer it to #version 410 shaders (issue #17).
            ivec2 historySize = textureSize(auGIHistPos, 0);
            ivec2 historyPixel = clamp(ivec2(texCoords * vec2(historySize)), ivec2(0), historySize - 1);
            ivec2 representative = ivec2(floor((vec2(historyPixel) + 0.5) * ViewportSize / vec2(historySize)));
            if (all(equal(ivec2(gl_FragCoord.xy), representative)))
                imageStore(auGIOutPos, historyPixel, vec4(1e9, 1e9, 1e9, 0.0));
        }
#endif
#endif
        discard;
    }

    vec4 gbuffer0 = texture(uColorTexture, texCoords);   // RGBA8: albedo + render flags
    vec3 albedo = gbuffer0.rgb;
    albedo = mix(vec3(GetLuminance(albedo)), albedo, AU_ALBEDO_SATURATION) * AU_ALBEDO_MULT;
    vec4 gbuffer1 = texture(uNormalTexture, texCoords);
    vec3 blockLight = texture(uLightTexture, texCoords).rgb;
    float skyLight = gbuffer1.b;
    float ao = getSSAOValue(texCoords, depth);
    float shadow = getShadowFactor(texCoords);

#if USE_LINEAR_Z
    vec3 playerPos = mat3(InvViewMatrix) * AU_ViewPosition(texCoords, depth * FarClip);
#else
    vec3 playerPos = PositionFromDepth(depth, texCoords, InvViewProjectionMatrix);
#endif

    bool hasSSAO, hasBloom, useCleanShadowBackfaces;
    unpackGBufferMeta(gbuffer0.a, hasSSAO, hasBloom);
    useCleanShadowBackfaces = gbuffer1.a > 0.5;

    vec3 normal = decodeNormal(gbuffer1.rg);
#if !INPUT_NORMALS_IN_WS
    normal = mat3(InvViewMatrix) * normal;
#endif

    vec2 surfaceFootprint = AU_SurfaceFootprint(normal, gbuffer0.rgb);
    float dither = GetDither(gl_FragCoord.xy);
#if AU_AO_METHOD == 1 || AU_HALF_RES_CLOUDS || AU_HALF_RES_GI
    // GTAO, the clouds' shadow and the GI, traced at half resolution by the light shaft pass: GTAO
    // and the GI are most of this pass's cost.
    vec4 halfResAO = vec4(normal, 1.0), halfResGI = vec4(0.0, 0.0, 0.0, 1.0);
    float halfResCloud = 1.0;
    if (uHookVLPass == 2 && !hasBloom) halfResAO = AU_UpsampleAO(texCoords, length(playerPos), normal, halfResCloud, halfResGI);
#endif
#if AU_AO_METHOD == 1
    // GTAO in place of Hytale's SSAO on solid surfaces (foliage keeps Hytale's): horizon-based
    // visibility from the depth buffer, with the light bounced between the occluding faces.
    if (hasSSAO && !hasBloom) {
        vec4 traced;
        if (uHookVLPass == 2) {
            traced = halfResAO;
        } else {
            vec3 posVS = (ViewMatrix * vec4(playerPos, 1.0)).xyz;
            vec3 bentNormalVS;
            traced.w = AU_GTAOVisibilityBent(uDepthTexture, texCoords, posVS, normalize(mat3(ViewMatrix) * normal),
                                             GetDither2(gl_FragCoord.xy + vec2(37.0, 71.0)), bentNormalVS);
            traced.xyz = normalize(mat3(InvViewMatrix) * bentNormalVS);
        }
        ao = AU_GTAOMultiBounce(traced.w, albedo);
        auAOIndirectOnly = true;
#if AU_SKY_LIGHTING == 1 && AU_GTAO_BENT_NORMALS
        // Sky light from where the sky is open (recesses, under overhangs: from the opening).
        auSkyNormal = traced.xyz;
        auSkyNormalValid = true;
#endif
    }
#endif


    // Material classes from Hytale's G-buffer flags:
    //  bloom      -> emissive (no shadows, glows)
    //  no SSAO    -> foliage / wind-animated blocks: subsurface scattering, no side shading
    int subsurfaceMode = 0;
    bool noDirectionalShading = false;
    float emission = 0.0;
#if AU_SUBSURFACE || AU_SSS
    if (!hasSSAO && !hasBloom) {
        // Leaf blocks are cubes (axis-aligned normals): keep directional shading.
        // Grass / cross plants have diagonal normals: soft, direction-less light.
        vec3 an = abs(normal);
        bool axisAligned = max(an.x, max(an.y, an.z)) > 0.96;
        subsurfaceMode = axisAligned ? 2 : 1;
        noDirectionalShading = !axisAligned;
    }
#endif
#if AU_SSS
    if (!hasSSAO && !hasBloom && AU_MaterialClass(gbuffer0.a) == 3u) {
        subsurfaceMode = 2;
        noDirectionalShading = false;
        auSSSMask = AU_MaterialLevel(gbuffer0.a);
    }
#endif
#if AU_PRESET >= 2 || AU_GI_DENOISE
#if AU_GI_DENOISE || (!AU_VOXELS && AU_SSGI_SELF_HIT_FIX)
    vec3 historyNormal = fastNormalFromPosition(playerPos);
#else
    vec3 historyNormal = normal;
#endif
#if AU_VOXELS
    if (uHookPTPass <= 1)
        AU_VoxFeed(playerPos, normal, albedo, subsurfaceMode != 0 || !hasSSAO, hasBloom, fract(dither * 7.31 + float(uHookFrame % 3600) * 0.137));
#endif
#if AU_VOXEL_WORLD || AU_GI_DENOISE
    if (uHookPTPass == 1) discard;
#endif
#if AU_GI_DENOISE && AU_GI_TEMPORAL_FILTER
    if (hasBloom && uHookPTPass == 3) {
        ivec2 historySize = textureSize(auGIHistPos, 0);
        ivec2 historyPixel = clamp(ivec2(texCoords * vec2(historySize)), ivec2(0), historySize - 1);
        ivec2 representative = ivec2(floor((vec2(historyPixel) + 0.5) * ViewportSize / vec2(historySize)));
        if (all(equal(ivec2(gl_FragCoord.xy), representative)))
            imageStore(auGIOutPos, historyPixel, vec4(1e9, 1e9, 1e9, 0.0));
    }
#endif
#endif

    // Emissive (lava, flames, crystals): brighter texels glow more.
    if (hasBloom) { emission = AU_EMISSION_STRENGTH * mix(0.5, 1.6, smoothstep(0.15, 0.9, GetLuminance(albedo))); shadow = 1.0; }
    // What the surface is made of (include/AU_Material.glsl, shared with the RR guides): the block
    // material's dry gloss and metal, ore crystal gloss, and rain - a water film on top, soaking
    // into what absorbs it. Glowing ores keep their glow level in the material bits (class 0).
    AU_MaterialData mat = AU_GetMaterial(gbuffer0.a, gbuffer0.rgb, normal, skyLight, surfaceFootprint.y,
                                         hasBloom, subsurfaceMode != 0);
    uint matClass = mat.kind;
    float matLevel = mat.level;
#if AU_SSS
    if (!hasBloom && matClass == 1u && uint(round(matLevel * 7.0)) == 6u) subsurfaceMode = 3;
#endif
    float oreGlowAmount = hasBloom || AU_MaterialClass(gbuffer0.a) != 0u ? 0.0 : AU_OreGlowLevel(gbuffer0.a);
    bool oreGlow = oreGlowAmount > 0.0;
    float matSmooth = mat.smoothness, metal = mat.metal;
    albedo = AU_MaterialSoakedAlbedo(albedo, mat);

    // Shadows of the volumetric clouds drifting over the land.
#if AU_HALF_RES_CLOUDS
    shadow *= hasBloom ? 1.0 : uHookVLPass == 2 ? halfResCloud : GetCloudShadow(playerPos);
#else
    shadow *= hasBloom ? 1.0 : GetCloudShadow(playerPos);
#endif
    if (IsCameraUnderwater > 0.5) {
        // Under water: sun light reaching surfaces comes through the waves (Unbound caustics)
        // and has lost its reds, like water-tinted translucent shadows.
#if AU_WATER_CAUSTICS
        if (!hasBloom) shadow *= mix(1.0, AU_CausticSunMult(playerPos + CameraPosition), 0.6);
#endif
        lightColor *= vec3(0.45, 0.75, 1.25);
    }

    vec3 rawStaticLight = blockLight;
    // Foliage (wind-animated) and emissive blocks use Hytale's flat shading: exposition 1.
    blockLight = (uint(round(gbuffer0.a * 255.0)) & AU_GBUFFER_PURE_GLOW) != 0u
               ? AU_GlowToBlockLight(blockLight, normal, hasBloom || !hasSSAO)
               : AU_ExtractBlockLight(blockLight, skyLight, normal, hasBloom || !hasSSAO);

    float aoUse = (hasSSAO || subsurfaceMode != 0) ? ao : 1.0;

    vec3 localLighting = vec3(0.0);
#if AU_SSS && AU_SSS_VOXEL == 1 && AU_VOXEL_WORLD
    if (subsurfaceMode >= 2 && !hasBloom && skyLight > 0.02) {
        float volumeThickness;
        vec3 scatteringDepth;
        vec4 transmission = AU_TraceSubsurface(playerPos + CameraPosition - normal * 0.025, lightVec, albedo,
                                               subsurfaceMode, volumeThickness, scatteringDepth);
        auSSSVolumeValid = transmission.a > 0.5;
        if (auSSSVolumeValid) {
            auSSSVolumeTransmission = transmission.rgb * auSSSMask * SampleShadowWS(playerPos + lightVec * AU_SSS_TRACE_DISTANCE, 1.0);
            auSSSVolumeLight = AU_SSSVolumeRadiance(auSSSVolumeTransmission, scatteringDepth, normal, playerPos, skyLight, subsurfaceMode);
        }
    }
#endif
#if AU_LOCAL_LIGHTS
    if (!hasBloom) {
        if (uHookLocalLightTiles != 0)
            localLighting = AU_LocalLightingOriginal(playerPos, normal, noDirectionalShading, GetDither2(gl_FragCoord.xy));
        else
            localLighting = AU_LocalLighting(playerPos, normal, noDirectionalShading, GetDither2(gl_FragCoord.xy));
    }
#endif
#if AU_PRESET < 2 && AU_GI_DENOISE
    float localOcclusion = 1.0, localSky = 1.0;
    vec3 localDirect = vec3(0.0);
    if (uHookPTPass != 5)
        AU_GIQuadFilter(playerPos, historyNormal, hasBloom, localLighting, localOcclusion, localSky, localDirect);
#if AU_GI_TEMPORAL_FILTER
    if (!hasBloom && uHookPTPass == 3)
        AU_GIAccumulate(texCoords, playerPos, historyNormal, localLighting, localOcclusion, localSky, localDirect,
                        GetLuminance(blockLight) + shadow * GetLuminance(lightColor) * max(dot(normal, lightVec), 0.0));
#endif
#endif
#if AU_PRESET >= 2
    // RTX: the GI rays double as ray-traced ambient occlusion.
    float giVisibility = 1.0;
    vec3 gi = vec3(0.0);
    auSSSUseGI = true;
    vec3 ptLight = vec3(0.0);
    float skyVis = 1.0;
    if (!hasBloom) {
        {
#if AU_VOXELS
            gi = AU_GetVoxelGI(uDepthTexture, playerPos, normal, skyLight, giVisibility, skyVis);
#elif AU_HALF_RES_GI
            if (uHookVLPass == 2) { gi = halfResGI.rgb; giVisibility = halfResGI.a; }
            else gi = AU_GetSSGI(uDepthTexture, playerPos, normal, historyNormal, dither, giVisibility);
#else
            gi = AU_GetSSGI(uDepthTexture, playerPos, normal, historyNormal, dither, giVisibility);
#endif
        }
    }
#if AU_VOXELS
    gi = gi * AU_PT_GI_STRENGTH + localLighting + auSSSVolumeLight;
#else
    gi = gi * AU_RTX_GI_STRENGTH + localLighting + auSSSVolumeLight;
#endif
#if AU_GI_DENOISE
    if (uHookPTPass != 5) AU_GIQuadFilter(playerPos, historyNormal, hasBloom, gi, giVisibility, skyVis, ptLight);
#endif
    if (!hasBloom) {
#if AU_GI_DENOISE && AU_GI_TEMPORAL_FILTER
        if (uHookPTPass == 3)
            AU_GIAccumulate(texCoords, playerPos, historyNormal, gi, giVisibility, skyVis, ptLight,
                            GetLuminance(blockLight) + shadow * GetLuminance(lightColor) * max(dot(normal, lightVec), 0.0));
#endif
#if AU_VOXELS
        // Path-traced sky light: the ambient follows how much open sky the surface sees,
        // relative to an open field (a wall there sees half the sky, a floor all of it).
        // Hytale's flood-fill sky light already darkens rooms and caves, so the traced sky
        // light only adds what it misses where it counts as open (under steps, overhangs,
        // trees); applying both inside a room left it black.
        float ptSkyAmount = AU_PT_SKY_LIGHT * pow2(skyLight) * (subsurfaceMode != 0 ? 0.5 : 1.0);
        auPTSky = mix(1.0, clamp(skyVis / max(0.5 + 0.5 * normal.y, 0.15), 0.0, 1.0), ptSkyAmount);
#endif
        // AO darkens indirect light; where the sun hits, direct light dominates.
        aoUse *= mix(1.0, giVisibility, AU_RTX_GI_AO * (1.0 - 0.75 * shadow));
    }
#endif
#if AU_LOCAL_LIGHTS
    if (!hasBloom) {
        blockLight = AU_BlendLocalLightColour(blockLight, auLocalLightUnshadowed, GetLuminance(auLocalLightUnshadowed));
    }
#endif
    float smoothnessG = 0.0, highlightMult = 1.0;
    if (subsurfaceMode == 2) {
        // Green leaves get a soft sheen.
        // Keyed on green dominance (Hytale has bright yellow/autumn leaves that would max it out).
        vec3 leafCol = albedo / max(AU_ALBEDO_MULT, 0.01);
        float factor = min1(pow2(max0(leafCol.g - max(leafCol.r, leafCol.b) * 0.9)) * 5.0) * 0.6;
        smoothnessG = factor * 0.4;
        float fresnelL = clamp(1.0 + dot(normal, normalize(playerPos)), 0.0, 1.0);
        highlightMult = (factor * 4.0 + 2.0) * (1.0 - pow2(pow2(fresnelL)));
    }
    // Ore crystals (the glowing texels of Hytale's REFLECTIVE blocks) are glossy like gems:
    // sharp sun glints here, reflections below.
    float crystal = mat.crystal;
    // Glossy materials and wet surfaces: sun glints (metals' brighter).
    if (matSmooth > 0.0) {
        smoothnessG = max(smoothnessG, 0.85 * matSmooth);
        highlightMult = max(highlightMult, 1.0 + (2.0 + 2.0 * metal) * matSmooth);
    }
    if (crystal > 0.0) {
        smoothnessG = max(smoothnessG, 0.8 * crystal);
        highlightMult = max(highlightMult, 1.0 + 3.0 * crystal);
    }
    smoothnessG = AU_SpecularSmoothness(smoothnessG, surfaceFootprint.x);
    // Plain surfaces (grass, dirt, wood, stone): only a faint sun sheen - more read as plastic.
    if (matSmooth <= 0.0 && crystal <= 0.0 && subsurfaceMode == 0) highlightMult *= 0.25;
    vec3 litAlbedo = albedo;
#if AU_PRESET >= 2
    litAlbedo *= 1.0 - 0.45 * metal;
#endif
    vec3 color = AU_DoLighting(litAlbedo, normal, playerPos, skyLight, blockLight, shadow, aoUse,
                               subsurfaceMode, emission, smoothnessG, highlightMult, noDirectionalShading);
    // Cloth and other models Hytale lights from both sides (no "clean backfaces"): the sun behind
    // them comes through, in the pattern of whatever stands in between - at dawn a curtain shows
    // the window's lattice behind it, like in Hytale. The shadow mask keeps the sun for these
    // faces (DeferredShadowFS only darkens the back of solid blocks); a solid model's own body
    // shadows its far side in the shadow map.
    if (!useCleanShadowBackfaces && subsurfaceMode == 0 && !hasBloom && dot(normal, lightVec) < 0.0) {
        float back = -dot(normal, lightVec);
        color += litAlbedo * lightColor * (shadow * shadowTime * sunVisibility * mix(0.4, 1.0, back) * AU_CLOTH_TRANSMIT);
    }
    // Emissive texels (flames, potions, lava) look like Hytale's: texture colour times the
    // light stored with them (models keep their glow tint there), unshadowed - mapped through
    // the inverse of the tonemap so they come out in that colour instead of washing to white.
    // Their glow is the bloom (BloomSelectFS boosts them).
    // (Capped below 1: right at the top of the curve the inverse explodes, and the tonemap's
    // path to white and the bloom would wash the texel out again.)
    if (hasBloom) color = AU_InverseTonemap(pow(clamp(gbuffer0.rgb * rawStaticLight * (AU_EMISSION_STRENGTH / 3.0), 0.0, 0.92), vec3(2.2)));
    // Glowing ores: the glow lights the crystal evenly - the texture's dark/light contrast is
    // compressed (its colour kept) so it doesn't turn grainy - strongest on the facets facing
    // the camera, so the crystal keeps its shape - and keeps its hue: the brightest channel is
    // eased off softly.
    if (oreGlow) {
        float oreLum = max(GetLuminance(albedo), 0.002);
        float facing = clamp(-dot(normal, normalize(playerPos)), 0.0, 1.0);
        color += albedo * pow(oreLum, -0.5) * (AU_ORE_GLOW_STRENGTH * 0.5 * oreGlowAmount * mix(0.35, 1.0, facing * facing) * AU_OrePulse(gbuffer0.rgb));
        float mx = max(color.r, max(color.g, color.b));
        const float knee = 1.0;
        if (mx > knee) {
            float room = AU_EMISSIVE_MAX - knee;
            color *= (knee + room * (1.0 - exp(-(mx - knee) / room))) / mx;
        }
    }

#if AU_PRESET >= 2
    // RTX preset: screen-space GI bounce + glossy reflections on solid surfaces.
    if (!hasBloom) {
#if AU_GI_DENOISE
        color = AU_AddIndirectLight(color, albedo, gi, uHookPTPass == 5);
#else
        color += albedo * gi;
#endif

        vec3 nView = normalize(playerPos);
        // A rain film reflects off the flat block face, not the texture relief under it.
        vec3 reflNormal = AU_MaterialReflectionNormal(normal, mat);
        float fresnel = clamp(1.0 + dot(reflNormal, nView), 0.0, 1.0);
        // Faint grazing sheen on solids (off by default), glossy materials and the rain film.
        float smoothness = subsurfaceMode == 1 || subsurfaceMode == 2 ? 0.0 : AU_RTX_SMOOTHNESS;
        smoothness = max(smoothness, max(0.85 * crystal, matSmooth));
        smoothness = AU_SpecularSmoothness(smoothness, surfaceFootprint.x);
        // Dielectrics reflect a little head-on (gems a bit more); metals mostly reflect, in
        // their own colour.
        float f0 = max(0.06 * crystal, matSmooth > 0.0 ? 0.04 : 0.0);
        float fresnelM = (f0 + (1.0 - f0) * pow(fresnel, 5.0)) * smoothness;
        fresnelM = mix(fresnelM, smoothness * (0.6 + 0.4 * pow(fresnel, 5.0)), metal);
        if (fresnelM > 0.004) {
            vec3 rdir = reflect(nView, reflNormal);
            vec3 skyRef = GetSky(rdir.y, dot(rdir, sunVec), dither, true, true) * pow2(skyLight);
            vec4 ssr = AU_GetSSR(uDepthTexture, playerPos, reflNormal, 1.0 - smoothness, dither);
            vec3 refl = mix(skyRef, ssr.rgb, ssr.a) * mix(vec3(1.0), albedo * 1.7, metal);
            color = mix(color, refl, fresnelM);
        }
    }
#endif

#if AU_RAIN_PUDDLES
    // Rain puddles: blotchy puddles on open, upward faces while the world is
    // wet (uHookWetness lingers after the rain), rippling while it rains, mirror reflections.
    if (!hasBloom && subsurfaceMode == 0 && IsCameraUnderwater < 0.5) {
        float wetM = max(uHookWetness, rainFactor);
        float glow = max(blockLight.r, max(blockLight.g, blockLight.b)) * AU_BLOCKLIGHT_RANGE;
        float puddleMixer = smoothstep(0.93, 0.99, skyLight) * clamp((1.0 - 1.15 * glow) * 10.0, 0.0, 1.0)
                          * pow2(max0(normal.y - 0.5) * 2.0) * pow2(pow2(wetM));
        if (puddleMixer > 0.00001) {
            vec3 worldPos = playerPos + CameraPosition;
            vec2 puddlePosNormal = worldPos.xz * 0.1;
            vec2 puddlePosForm = puddlePosNormal * 0.05;
            float pFormNoise = textureLod(noisetex, puddlePosForm, 0.0).b * 3.0
                             + textureLod(noisetex, puddlePosForm * 0.5, 0.0).b * 5.0
                             + textureLod(noisetex, puddlePosForm * 0.25, 0.0).b * 8.0;
            pFormNoise *= sqrt1(wetM) * 0.5625 + 0.4375;
            puddleMixer *= clamp(pFormNoise - 7.0, 0.0, 1.0) * AU_RAIN_PUDDLE_STRENGTH;
            // Puddles are a close-up detail: far away at grazing angles they only read as pale
            // sky-coloured patches on the grass (snow-like), so fade them out with distance.
            puddleMixer *= 1.0 - smoothstep(40.0, 90.0, length(playerPos));

            vec2 puddleWind = vec2(uHookTime) * 0.03;
            vec3 pn1 = textureLod(noisetex, puddlePosNormal + puddleWind, 0.0).rgb;
            vec3 pn2 = textureLod(noisetex, puddlePosNormal + vec2(puddleWind.x * -1.5, puddleWind.y * -1.0), 0.0).rgb;
            vec2 pnXZ = (pn1.xy + pn2.xy - vec2(1.0)) * 0.03 * rainFactor;
            vec3 puddleNormal = normalize(vec3(pnXZ.x, 1.0, pnXZ.y));

            if (puddleMixer > 0.001) {
                vec3 nViewP = normalize(playerPos);
                float pFresnel = clamp(1.0 + dot(puddleNormal, nViewP), 0.0, 1.0);
                float pFresnelM = (pow2(pow2(pFresnel)) * 0.6 + 0.04) * puddleMixer;
                vec3 rdir = reflect(nViewP, puddleNormal);
                // The overcast rain sky is near white; reflected at full strength it turns grazing
                // puddles into a milky film, so the murky water dims it.
                vec3 skyRef = GetSky(rdir.y, dot(rdir, sunVec), dither, true, true) * pow2(skyLight) * 0.6;
                vec4 ssr = AU_GetSSR(uDepthTexture, playerPos, puddleNormal, 0.05, dither);
                color *= 1.0 - 0.35 * puddleMixer;   // wet ground is darker
                color = mix(color, mix(skyRef, ssr.rgb, ssr.a), pFresnelM);
            }
        }
    }
#endif

#if AU_PRESET < 2 && AU_LOCAL_LIGHTS
    if (!hasBloom) color += albedo * localLighting;
#endif

#if AU_BIOME_ATMOSPHERE
#if USE_FOG
    vec4 biomeFogParams = FogParams;
    if (biomeFogParams.y > 0.0 && biomeFogParams.y - biomeFogParams.x < 0.0001)
        biomeFogParams.x = biomeFogParams.y - 0.0001;
    vec4 biomeFog = computeFog(playerPos, CameraPosition, SunPositionWS,
                              FogTopColor.rgb, FogFrontColor.rgb, FogBackColor.rgb, biomeFogParams, FogMoodParamsA, FogHeightDensityAtViewer,
                              texCoords, uFogNoiseTexture, SceneBrightness.r);
    AU_ApplyBiomeFog(color, biomeFog);
#endif
#else
    DoAUFog(color, playerPos, dither, skyLight);
#endif
    AU_ApplyMist(color, playerPos, dither);
#if AU_LOCAL_LIGHTS && AU_LIGHT_FOG
    color += AU_LightFog(playerPos, dither, GetDither2(gl_FragCoord.xy + vec2(91.0, 13.0)));
#endif
    color += AU_GetRainbow(playerPos / max(length(playerPos), 0.0001), length(playerPos), false, dither);

    // Volumetric light shafts in front of this surface.
    float lViewPos = length(playerPos);
    vec4 halfResVL = vec4(0.0);
#if AU_LIGHTSHAFTS
    if (uHookVLPass == 2) halfResVL = AU_UpsampleVL(texCoords, lViewPos);
#endif
    color = AU_AddVL(color, halfResVL.a > 0.0 ? halfResVL.rgb : GetVolumetricLight(playerPos / max(lViewPos, 0.0001), lViewPos, false, dither));

#if AU_DEBUG_CLASS == 11
    color = gbuffer0.rgb;
#elif AU_DEBUG_CLASS == 9 && AU_GI_DENOISE
    color = auGIDiagnostic;
#elif AU_DEBUG_CLASS == 1
    color = vec3(hasBloom ? 1.0 : 0.0, subsurfaceMode != 0 ? 1.0 : 0.0, hasSSAO ? 0.6 : 0.0) * 0.5 + shadow * 0.15;
#elif AU_DEBUG_CLASS == 2
    color = vec3(shadow);
#elif AU_DEBUG_CLASS == 3
    // red: sun visibility, green: sky light (gamma-encoded for reading)
    color = sqrt(vec3(shadow, skyLight, 0.0)) * 0.6;
#elif AU_DEBUG_CLASS == 6
    color = vec3(GetEyeBrightness());
#elif AU_DEBUG_CLASS == 7
    color = sqrt(GetVolumetricLight(playerPos / max(lViewPos, 0.0001), lViewPos, false, dither) * 3.0);
#elif AU_DEBUG_CLASS == 8
    // Materials: red polished, white metal, blue porous (brighter = higher level); green ore glow.
    color = (matClass == 1u ? vec3(1.0, 0.1, 0.1) : matClass == 2u ? vec3(1.0) : matClass == 3u ? vec3(0.1, 0.3, 1.0) : vec3(0.0))
          * (0.3 + 0.7 * matLevel) + vec3(0.0, oreGlowAmount, 0.0);
#elif AU_DEBUG_CLASS == 4
    color = fragTexCoords.x < 0.5 ? rawStaticLight : blockLight;
#endif
#if AU_VOXELS && (AU_VOXEL_DEBUG == 1 || AU_VOXEL_DEBUG == 2)
    {
        // Voxel grid debug: what the path tracer sees, cast from the camera. Magenta = block
        // never seen on screen (no colour yet), green tint = leaves, blue tint = small model.
        ivec3 hb; vec3 hn; float ht; uint hv;
        vec3 dbg = vec3(0.02, 0.03, 0.08);
        if (AU_VoxTrace(CameraPosition, normalize(playerPos), 250.0, 512, 0.99, hb, hn, ht, hv)) {
            vec4 vc = AU_VoxGetColor(hb);
            vec3 base = vc.a > 0.5 ? vc.rgb : vec3(0.9, 0.1, 0.9);
            if ((hv & 3u) == AU_VOX_POROUS) base *= vec3(0.5, 1.0, 0.5);
            if ((hv & AU_VOX_SMALL) != 0u) base *= vec3(0.5, 0.6, 1.0);
            dbg = base * (0.3 + 0.7 * max(dot(hn, sunVec), 0.0) + 0.15 * hn.y) * 2.0;
        }
        color = AU_VOXEL_DEBUG == 1 ? dbg : mix(color, dbg, 0.5);
    }
#endif
#if AU_VOXELS && AU_PT_LIGHTS && AU_VOXEL_DEBUG == 3
    {
        // Light list probe: red = empty, green brighter with more lights.
        uint nl = imageLoad(auLights, ivec2(0, 0)).r;
        color = mix(color, nl == 0u ? vec3(1.0, 0.0, 0.0) : vec3(0.0, min(float(nl) / 8.0, 1.0), 0.0), 0.5);
    }
#elif AU_VOXELS && AU_PT_LIGHTS && AU_VOXEL_DEBUG == 4
    color = sqrt(ptLight) * 0.7;   // traced torch light only
#elif AU_VOXELS && AU_VOXEL_DEBUG == 6
    color = sqrt(gi * AU_RTX_GI_STRENGTH) * 0.8;   // incoming bounce light only (before the surface colour)
#elif AU_VOXELS && AU_PT_LIGHTS && AU_VOXEL_DEBUG == 5
    {
        // Distance to the nearest listed light: rings every 2 blocks, red beyond 32.
        int row = 0;
        uint nl = min(imageLoad(auLights, ivec2(0, row)).r, 64u);
        ivec3 base = ivec3(floor(CameraPosition)) - AU_VOX_HALF;
        float md = 1e9;
        for (uint k = 0u; k < nl; k++) {
            uint c = imageLoad(auLights, ivec2(1 + 2 * int(k), row)).r;
            ivec3 lb = base + ((ivec3(c & 255u, (c >> 8) & 127u, (c >> 15) & 255u) - base) & AU_VOX_MASK);
            md = min(md, distance(vec3(lb) + 0.5, playerPos + CameraPosition));
        }
        color = md > 32.0 ? vec3(0.5, 0.0, 0.0) : vec3(fract(md * 0.5), 1.0 - md / 32.0, 0.2);
    }
#endif
    // Meta for the bloom pass: 1 SSAO, 2 emissive, bits 2-4 ore glow level.
    uint oreLevel = uint(round(oreGlowAmount * 7.0));
    outColor = vec4(color, float((hasSSAO ? 1u : 0u) | (hasBloom ? 2u : 0u) | (oreLevel << 2)) / 255.0);
}
