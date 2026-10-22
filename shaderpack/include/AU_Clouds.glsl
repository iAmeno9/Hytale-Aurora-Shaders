// Aurora Shaders for Hytale - volumetric clouds.
// Two ray-marched cloud layers shaped by a tiling noise texture.

#ifndef AU_CLOUDS_GLSL
#define AU_CLOUDS_GLSL

#include "AU_Sky.glsl"

#ifndef AU_HAS_NOISETEX
#define AU_HAS_NOISETEX
uniform sampler2D noisetex;
#endif

float Noise3D(vec3 p, float lod)
{
    p.z = fract(p.z) * 128.0;
    float iz = floor(p.z);
    float fz = fract(p.z);
    vec2 a_off = vec2(23.0, 29.0) * (iz) / 128.0;
    vec2 b_off = vec2(23.0, 29.0) * (iz + 1.0) / 128.0;
    float a = textureLod(noisetex, p.xy + a_off, lod).r;
    float b = textureLod(noisetex, p.xy + b_off, lod).r;
    return mix(a, b, fz);
}

float Noise3D(vec3 p)
{
    return Noise3D(p, 0.0);
}

const float cloudStretch = 16.0;
const float cloudNarrowness = 0.00012;
const float cloudTallness = cloudStretch * 2.0;

vec3 cloudAmbientColor, cloudLightColor;

void InitCloudColors()
{
    vec3 cloudRainColor = mix(nightMiddleSkyColor, dayMiddleSkyColor, sunFactor);
    cloudAmbientColor = mix(ambientColor * (sunVisibility2 * (0.55 + vec3(0.2, 0.1, 0.0) * noonFactor) + 0.35), cloudRainColor * 0.5, rainFactor);
    cloudLightColor = mix(lightColor * (1.3 + vec3(0.1, -0.1, -0.3) * noonFactor), cloudRainColor * 0.45, noonFactor * rainFactor);
#if AU_ATMOSPHERE_MODEL == 1 && !AU_BIOME_ATMOSPHERE
    vec3 skyAmbient = AU_AtmosphereSky(0.6, sunVec.y * 0.6, false);
    float ambientEnergy = GetLuminance(cloudAmbientColor);
    vec3 skyTint = clamp(skyAmbient / max(GetLuminance(skyAmbient), 0.001), vec3(0.25), vec3(2.0));
    cloudAmbientColor = mix(cloudAmbientColor, skyTint * ambientEnergy, 0.6);
#endif
#if AU_BIOME_ATMOSPHERE
    vec3 nativeTint = AU_BiomeCloudColour().rgb;
    cloudAmbientColor = nativeTint * 0.55;
    cloudLightColor = nativeTint * 0.45;
#endif
}

float GetCloudWind()
{
    return 0.0006 * Time * AU_CLOUD_SPEED;
}

float GetCloudNoise(vec3 tracePos, float cloudAltitude, float lTracePosXZ, float cloudPlayerPosY, float footprint, int octaves)
{
    vec3 tracePosM = tracePos.xyz * cloudNarrowness;
    float wind = GetCloudWind();
    float noise = 0.0;
    float currentPersist = 1.0;
    float total = 0.0;

    const float persistance = 0.5;
    float noiseMult = 1.14; // CLOUD_QUALITY 2, main (deferred1) path

    for (int i = 0; i < octaves; i++) {
        float lod = log2(max(footprint * cloudNarrowness * float(textureSize(noisetex, 0).x), 1.0));
        noise += Noise3D(tracePosM - vec3(0.0, 0.0, wind), lod) * currentPersist;
        total += currentPersist;
        tracePosM *= 3.0;
        wind *= 0.5;
        footprint *= 3.0;
        currentPersist *= persistance;
    }
    noise = pow2(noise / total);

    noiseMult *= 0.8
               + 0.1 * clamp01(-cloudPlayerPosY / cloudTallness)
               + 0.40 * rainFactor;
    noise *= noiseMult * AU_CLOUD_AMOUNT;

    float threshold = clamp(abs(cloudAltitude - tracePos.y) / cloudStretch, 0.001, 0.999);
    threshold = pow2(pow2(pow2(threshold)));
    return noise - (threshold * 0.2 + 0.25);
}

float GetCloudNoise(vec3 tracePos, float cloudAltitude, float lTracePosXZ, float cloudPlayerPosY, float footprint)
{
    return GetCloudNoise(tracePos, cloudAltitude, lTracePosXZ, cloudPlayerPosY, footprint, 4);
}

float GetCloudNoise(vec3 tracePos, float cloudAltitude, float lTracePosXZ, float cloudPlayerPosY)
{
    return GetCloudNoise(tracePos, cloudAltitude, lTracePosXZ, cloudPlayerPosY, 0.0);
}

