        // ---- Aurora water ----
        vec2 screenUV = gl_FragCoord.xy * uCurrentInvViewportSize;
        float depth = -texture(uDepthTexture, screenUV).r;
        float skyL = clamp(fragStaticLight.a, 0.0, 1.0);
        float lViewPos = length(fragPositionWS);
        vec3 nViewPos = fragPositionWS / max(lViewPos, 0.0001);
        bool isTopFace = abs(normalWS.y) > 0.8;
        float signY = normalWS.y >= 0.0 ? 1.0 : -1.0;

        // Waves from the cloud-water normal map, with parallax
        vec3 worldPos = fragPositionWS + CameraPosition;
        float rawWind = Time * 1.10 * 0.018;
        vec2 wind = vec2(0.0, -rawWind);
        vec2 waterPos = 0.032 * (worldPos.xz + worldPos.y * 2.0);
        vec2 waterPosM = waterPos * 2.5;
        vec2 windM = wind * 2.5;
        float fresnel0 = clamp(1.0 + dot(normalWS, nViewPos), 0.0, 1.0);
        vec3 normalM = normalWS;
        vec2 normalMed = vec2(0.0), normalSmall = vec2(0.0), nm = vec2(0.0);
        if (isTopFace) {
            vec3 viewTS = vec3(nViewPos.x, nViewPos.z, nViewPos.y * signY);
            vec2 parallaxMult = -0.01 * viewTS.xy / min(viewTS.z, -0.05);
            for (int i = 0; i < 4; i++) {
                waterPosM += parallaxMult * texture(cloudWaterTex, waterPosM - windM).a;
                waterPosM += parallaxMult * texture(cloudWaterTex, waterPosM * 0.25 - 0.5 * windM).a;
            }
            normalMed = texture(cloudWaterTex, waterPosM + windM).rg - 0.5;
            normalSmall = texture(cloudWaterTex, waterPosM * 4.0 - 2.0 * windM).rg - 0.5;
            vec2 normalBig = texture(cloudWaterTex, waterPosM * 0.25 - 0.5 * windM).rg - 0.5;
            normalBig += texture(cloudWaterTex, waterPosM * 0.05 - 0.05 * windM).rg - 0.5;
            nm = normalMed * 1.70 + normalSmall * 0.75 + normalBig * 2.00;
            nm *= 6.0 * (1.0 - 0.7 * fresnel0) * 1.25 * 0.8;
            nm *= 0.03 * skyL + 0.01;
            vec3 normalMap = vec3(nm, sqrt(max(1.0 - dot(nm, nm), 0.0)));
            normalM = normalize(vec3(normalMap.x, normalMap.z * signY, normalMap.y));
            vec3 refl = reflect(nViewPos, normalM);
            float norMix = pow2(pow2(pow2(1.0 - max0(dot(normalWS, refl))))) * 0.5;
            normalM = normalize(mix(normalM, normalWS, norMix));
        }
        float fresnel = clamp(1.0 + dot(normalM, nViewPos), 0.0, 1.0);
        float fresnel4 = pow2(pow2(fresnel));

        // Colour
        vec3 glColor = max(fragTintColorFixed, vec3(0.0));
        vec3 glColorM = glColor;
        glColorM.g = max(glColorM.g, 0.39);
        glColorM = sqrt(glColorM) * vec3(1.0, 0.85, 0.8);
        vec3 waterAlbedo = 0.375 * glColorM;
        vec3 translucentMult = normalize(sqrt(sqrt(glColor + 0.0001)));
        translucentMult.g *= 0.88;
        float noise = (texture(noisetex, (waterPos + wind) * 0.25).g - 0.5) * 0.25;
        waterAlbedo = pow(waterAlbedo, vec3(1.0 + noise));

        // Distance from the surface to whatever is behind it
        float deltaZ = fragPositionVS.z - depth * FarClipPlane;

        // Refraction
        // Refraction: a slow, smooth noise wobble that shrinks
        // with distance, not the detailed wave normals (those shred the floor into grain).
        vec2 worldPosRM = worldPos.xz * 0.02 + worldPos.y * 0.01 + 0.01 * Time;
        vec2 refractNoise = textureLod(noisetex, worldPosRM, 0.0).rb - vec2(0.5);
        refractNoise *= AU_WATER_REFRACTION * ProjectionMatrix[1][1] / (3.0 + lViewPos) * 0.02;
        vec2 refractedUV = screenUV + refractNoise * clamp(deltaZ, 0.0, 1.0);
        float refractedDepth = -texture(uDepthTexture, refractedUV).r;
        float deltaZRefracted = fragPositionVS.z - refractedDepth * FarClipPlane;
        if (deltaZRefracted > 0.0) { deltaZ = deltaZRefracted; } else { refractedUV = screenUV; refractedDepth = depth; }
        float dist = max(deltaZ, 0.0) * lViewPos / max(-fragPositionVS.z, 0.001);
        float waterFog = 1.0 - exp(-dist * 0.075 * AU_WATER_FOG_MULT);
        vec3 background = textureLod(uRefractionTexture, refractedUV, 0.0).rgb;

        vec3 floorVS = PositionFromLinearDepth(refractedUV, refractedDepth * FarClipPlane, ProjInfos);
        vec3 floorFromCamWS = mat3(InvViewMatrix) * floorVS;