vec2 AU_CloudInterval(float altitude, vec3 cameraPos, vec3 direction, float limit)
{
    if (abs(direction.y) < 0.000001) {
        return abs(cameraPos.y - altitude) < cloudStretch ? vec2(0.0, limit) : vec2(0.0);
    }
    vec2 distances = (vec2(altitude - cloudStretch, altitude + cloudStretch) - cameraPos.y) / direction.y;
    float entry = max(min(distances.x, distances.y), 0.0);
    float exitDistance = min(max(distances.x, distances.y), limit);
    return exitDistance > entry ? vec2(entry, exitDistance) : vec2(0.0);
}

void AU_CloudIntervals(vec3 cameraPos, vec3 direction, float limit, out vec2 nearRange, out vec2 farRange)
{
    nearRange = AU_CloudInterval(AU_CLOUD_ALT1, cameraPos, direction, limit);
    farRange = vec2(0.0);
#if AU_CLOUD_LAYERS > 1
    farRange = AU_CloudInterval(AU_CLOUD_ALT2, cameraPos, direction, limit);
    if (nearRange.y <= nearRange.x || (farRange.y > farRange.x && farRange.x < nearRange.x)) {
        vec2 swapRange = nearRange;
        nearRange = farRange;
        farRange = swapRange;
    }
    if (farRange.y > farRange.x && farRange.x <= nearRange.y) {
        nearRange.y = max(nearRange.y, farRange.y);
        farRange = vec2(0.0);
    }
#endif
}

ivec2 AU_CloudSampleCounts(vec2 nearRange, vec2 farRange)
{
    vec2 spans = vec2(nearRange.y - nearRange.x, farRange.y - farRange.x);
    float totalSpan = spans.x + spans.y;
    if (totalSpan <= 0.0) return ivec2(0);
    int budget = 96;
    float densityCost = 1.0;
#if AU_CLOUD_LAYERS > 1
    if (abs(AU_CLOUD_ALT1 - AU_CLOUD_ALT2) < cloudTallness) densityCost = 2.0;
#endif
#if AU_CLOUD_LIGHTING == 1
    densityCost += 0.5 * float(clamp(AU_CLOUD_LIGHT_SAMPLES, 1, 2));
#endif
    budget = int(float(budget) / densityCost);
    int nearCount = spans.x > 0.0 ? int(clamp(ceil(spans.x / max(AU_CLOUD_STEP, 1.0)), 1.0, float(budget))) : 0;
    int farCount = spans.y > 0.0 ? int(clamp(ceil(spans.y / max(AU_CLOUD_STEP, 1.0)), 1.0, float(budget))) : 0;
    if (nearCount + farCount > budget) {
        nearCount = int(clamp(floor(float(budget) * spans.x / totalSpan + 0.5), 1.0, float(budget - 1)));
        farCount = budget - nearCount;
    }
    return ivec2(nearCount, farCount);
}

float AU_CloudDensity(vec3 position, float altitude, float footprint)
{
    float edge = cloudStretch - abs(position.y - altitude);
    if (edge <= 0.0) return 0.0;
    return max(GetCloudNoise(position, altitude, 0.0, 0.0, footprint), 0.0) * smoothstep(0.0, 2.0, edge);
}

float AU_CloudLightDensity(vec3 position, float altitude, float footprint)
{
    float edge = cloudStretch - abs(position.y - altitude);
    if (edge <= 0.0) return 0.0;
    vec3 coordinates = position * cloudNarrowness;
    float wind = GetCloudWind();
    float lod = log2(max(footprint * cloudNarrowness * float(textureSize(noisetex, 0).x), 1.0));
    float noise = (Noise3D(coordinates - vec3(0.0, 0.0, wind), lod)
        + 0.5 * Noise3D(coordinates * 3.0 - vec3(0.0, 0.0, wind * 0.5), lod + log2(3.0))) / 1.5;
    float threshold = pow2(pow2(pow2(clamp(abs(position.y - altitude) / cloudStretch, 0.001, 0.999))));
    float density = pow2(noise) * 1.14 * (0.8 + 0.4 * rainFactor) * AU_CLOUD_AMOUNT - (threshold * 0.2 + 0.25);
    return max(density, 0.0) * smoothstep(0.0, 2.0, edge);
}

vec3 AU_CloudSampleLight(vec3 position, float altitude, float density, float alignment, float footprint)
{
    float height = clamp01((position.y - altitude + cloudStretch) / cloudTallness);
#if AU_CLOUD_LIGHTING == 1
    const int lightSamples = clamp(AU_CLOUD_LIGHT_SAMPLES, 1, 2);
    vec2 interval = AU_CloudInterval(altitude, position, lightVec, 96.0);
    float lightStep = interval.y / float(lightSamples);
    float opticalDepth = 0.0;
    for (int sampleIndex = 0; sampleIndex < lightSamples; sampleIndex++) {
        vec3 lightPosition = position + lightVec * ((float(sampleIndex) + 0.5) * lightStep);
        opticalDepth += AU_CloudLightDensity(lightPosition, altitude, max(footprint, lightStep * 0.35)) * lightStep * 0.25;
    }
    float transmission = exp(-opticalDepth);
    float forwardScatter = pow(max(alignment, 0.0), 12.0);
    float rim = forwardScatter * exp(-density * 12.0) * invRainFactor;
    float diffuse = 0.18 + 0.3 * height + transmission * (0.5 + 0.6 * forwardScatter);
    return cloudAmbientColor * (0.55 + 0.3 * height + 0.15 * exp(-opticalDepth * 0.25))
        + cloudLightColor * (diffuse + 0.6 * rim);
#else
    float forwardScatter = max(alignment, 0.0);
    float scatter = pow2(forwardScatter) * abs(sunVisibility - 0.5) * 2.0 * (2.5 + rainFactor) + 1.5 * rainFactor;
    float shading = height * (1.0 + 0.2 * scatter * (1.0 - min1(density * 8.0))
        + pow(forwardScatter * invRainFactor, 100.0) * sunVisibility);
    return cloudAmbientColor * (0.4 + 0.6 * shading) + cloudLightColor * shading;
#endif
}

vec4 AU_MarchCloudInterval(vec2 interval, int sampleCount, vec3 cameraPos, vec3 direction,
                          float skyFade, vec3 skyLight, float alignment, float incomingOpacity)
{
    vec4 accumulation = vec4(0.0);
    if (sampleCount <= 0) return accumulation;
    float stepLength = (interval.y - interval.x) / float(sampleCount);
    float footprint = stepLength * 0.35;
    for (int sampleIndex = 0; sampleIndex < 96; sampleIndex++) {
        if (sampleIndex >= sampleCount) break;
        float distanceAlongRay = interval.x + (float(sampleIndex) + 0.5) * stepLength;
        vec3 position = cameraPos + direction * distanceAlongRay;
        float altitude = AU_CLOUD_ALT1;
        float density = AU_CloudDensity(position, altitude, footprint);
#if AU_CLOUD_LAYERS > 1
        float secondDensity = AU_CloudDensity(position, AU_CLOUD_ALT2, footprint);
        if (secondDensity > density) { density = secondDensity; altitude = AU_CLOUD_ALT2; }
#endif
        if (density <= 0.00001) continue;
        float distanceRatio = clamp01(1.0 - distanceAlongRay * length(direction.xz) / max(AU_CLOUD_DISTANCE, 1.0));
        float distanceFade = smoothstep(0.0, 0.2, distanceRatio);
        float sampleOpacity = 1.0 - exp(-min1(density * 8.0) * stepLength * distanceFade / 32.0);
        vec3 sampleLight = AU_CloudSampleLight(position, altitude, density, alignment, footprint);
        float aboveClouds = clamp01((cameraPos.y - altitude + cloudStretch) * 0.01);
        float fade = mix(skyFade, 1.0, 0.4 * max(aboveClouds, rainFactor2));
        float haze = mix(1.0, distanceRatio * distanceRatio * distanceRatio * 0.69, fade);
        sampleLight *= 1.0 - 0.2 * (1.0 - fade) * max(sunVisibility2, nightFactor);
        sampleLight = mix(skyLight, sampleLight, haze * 0.69);
        sampleOpacity *= 0.5 + 0.5 * fade;
        float weight = (1.0 - accumulation.a) * sampleOpacity;
        accumulation.rgb += sampleLight * weight;
        accumulation.a += weight;
        if ((1.0 - incomingOpacity) * (1.0 - accumulation.a) < 0.005) break;
    }
    return accumulation;
}

// Shadow of the volumetric cloud layer on a surface (1 = no cloud), sampling the same noise
// the sky renders, where the light ray crosses the middle of the layer.
float CloudShadowDistance(float viewerHeight, float sampleHeight, float lightElevation)
{
    const float curvatureRadius = 65536.0;
    float height = max(sampleHeight - viewerHeight, 0.0);
    float radialDistance = max(curvatureRadius + viewerHeight, 1.0);
    float projectedRadius = radialDistance * max(lightElevation, 0.0);
    float shellDifference = height * (2.0 * radialDistance + height);
    return shellDifference / max(sqrt(projectedRadius * projectedRadius + shellDifference) + projectedRadius, 0.0001);
}