#if USE_UNDERWATER_CAUSTICS
        if (uWaterQuality >= 2 && IsCameraUnderwater <= 0.0 && lViewPos < 64.0) {
            vec3 floorWS = floorFromCamWS + CameraPosition;
            float caustics = computeCaustics(uCausticsTexture, WaterCausticsIntensity, WaterCausticsScale, WaterCausticsDistortion,
                                             floorWS.xz * WaterCausticsScale, vec2(WaterCausticsAnimTime), floorWS, floorFromCamWS,
                                             lViewPos, 1.0 / 64.0) * skyL;
            background += background * caustics * 1.35 * shadowTime;
        }
#endif

        float alpha = 0.98 * (0.25 + 0.75 * waterFog);
        float reflectMult = 1.0;

        // Foam where the floor is just below the surface
        float foam = 0.0;
        if (normalWS.y > 0.99 && IsCameraUnderwater < 0.5) {
            float yPosDif = floorFromCamWS.y - fragPositionWS.y;
            // Hytale shores are wide shallow sand flats, so the foam reaches less far
            // than it would on walls, and its strength is a setting.
            float foamThreshold = pow2(texture(noisetex, waterPos * 4.0 + wind * 0.5).g) * 1.6 * 0.6;
            foam = pow2(clamp((foamThreshold + yPosDif) / max(foamThreshold, 0.001), 0.0, 1.0));
            foam *= (0.4 + 0.25 * skyL) * AU_WATER_FOAM;
        }
        waterAlbedo = mix(waterAlbedo, vec3(0.9, 0.95, 1.05), foam);
        alpha = mix(alpha, 1.0, foam);
        reflectMult = 1.0 - foam;
        reflectMult *= 0.5 + 0.5 * max(normalWS.y, 0.0);
        alpha = mix(alpha, 1.0, fresnel4);

        // Sharp sun glint (smoothness 1)
        float highlightMult = 0.24;
        if (isTopFace) {
            vec2 lightNormalP = normalMed + 0.5 * normalSmall;
            vec3 lightNormal = normalize(vec3(lightNormalP.x, signY, lightNormalP.y));
            highlightMult = max0(dot(lightNormal, lightVec)) / max(dot(normalWS, lightVec), 0.17);
            highlightMult = pow2(pow2(highlightMult * 1.1));
            highlightMult = 0.24 * mix(highlightMult, 1.0, clamp(lViewPos / 160.0, 0.0, 1.0));
        }
        // Water blocks are in Hytale's shadow map; sample just above the block so it doesn't self-shadow.
        float wShadow = SampleShadowWS(fragPositionWS + normalWS * 0.7 + lightVec * 0.3, 1.0);
        vec3 wBlock = AU_ExtractBlockLight(fragStaticLight.rgb, skyL, normalWS, false);
        vec3 litWater = AU_DoLighting(waterAlbedo, normalM, fragPositionWS, skyL, wBlock, wShadow, 1.0, 0, 0.0, 1.0, highlightMult, true);