float AU_CloudLayerShadow(vec3 worldPos, float altitude, int sampleCount)
{
    float lowerHeight = max(worldPos.y, altitude - cloudStretch);
    float upperHeight = altitude + cloudStretch;
    if (lowerHeight >= upperHeight) return 0.0;
    float entryDistance = CloudShadowDistance(worldPos.y, lowerHeight, lightVec.y);
    float exitDistance = CloudShadowDistance(worldPos.y, upperHeight, lightVec.y);
    float sampleSpan = (exitDistance - entryDistance) / float(sampleCount);
    float layerWeight = (upperHeight - lowerHeight) / cloudTallness;
    float opticalDepth = 0.0;
    for (int sampleIndex = 0; sampleIndex < sampleCount; sampleIndex++) {
        float fraction = (float(sampleIndex) + 0.5) / float(sampleCount);
        float alt = mix(lowerHeight, upperHeight, fraction);
        float t = CloudShadowDistance(worldPos.y, alt, lightVec.y);
        vec3 cloudPos = worldPos + lightVec * t;
        cloudPos.y = alt;
        float footprint = max(t * 0.0093, max(sampleSpan, 8.0));
        // Seen from the ground through hundreds of blocks of cloud, the two finest octaves only
        // sharpen the shadow's edge; they cost as much per pixel as the shapes themselves.
        float noise = GetCloudNoise(cloudPos, altitude, 0.0, 0.0, footprint, 2);
        opticalDepth += max(noise, 0.0) * layerWeight * (2.0 / float(sampleCount));
    }
    return opticalDepth;
}

float GetCloudShadow(vec3 playerPos)
{
#if AU_CLOUDS && AU_CLOUD_SHADOWS
    float horizonWeight = smoothstep(0.0, 0.08, lightVec.y);
    if (horizonWeight <= 0.0) return 1.0;
    float modFactor = floor(1.0 / cloudNarrowness);
    vec3 cameraPos = vec3(mod(CameraPosition.x, modFactor), CameraPosition.y, mod(CameraPosition.z, modFactor));
    vec3 worldPos = playerPos + cameraPos;
    float opticalDepth;
#if AU_CLOUD_LAYERS > 1
    bool firstActive = worldPos.y < AU_CLOUD_ALT1 + cloudStretch;
    bool secondActive = worldPos.y < AU_CLOUD_ALT2 + cloudStretch && abs(AU_CLOUD_ALT1 - AU_CLOUD_ALT2) > 0.01;
    int layerSamples = firstActive && secondActive ? 2 : 4;
    opticalDepth = AU_CloudLayerShadow(worldPos, AU_CLOUD_ALT1, layerSamples);
    if (secondActive) opticalDepth += AU_CloudLayerShadow(worldPos, AU_CLOUD_ALT2, layerSamples);
#else
    opticalDepth = AU_CloudLayerShadow(worldPos, AU_CLOUD_ALT1, 4);
#endif
    float shadow = exp(-3.0 * opticalDepth);
#if AU_BIOME_ATMOSPHERE
    return mix(1.0, shadow, horizonWeight * AU_CLOUD_SHADOW_STRENGTH * AU_BiomeCloudColour().a);
#else
    return mix(1.0, shadow, horizonWeight * AU_CLOUD_SHADOW_STRENGTH);
#endif
#else
    return 1.0;
#endif
}

vec4 GetClouds(vec3 nPlayerPos, float lViewPos, float skyFade, float VdotS, float VdotU, float dither)
{
    InitCloudColors();
    float limit = min(max(lViewPos, 0.0), AU_CLOUD_DISTANCE / max(length(nPlayerPos.xz), 0.0001));

    // Keep the trace coordinates small (the noise tiles every 1 / cloudNarrowness blocks).
    float modFactor = floor(1.0 / cloudNarrowness);
    vec3 cameraPos = vec3(mod(CameraPosition.x, modFactor), CameraPosition.y, mod(CameraPosition.z, modFactor));

    vec2 nearRange, farRange;
    AU_CloudIntervals(cameraPos, nPlayerPos, limit, nearRange, farRange);
    ivec2 sampleCounts = AU_CloudSampleCounts(nearRange, farRange);
    float alignment = sunVisibility > 0.5 ? VdotS : -VdotS;
    vec4 clouds = vec4(0.0);
    if (sampleCounts.x + sampleCounts.y > 0) {
        vec3 skyLight = GetSky(VdotU, VdotS, 0.5, IsCameraUnderwater < 0.5, false);
        clouds = AU_MarchCloudInterval(nearRange, sampleCounts.x, cameraPos, nPlayerPos, skyFade, skyLight, alignment, 0.0);
        if (clouds.a < 0.995 && sampleCounts.y > 0) {
            vec4 farClouds = AU_MarchCloudInterval(farRange, sampleCounts.y, cameraPos, nPlayerPos, skyFade, skyLight, alignment, clouds.a);
            clouds += farClouds * (1.0 - clouds.a);
        }
    }
    if (clouds.a <= 0.00001) return vec4(0.0);
    if (clouds.a > 0.00001) clouds.rgb /= clouds.a;
    return clouds;
}

#endif