#if AU_WATER_MODEL == 1
        // Enhanced water: light is absorbed per colour along its path through the water - red
        // first, then green - with Hytale's water tint as the colour that survives longest, so
        // shallow edges stay clear and deep water takes the lake's own colour. The view path
        // through the water and the light's path down to the bed are separate: the bed of a deep
        // pool is dim even where the water above it is thin to look through at a steep angle.
        // What the water absorbs on the way is replaced by the light it scatters (litWater).
        vec3 auAbsorb = AU_WaterAbsorption(glColor);
        vec3 auViewT = AU_WaterTransmittance(auAbsorb, dist);
        float auDepthBelow = isTopFace ? max(fragPositionWS.y - floorFromCamWS.y, 0.0) : dist;
        vec3 auBedT = AU_WaterTransmittance(auAbsorb, AU_WaterBedPath(auDepthBelow, lightVec));
#endif
        if (IsCameraUnderwater > 0.5) {
            background *= 1.0 - 0.9 * max(0.5 * sqrt(fresnel4), fresnel4);
            reflectMult = 0.5;
            alpha = 0.15;
        } else {
#if AU_WATER_MODEL != 1
            background *= translucentMult;
#endif
        }

        // Reflections: Hytale's screen-space trace, procedural sky as fallback
        vec3 reflectDir = reflect(nViewPos, normalM);
        vec3 skyRef = GetSky(reflectDir.y, dot(reflectDir, sunVec), auDither, true, true) * pow2(skyL);
        vec3 reflection = skyRef;
        float fresnelM = (auPow3(fresnel) * 0.85 + 0.15) * reflectMult;
        if (uWaterQuality >= 2 && fresnelM > 0.02) {
            vec3 rayVS = normalize(mat3(ViewMatrix) * reflectDir);
            vec4 ssr = AU_WaterSSR(uDepthTexture, uRefractionTexture, fragPositionVS.xyz, rayVS, FarClipPlane, auDither);
            reflection = mix(skyRef, ssr.rgb, ssr.a);
        }
        // Order: the reflection is part of the (translucent) water surface,
        // which is then blended over what's behind it.
        vec3 auDbgBase = mix(background, litWater, alpha);
        vec3 surface = mix(litWater, reflection, fresnelM);
        vec3 waterColor = mix(background, surface, alpha);
        float auVLHidden = alpha;
#if AU_WATER_MODEL == 1
        if (IsCameraUnderwater < 0.5) {
            // The bed seen through the water, dimmed on both paths; the scattered water light in
            // place of what was absorbed; foam is opaque; then the surface reflection on top -
            // in shallow water as much as in deep (it is the surface that reflects).
            vec3 auOpacity = mix(1.0 - auViewT, vec3(1.0), max(foam, fresnel4));
            vec3 auBody = background * auBedT * (1.0 - auOpacity) + litWater * auOpacity;
            waterColor = mix(auBody, reflection, fresnelM * (1.0 - foam));
            auDbgBase = auBody;
            auVLHidden = dot(auOpacity, vec3(0.299, 0.587, 0.114));
        }
#endif
        outColor0.rgb = waterColor;
        if (IsCameraUnderwater < 0.5) AU_ApplyMist(outColor0.rgb, fragPositionWS, auDither);
        // The background already carries the shafts up to the riverbed; the water surface
        // hides part of them, so put that part back in front of it.
        if (IsCameraUnderwater < 0.5) {
            // DeferredFS traced these shafts at half resolution to the riverbed behind this pixel: close
            // enough for the part in front of the surface, and much cheaper than tracing them again.
            vec4 auTraced = AU_UpsampleVL(screenUV, length(floorFromCamWS));
            auForwardVL = (auTraced.a > 0.0 ? auTraced.rgb : GetVolumetricLight(nViewPos, lViewPos, false, auDither)) * auVLHidden;
        }
#if AU_DEBUG_WATER == 1
        outColor0.rgb = glColor;
#elif AU_DEBUG_WATER == 2
        outColor0.rgb = texColor.rgb;
#elif AU_DEBUG_WATER == 3
        outColor0.rgb = auDbgBase;
#elif AU_DEBUG_WATER == 4
        outColor0.rgb = reflection * fresnelM * alpha;
#elif AU_DEBUG_WATER == 6
        outColor0.rgb = vec3(wShadow, skyL, alpha);
#elif AU_DEBUG_WATER == 5
        outColor0.rgb = vec3(fresnelM);
#endif
