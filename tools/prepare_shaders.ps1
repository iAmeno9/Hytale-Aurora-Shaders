# Prepares shaderpack/ for the installed game version:
#   1. extracts Hytale's GLSL from HytaleClient.exe into shaderpack/original (the pack's overrides
#      include parts of it, and it cannot be redistributed, so every install pulls it from the
#      player's own game),
#   2. builds shaderpack/index.txt (unique source lines the hook uses to recognise each shader),
#   3. generates shaderpack/programs/MapChunkFS.glsl from the game's MapChunkFS + tools/mapchunk/*.
#
#   prepare_shaders.ps1 -Exe "<...>\Client\HytaleClient.exe"
#   prepare_shaders.ps1 -MapChunkOnly        (after editing tools/mapchunk/*.glsl)
param(
    [string]$Exe,
    [switch]$MapChunkOnly
)
$ErrorActionPreference = 'Stop'
if ($PSVersionTable.PSEdition -eq 'Core') {
    $prepareArguments = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $PSCommandPath)
    if ($Exe) { $prepareArguments += @('-Exe', $Exe) }
    if ($MapChunkOnly) { $prepareArguments += '-MapChunkOnly' }
    & powershell.exe @prepareArguments
    if ($LASTEXITCODE -ne 0) { throw 'Game shader preparation failed.' }
    return
}
$root = Split-Path $PSScriptRoot -Parent
$pack = Join-Path $root 'shaderpack'

Add-Type -Language CSharp -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text;
using System.Text.RegularExpressions;

public static class AuroraPrep
{
    static readonly UTF8Encoding Utf8 = new UTF8Encoding(false);

    // NativeAOT "NativeFormat" unsigned integer.
    static int Nu(byte[] d, ref int p)
    {
        int b0 = d[p];
        if ((b0 & 1) == 0) { p += 1; return b0 >> 1; }
        if ((b0 & 2) == 0) { int v = (b0 >> 2) | (d[p + 1] << 6); p += 2; return v; }
        if ((b0 & 4) == 0) { int v = (b0 >> 3) | (d[p + 1] << 5) | (d[p + 2] << 13); p += 3; return v; }
        if ((b0 & 8) == 0) { int v = (b0 >> 4) | (d[p + 1] << 4) | (d[p + 2] << 12) | (d[p + 3] << 20); p += 4; return v; }
        int r = BitConverter.ToInt32(d, p + 1); p += 5; return r;
    }

    static List<int> FindAll(byte[] d, byte[] pat)
    {
        var hits = new List<int>();
        byte first = pat[0];
        for (int i = Array.IndexOf(d, first); i >= 0 && i <= d.Length - pat.Length; i = Array.IndexOf(d, first, i + 1))
        {
            int k = 1;
            while (k < pat.Length && d[i + k] == pat[k]) k++;
            if (k == pat.Length) hits.Add(i);
        }
        return hits;
    }

    static bool StartsWithAt(byte[] d, int at, byte[] pat)
    {
        if (at < 0 || at + pat.Length > d.Length) return false;
        for (int k = 0; k < pat.Length; k++) if (d[at + k] != pat[k]) return false;
        return true;
    }

    // Returns the number of shader files written.
    public static int Extract(string exe, string outDir)
    {
        byte[] d = File.ReadAllBytes(exe);
        byte[] asm = Encoding.ASCII.GetBytes("HytaleClient, Version=1.0.0.0, Culture=neutral, PublicKeyToken=null");
        const string prefix = "HytaleClient.Graphics.Shaders.";
        var res = new List<Tuple<string, int, int>>();
        foreach (int m in FindAll(d, asm))
        {
            int p = m + asm.Length;
            int n = Nu(d, ref p);
            if (n <= 0 || n > 512 || p + n > d.Length) continue;
            string name = Encoding.ASCII.GetString(d, p, n);
            if (!name.StartsWith(prefix)) continue;
            int q = p + n;
            int off = Nu(d, ref q);
            int len = Nu(d, ref q);
            res.Add(Tuple.Create(name.Substring(prefix.Length), off, len));
        }
        if (res.Count == 0) throw new Exception("No shader resources found in " + exe);

        // The resources are stored back to back in one blob; find its start by checking which
        // "#version" occurrence makes the most vertex/fragment shaders start with "#version".
        byte[] ver = Encoding.ASCII.GetBytes("#version 410 core");
        var mains = res.Where(r => r.Item1.EndsWith("FS.glsl") || r.Item1.EndsWith("VS.glsl")).ToList();
        var first = mains.OrderBy(r => r.Item2).First();
        int bestBase = -1, bestScore = 0;
        foreach (int occ in FindAll(d, ver))
        {
            int b = occ - first.Item2;
            int score = mains.Count(r => StartsWithAt(d, b + r.Item2, ver));
            if (score > bestScore) { bestScore = score; bestBase = b; }
        }
        if (bestBase < 0 || bestScore < mains.Count / 2) throw new Exception("Could not locate the shader data in " + exe);

        Directory.CreateDirectory(outDir);
        foreach (var r in res)
        {
            if (bestBase + r.Item2 + r.Item3 > d.Length) continue;
            var data = new byte[r.Item3];
            Array.Copy(d, bestBase + r.Item2, data, 0, r.Item3);
            File.WriteAllBytes(Path.Combine(outDir, r.Item1), data);
        }
        return res.Count;
    }

    // For every main (non-include) shader: up to three source lines found in no other shader.
    // The hook hashes each line of a runtime shader and identifies it by these.
    public static int BuildIndex(string origDir, string outPath)
    {
        var files = Directory.GetFiles(origDir, "*.glsl").OrderBy(f => Path.GetFileName(f), StringComparer.Ordinal).ToList();
        var text = files.ToDictionary(f => Path.GetFileName(f), f => File.ReadAllText(f, Utf8));
        var included = new HashSet<string>();
        foreach (var t in text.Values)
            foreach (Match m in Regex.Matches(t, "#include\\s*\"([^\"]+)\"")) included.Add(m.Groups[1].Value);
        var lines = text.ToDictionary(kv => kv.Key, kv => new HashSet<string>(
            kv.Value.Split('\n').Select(l => l.Trim()).Where(l => l.Length > 0)));
        var count = new Dictionary<string, int>();
        foreach (var set in lines.Values)
            foreach (var l in set) { int c; count[l] = count.TryGetValue(l, out c) ? c + 1 : 1; }
        var outLines = new List<string>();
        foreach (var name in text.Keys.Where(n => !included.Contains(n)))
        {
            var sigs = lines[name]
                .Where(l => count[l] == 1 && l.Length >= 20 && !l.Contains('\t')
                            && !l.StartsWith("#include") && !l.StartsWith("#version"))
                .OrderBy(l => l.StartsWith("//") ? 1 : 0).ThenByDescending(l => l.Length).ThenBy(l => l, StringComparer.Ordinal)
                .Take(3).ToList();
            if (sigs.Count == 0) continue;
            outLines.Add(name.Substring(0, name.Length - 5) + "\t" + string.Join("\t", sigs));
        }
        File.WriteAllText(outPath, string.Join("\n", outLines) + "\n", Utf8);
        return outLines.Count;
    }

    static string Read(string path)
    {
        return File.ReadAllText(path, Utf8).TrimStart((char)0xFEFF).Replace("\r\n", "\n");
    }

    static string Rep(string s, string a, string b)
    {
        int i = s.IndexOf(a, StringComparison.Ordinal);
        if (i < 0) throw new Exception("MapChunkFS: game shader changed, anchor not found: " + a.Substring(0, Math.Min(70, a.Length)).Replace("\n", "\\n"));
        return s.Substring(0, i) + b + s.Substring(i + a.Length);
    }

    static string MaterialMips(string source)
    {
        source = Rep(source, "#version 410 core\n", "#version 410 core\nuniform float uHookTextureLodBias;\n");
        source = System.Text.RegularExpressions.Regex.Replace(source,
            @"texture\((uTexture[012]?),\s*(vec3\([^()]*\))\)", "texture($1, $2, uHookTextureLodBias)");
        return source.Replace("dFdx(fragTexCoords), dFdy(fragTexCoords)",
            "dFdx(fragTexCoords) * exp2(uHookTextureLodBias), dFdy(fragTexCoords) * exp2(uHookTextureLodBias)");
    }

    public static void MakeBlockyModelFS(string pack)
    {
        string source = Read(Path.Combine(pack, "original", "BlockyModelFS.glsl"));
        source = Rep(source, "#version 410 core\n", "#version 410 core\n#extension GL_ARB_shader_image_load_store : enable\n#include \"AU_Settings.glsl\"\n");
        source = Rep(source, "#include \"ModelVFX_inc.glsl\"\n", "#if AU_VOXEL_WORLD && !USE_DISTORTION_RT && !USE_SCENE_DATA_OVERRIDE && !FIRST_PERSON_VIEW\n"
            + "#define AU_VOX_WRITER_ONLY\n#include \"AU_Voxel.glsl\"\n#endif\n#include \"ModelVFX_inc.glsl\"\n");
        string gbuffer = "    writeToGBuffer(color.rgb, normalWS, defLight, staticLightColor.a, hasSSAO, hasBloom, false, outColor0, outColor1, outColor2);";
        source = Rep(source, gbuffer, "#if AU_VOXEL_WORLD && !USE_SCENE_DATA_OVERRIDE && !FIRST_PERSON_VIEW\n"
            + "    if (hasBloom && !hasHighlight) {\n"
            + "        vec3 auEmission = color.rgb * staticLightColor.rgb;\n"
            + "        float auPeak = max(auEmission.r, max(auEmission.g, auEmission.b));\n"
            + "        if (auPeak > 0.001) AU_RecordEmitterAt(fragPositionWS + CameraPosition - normalWS * 0.04, auEmission, min(auEmission.r, min(auEmission.g, auEmission.b)) < auPeak * 0.8);\n"
            + "    }\n#endif\n" + gbuffer);
        string forwardLight = "    color.rgb *= computeSimpleLightColor(normalWS, shadingMode);";
        source = Rep(source, forwardLight, "#if AU_VOXEL_WORLD && !USE_SCENE_DATA_OVERRIDE && !FIRST_PERSON_VIEW\n"
            + "    if (shadingMode == SHADING_FULLBRIGHT && !hasHighlight) {\n"
            + "        vec3 auEmission = color.rgb * staticLightColor.rgb;\n"
            + "        float auPeak = max(auEmission.r, max(auEmission.g, auEmission.b));\n"
            + "        if (auPeak > 0.001) AU_RecordEmitterAt(fragPositionWS + CameraPosition - normalWS * 0.04, auEmission, min(auEmission.r, min(auEmission.g, auEmission.b)) < auPeak * 0.8);\n"
            + "    }\n#endif\n" + forwardLight);
        File.WriteAllText(Path.Combine(pack, "programs", "BlockyModelFS.glsl"), MaterialMips(source), Utf8);
    }

    // The game's MapChunkFS with the pack's G-buffer normals, forward lighting, water and fog
    // spliced in.
    public static void MakeMapChunk(string pack, string snip)
    {
        string s = Read(Path.Combine(pack, "original", "MapChunkFS.glsl"));
        s = Rep(s, "#endif // !DEFERRED\n\n#if USE_OVERLAY",
                "#endif // !DEFERRED\n\n" + Read(Path.Combine(snip, "includes.glsl")) + "\n#if USE_OVERLAY");
        // Hytale sweeps a fake shine over REFLECTIVE blocks in near chunks only, boosting their
        // static light; the pack's lighting reads that as block light and the near chunks glow
        // in a square around the player. The pack has its own highlights.
        s = Rep(s, "    if (shadingMode == SHADING_REFLECTIVE)\n    {\n"
                 + "        vec4 shininess = computeFakeShininess(texColor.rgb, normalWS, CameraDirection.xyz);\n"
                 + "        light = max(light, vec3(shininess.a));\n        albedo.rgb += shininess.rgb;\n    }\n",
                "    // (Hytale fake shininess removed by Aurora Shaders)\n");
        s = Rep(s, "writeToGBuffer(albedo, normalWS, light, fragStaticLight.a, hasSSAO, hasBloom, useCleanShadowBackfaces, outColor0, outColor1, outColor2);\n",
                "writeToGBuffer(albedo, normalWS, light, fragStaticLight.a, hasSSAO, hasBloom, useCleanShadowBackfaces, outColor0, outColor1, outColor2);\n"
                + "    outColor0.a = (round(outColor0.a * 255.0) + 128.0 + 4.0 * (auMatClass > 0.0 ? auMatLevel : round(clamp(auOreGlow, 0.0, 1.0) * 7.0)) + 32.0 * auMatClass) / 255.0;   // Aurora: pure glow (128), ore glow / material level (bits 2-4), material class (bits 5-6)\n");
        s = Rep(s, "    bool useCleanShadowBackfaces = effectID > EFFECT_WIND;\n\n#if DEFERRED\n\n    writeToGBuffer(",
                "    bool useCleanShadowBackfaces = effectID > EFFECT_WIND;\n\n#if DEFERRED\n"
                + Read(Path.Combine(snip, "gennormals.glsl")) + "\n" + Read(Path.Combine(snip, "emitters.glsl")) + "\n    writeToGBuffer(");
        string lit = "    outColor0.rgb = albedo * light * shadow;\n    outColor0.a = texColor.a;\n";
        // Glass the pack composites itself (lighting.glsl) is written opaque into the OIT pass.
        s = Rep(s, "    color.a = isWater(effectID) ? 1.0 : texColor.a;\n",
                "#if AU_FORWARD\n    color.a = isWater(effectID) || auGlass ? 1.0 : texColor.a;\n#else\n"
                + "    color.a = isWater(effectID) ? 1.0 : texColor.a;\n#endif\n");
        s = Rep(s, lit, lit + "\n" + Read(Path.Combine(snip, "lighting.glsl")));

        int start = s.IndexOf("    if (isWater(effectID) && uWaterQuality >= 1)\n    {\n        vec2 screenUV", StringComparison.Ordinal);
        int end = s.IndexOf("    // Warning : because of precision issue \"with the UVs\",", StringComparison.Ordinal);
        if (start < 0 || end < start) throw new Exception("MapChunkFS: game shader changed, water block not found");
        string origWater = s.Substring(start, end - start);
        int bodyStart = origWater.IndexOf("{\n", StringComparison.Ordinal) + 2;
        string origBody = origWater.Substring(bodyStart, origWater.LastIndexOf('}') - bodyStart);
        s = s.Substring(0, start)
            + "    if (isWater(effectID) && uWaterQuality >= 1)\n    {\n#if AU_FORWARD && AU_WATER\n"
            + Read(Path.Combine(snip, "water.glsl")) + "#else\n" + origBody + "#endif\n    }\n\n"
            + s.Substring(end);

        s = Rep(s, "#if USE_FOG\n    // Apply fog\n    outColor0.rgb = mix(outColor0.rgb, fragFog.rgb, fragFog.w);\n"
                 + "    hasBloom = hasBloom && fragFog.w < 0.9;\n#endif // USE_FOG",
                "#if USE_FOG\n#if AU_FORWARD\n#if AU_BIOME_ATMOSPHERE\n    AU_ApplyBiomeFog(outColor0.rgb, fragFog);\n#else\n    DoAUFog(outColor0.rgb, fragPositionWS, auDither, fragStaticLight.a);\n#endif\n"
                + "    outColor0.rgb = AU_AddVL(outColor0.rgb, auForwardVL);\n#else\n"
                + "    // Apply fog\n    outColor0.rgb = mix(outColor0.rgb, fragFog.rgb, fragFog.w);\n#endif\n"
                + "    hasBloom = hasBloom && fragFog.w < 0.9;\n#endif // USE_FOG");
        s = Rep(s, "#version 410 core\n",
                "#version 410 core\n// Aurora Shaders for Hytale - terrain (G-buffer) and forward water / translucents.\n"
                + "// Generated by tools/prepare_shaders.ps1 from the game shader + tools/mapchunk/*.glsl.\n");
        File.WriteAllText(Path.Combine(pack, "programs", "MapChunkFS.glsl"), MaterialMips(s), Utf8);
    }

    // The game's MapChunkVS, recording every block it draws in the path tracer's voxel grid.
    public static void MakeMapChunkVS(string pack, string snip)
    {
        string s = Read(Path.Combine(pack, "original", "MapChunkVS.glsl"));
        s = Rep(s, "#version 410 core\n",
                "#version 410 core\n#extension GL_ARB_shader_image_load_store : enable\n"
                + "// Aurora Shaders for Hytale - terrain vertices + voxel grid.\n"
                + "// Generated by tools/prepare_shaders.ps1 from the game shader + tools/mapchunk/voxelize.glsl.\n");
        s = Rep(s, "#include \"Shading_inc.glsl\"\n",
                "#include \"Shading_inc.glsl\"\n#include \"AU_Settings.glsl\"\n"
                + "#if AU_VOXEL_WORLD && !ALPHA_BLEND && !USE_SCENE_DATA_OVERRIDE\n"
                + "uniform sampler2DArray uTexture;\nuniform sampler2DArray uHookMaterials;\nout vec3 auEmitterPositionWS;\n#include \"AU_Emission.glsl\"\n"
                + "#define AU_VOX_WRITER_ONLY\n#include \"AU_Voxel.glsl\"\n#endif\n");
        s = Rep(s, "    fragPackedData = packData(effectID, shadingMode);\n",
                Read(Path.Combine(snip, "voxelize.glsl")) + "\n    fragPackedData = packData(effectID, shadingMode);\n");
        // DLSS camera jitter (sub-pixel offset per frame, set by the hook; 0 without DLSS).
        s = Rep(s, "uniform mat4 uModelMatrix;\n", "uniform mat4 uModelMatrix;\nuniform vec2 uHookJitter;\n");
        s = Rep(s, "#endif // ALPHA_BLEND\n\n    float lightExposition;\n",
                "#endif // ALPHA_BLEND\n#if !USE_SCENE_DATA_OVERRIDE\n    gl_Position.xy += uHookJitter * gl_Position.w;\n#endif\n\n    float lightExposition;\n");
        // The G-buffer gets the pure block light (glow); DeferredFS adds the sun part from the
        // sky light itself. Hytale's max(sun, glow) here threw torch light away by day wherever
        // the sky reaches. Forward passes keep the game's combined light.
        string mx = "    fragStaticLight.rgb = max(SunLightColor.rgb * SunLightColor.a * staticLight.a, staticLight.rgb * StaticLightMultiplier);\n";
        s = Rep(s, mx, "#if DEFERRED && !USE_SCENE_DATA_OVERRIDE\n"
                + "    fragStaticLight.rgb = staticLight.rgb * StaticLightMultiplier;   // Aurora: pure glow (AU_GBUFFER_PURE_GLOW)\n"
                + "#else\n" + mx + "#endif\n");
        File.WriteAllText(Path.Combine(pack, "programs", "MapChunkVS.glsl"), s, Utf8);
    }

    // The game's other scene vertex shaders with the DLSS camera jitter: their main() is
    // renamed and called from a new main() that offsets gl_Position (early returns included).
    public static void MakeJitteredVS(string pack, string name)
    {
        string s = Read(Path.Combine(pack, "original", name + ".glsl"));
        var m = System.Text.RegularExpressions.Regex.Match(s, @"void\s+main\s*\(\s*(void)?\s*\)");
        if (!m.Success) throw new Exception(name + ": main() not found");
        s = s.Substring(0, m.Index) + "void auGameMain()" + s.Substring(m.Index + m.Length);
        string guardA = s.Contains("USE_SCENE_DATA_OVERRIDE") ? "#if !USE_SCENE_DATA_OVERRIDE\n" : "";
        string guardB = guardA.Length > 0 ? "#endif\n" : "";
        s = Rep(s, "#version 410 core\n", "#version 410 core\n// Aurora Shaders for Hytale - " + name
                + " with the DLSS camera jitter. Generated by tools/prepare_shaders.ps1 from the game shader.\n");
        s += "\n// DLSS camera jitter (sub-pixel offset per frame, set by the hook; 0 without DLSS).\n"
           + "uniform vec2 uHookJitter;\nvoid main()\n{\n    auGameMain();\n" + guardA
           + "    gl_Position.xy += uHookJitter * gl_Position.w;\n" + guardB + "}\n";
        File.WriteAllText(Path.Combine(pack, "programs", name + ".glsl"), s, Utf8);
    }

    // The game's fullscreen vertex shader, plus the sky's ambient light for the deferred lighting
    // (include/AU_SkyLight.glsl): worked out once per draw and handed over as flat varyings.
    public static void MakeScreenVS(string pack)
    {
        string s = Read(Path.Combine(pack, "original", "ScreenVS.glsl"));
        var m = System.Text.RegularExpressions.Regex.Match(s, @"void\s+main\s*\(\s*(void)?\s*\)");
        if (!m.Success || s.IndexOf("USE_FAR_CORNERS", StringComparison.Ordinal) < 0)
            throw new Exception("ScreenVS: game shader changed, main() or USE_FAR_CORNERS not found");
        s = s.Substring(0, m.Index) + "void auGameMain()" + s.Substring(m.Index + m.Length);
        s = Rep(s, "#version 410 core\n", "#version 410 core\n// Aurora Shaders for Hytale - ScreenVS with the sky light"
                + " for the deferred lighting. Generated by tools/prepare_shaders.ps1 from the game shader.\n");
        s += "\n// Aurora: the sky's ambient light per facing for the deferred lighting (include/AU_SkyLight.glsl).\n"
           + "#if USE_FAR_CORNERS\n#define AU_SKY_LIGHT_VERTEX 1\n#include \"SceneData_inc.glsl\"\n#include \"AU_SkyLight.glsl\"\n#endif\n"
           + "void main()\n{\n    auGameMain();\n#if USE_FAR_CORNERS\n    AU_SkyLightVertex();\n#endif\n}\n";
        File.WriteAllText(Path.Combine(pack, "programs", "ScreenVS.glsl"), s, Utf8);
    }

    // The game's ParticleFS with glowing particles (flames, sparks) mapped through the inverse of
    // the pack's tonemap, so they show Hytale's colour instead of a pale, darker one.
    public static void MakeParticleFS(string pack)
    {
        string s = Read(Path.Combine(pack, "original", "ParticleFS.glsl"));
        string call = "    processOIT(color, fragDepthVS, sceneLinearDepth, screenUV, blendMode, hasBloom, outColor0, outColor1);\n";
        if (s.IndexOf(call, StringComparison.Ordinal) < 0) throw new Exception("ParticleFS: game shader changed, processOIT call not found");
        s = s.Replace(call, "    if (hasBloom) color.rgb = AU_InverseTonemap(pow(clamp(color.rgb, 0.0, 0.88), vec3(2.2)));   // Aurora\n" + call);
        int nl = s.IndexOf('\n');
        s = s.Substring(0, nl + 1) + "#include \"AU_Tonemap.glsl\"\n" + s.Substring(nl + 1);
        File.WriteAllText(Path.Combine(pack, "programs", "ParticleFS.glsl"), s, Utf8);
    }

    // The game's SSAOFS without its taps where the pack's GTAO replaces them (DeferredFS): only
    // foliage and two-sided models, the surfaces without clean backfaces, still use this occlusion.
    public static void MakeSSAOFS(string pack)
    {
        string s = Read(Path.Combine(pack, "original", "SSAOFS.glsl"));
        s = Rep(s, "#include \"Noise_inc.glsl\"\n", "#include \"Noise_inc.glsl\"\n#include \"AU_Settings.glsl\"\n");
        s = Rep(s, "    if (ssaoDistanceScale < 1.0)\n", "#if AU_AO_METHOD == 1\n"
            + "    if (ssaoDistanceScale < 1.0 && texture(uGBufferTexture, fragTexCoords).a <= 0.5)   // Aurora\n"
            + "#else\n    if (ssaoDistanceScale < 1.0)\n#endif\n");
        File.WriteAllText(Path.Combine(pack, "programs", "SSAOFS.glsl"), s, Utf8);
    }

    public static void MakeShadowChunk(string pack, string snip)
    {
        string vertex = Read(Path.Combine(pack, "original", "ZOnlyChunkVS.glsl"));
        vertex = Rep(vertex, "flat out float fragAtlasPage;\n", "flat out float fragAtlasPage;\nflat out uint auSSSShadowSeed;\nflat out int auSSSShadowPass;\n");
        vertex = Rep(vertex, "void main()\n{\n", "void main()\n{\n#if ALPHA_TEST\n"
            + "    auSSSShadowSeed = uint(vertDoubleSidedAndBlockId & 32767) * 0x9e3779b9u ^ (vertNormalAndNodeId & 0xffffffu);\n"
            + "#if SHADOW_VERSION\n"
            + "    auSSSShadowPass = (vertTintColorAndShadingAndEffect & 31u) <= 15u && ((vertTintColorAndShadingAndEffect >> 6) & 3u) != 2u ? 1 : 0;\n"
            + "#else\n    auSSSShadowPass = 0;\n#endif\n#endif\n");
        string fragment = Read(Path.Combine(pack, "original", "ZOnlyChunkFS.glsl"));
        fragment = Rep(fragment, "#version 410 core\n", "#version 410 core\n#include \"AU_Settings.glsl\"\n"
            + "#if AU_SSS && AU_SSS_VOXEL == 2 && ALPHA_TEST\n"
            + "uniform sampler2DArray uHookMaterials;\nflat in uint auSSSShadowSeed;\nflat in int auSSSShadowPass;\n"
            + "#include \"AU_SSSMask.glsl\"\n#endif\n");
        string opacity = "    float opacity = texture(uTexture, vec3(fragTexCoords, fragAtlasPage), MIP_LOD_BIAS).a;\n";
        fragment = Rep(fragment, opacity, opacity + Read(Path.Combine(snip, "shadow-fragment.glsl")) + "\n");
        File.WriteAllText(Path.Combine(pack, "programs", "ZOnlyChunkVS.glsl"), vertex, Utf8);
        File.WriteAllText(Path.Combine(pack, "programs", "ZOnlyChunkFS.glsl"), fragment, Utf8);
    }

    public static void MakeBatcherFS(string pack)
    {
        string source = Read(Path.Combine(pack, "original", "Batcher2DFS.glsl"));
        string declaration = "layout(origin_upper_left) in vec4 gl_FragCoord;";
        int position = source.IndexOf(declaration, StringComparison.Ordinal);
        if (position < 0) throw new Exception("Batcher2DFS: fragment coordinate declaration not found");
        position += declaration.Length;
        source = source.Substring(0, position) + "\nuniform vec2 uHookUIFragmentScale;\n"
               + "#define auUIFragmentCoord vec4(gl_FragCoord.xy * uHookUIFragmentScale, gl_FragCoord.zw)\n"
               + source.Substring(position).Replace("gl_FragCoord", "auUIFragmentCoord");
        File.WriteAllText(Path.Combine(pack, "programs", "Batcher2DFS.glsl"), source, Utf8);
    }

    // ---- Block materials --------------------------------------------------------------------
    // shaderpack/materials.txt: one line per 32x32 block texture of the game - a fingerprint of
    // its pixels (FNV-1a over RGBA, top row first, transparent texels as 0) and the material its
    // name says it is. The hook fingerprints the tiles of Hytale's block atlas the same way and
    // builds the per-tile material map the terrain shader reads (hook.c, materials_build).
    //   class 0 default, 1 polished (gloss = level), 2 metal (level = polish), 3 porous (soaks
    //   up rain, darker when wet; level = how much); level 0-7.
    // Block materials by texture name: tools/material_rules.txt, read the same way by
    // prepare_shaders.py. Each rule: class, level, conditions (prefix/contains/exact, | for
    // alternatives) that must all hold; the first matching rule wins.
    class MaterialRule
    {
        public int Kind, Level;
        public List<KeyValuePair<string, string[]>> Conditions = new List<KeyValuePair<string, string[]>>();
    }

    static List<MaterialRule> LoadMaterialRules(string path)
    {
        var rules = new List<MaterialRule>();
        int number = 0;
        foreach (string raw in File.ReadAllLines(path, Utf8))
        {
            number++;
            string line = raw;
            int hash = line.IndexOf('#');
            if (hash >= 0) line = line.Substring(0, hash);
            string[] fields = line.Split(new[] { ' ', '	' }, StringSplitOptions.RemoveEmptyEntries);
            if (fields.Length == 0) continue;
            int kind, level;
            if (fields.Length < 3 || !int.TryParse(fields[0], out kind) || !int.TryParse(fields[1], out level)
                || kind < 0 || kind > 3 || level < 0 || level > 7)
                throw new Exception("material_rules.txt:" + number + ": expected <class 0-3> <level 0-7> <condition>...");
            var rule = new MaterialRule { Kind = kind, Level = level };
            for (int i = 2; i < fields.Length; i++)
            {
                int colon = fields[i].IndexOf(':');
                string test = colon > 0 ? fields[i].Substring(0, colon) : "";
                if ((test != "prefix" && test != "contains" && test != "exact") || colon == fields[i].Length - 1)
                    throw new Exception("material_rules.txt:" + number + ": bad condition " + fields[i]);
                rule.Conditions.Add(new KeyValuePair<string, string[]>(test, fields[i].Substring(colon + 1).Split('|')));
            }
            rules.Add(rule);
        }
        return rules;
    }

    static int[] Classify(string name, List<MaterialRule> rules)
    {
        string n = name.ToLowerInvariant();
        foreach (var rule in rules)
        {
            bool all = true;
            foreach (var condition in rule.Conditions)
            {
                bool any = false;
                foreach (string word in condition.Value)
                {
                    if (condition.Key == "prefix" ? n.StartsWith(word, StringComparison.Ordinal)
                        : condition.Key == "contains" ? n.Contains(word) : n == word) { any = true; break; }
                }
                if (!any) { all = false; break; }
            }
            if (all) return new[] { rule.Kind, rule.Level };
        }
        return new[] { 0, 0 };
    }

    public static int BuildMaterials(string assetsZip, string outPath, string rulesPath)
    {
        var lines = new List<string>();
        var rules = LoadMaterialRules(rulesPath);
        using (var zip = System.IO.Compression.ZipFile.OpenRead(assetsZip))
        {
            foreach (var e in zip.Entries)
            {
                if (!e.FullName.StartsWith("Common/BlockTextures/") || !e.FullName.EndsWith(".png")) continue;
                string name = Path.GetFileNameWithoutExtension(e.FullName);
                int[] cl = Classify(name, rules);
                if (cl[0] == 0) continue;
                byte[] png;
                using (var s = e.Open()) using (var ms = new MemoryStream()) { s.CopyTo(ms); png = ms.ToArray(); }
                using (var bmp = new System.Drawing.Bitmap(new MemoryStream(png)))
                {
                    if (bmp.Width != 32 || bmp.Height != 32) continue;
                    var data = bmp.LockBits(new System.Drawing.Rectangle(0, 0, 32, 32),
                        System.Drawing.Imaging.ImageLockMode.ReadOnly, System.Drawing.Imaging.PixelFormat.Format32bppArgb);
                    var bgra = new byte[32 * 32 * 4];
                    for (int y = 0; y < 32; y++)
                        System.Runtime.InteropServices.Marshal.Copy(data.Scan0 + y * data.Stride, bgra, y * 128, 128);
                    bmp.UnlockBits(data);
                    uint h = 2166136261u;
                    for (int i = 0; i < 1024; i++)
                    {
                        byte b = bgra[i * 4], g = bgra[i * 4 + 1], r = bgra[i * 4 + 2], a = bgra[i * 4 + 3];
                        if (a == 0) { r = g = b = 0; }
                        foreach (byte v in new[] { r, g, b, a }) { h ^= v; h *= 16777619u; }
                    }
                    lines.Add(string.Format("{0:x8} {1} {2} {3}", h, cl[0], cl[1], name));
                }
            }
        }
        lines.Sort(StringComparer.Ordinal);
        File.WriteAllLines(outPath, new[] { "# fingerprint class level texture  (tools/prepare_shaders.ps1 BuildMaterials)" }.Concat(lines), Utf8);
        return lines.Count;
    }
}
'@ -ReferencedAssemblies System.Drawing, System.IO.Compression, System.IO.Compression.FileSystem

if (-not $MapChunkOnly) {
    if (-not $Exe) { throw 'Pass -Exe "<...>\Client\HytaleClient.exe".' }
    $orig = Join-Path $pack 'original'
    $n = [AuroraPrep]::Extract($Exe, $orig)
    Write-Host "Extracted $n game shaders into shaderpack\original"
    $n = [AuroraPrep]::BuildIndex($orig, (Join-Path $pack 'index.txt'))
    Write-Host "Shader index: $n entries"
    # Client\HytaleClient.exe -> Assets.zip next to the Client folder.
    $assets = Join-Path (Split-Path (Split-Path $Exe -Parent) -Parent) 'Assets.zip'
    if (Test-Path $assets) {
        $n = [AuroraPrep]::BuildMaterials($assets, (Join-Path $pack 'materials.txt'), (Join-Path $PSScriptRoot 'material_rules.txt'))
        Write-Host "Block materials: $n textures"
        & (Join-Path $PSScriptRoot 'build_emitters.ps1') -Assets $assets -Output (Join-Path $pack 'emitters.txt')
        & (Join-Path $PSScriptRoot 'build_sss.ps1') -Assets $assets -Output (Join-Path $pack 'sss-masks.bin') -Overrides (Join-Path $pack 'sss')
    } else {
        Write-Host 'Assets.zip not found next to the game: no block materials'
    }
}
[AuroraPrep]::MakeMapChunk($pack, (Join-Path $PSScriptRoot 'mapchunk'))
Write-Host 'Generated shaderpack\programs\MapChunkFS.glsl'
[AuroraPrep]::MakeMapChunkVS($pack, (Join-Path $PSScriptRoot 'mapchunk'))
Write-Host 'Generated shaderpack\programs\MapChunkVS.glsl'
[AuroraPrep]::MakeParticleFS($pack)
[AuroraPrep]::MakeBlockyModelFS($pack)
Write-Host 'Generated shaderpack\programs\ParticleFS.glsl'
[AuroraPrep]::MakeBatcherFS($pack)
[AuroraPrep]::MakeShadowChunk($pack, (Join-Path $PSScriptRoot 'mapchunk'))
Write-Host 'Generated shaderpack\programs\Batcher2DFS.glsl'
foreach ($vs in 'BlockyModelVS', 'ParticleVS', 'SkyAndCloudsVS', 'BasicVS', 'BasicFogVS', 'BeamVS', 'TextVS') {
    [AuroraPrep]::MakeJitteredVS($pack, $vs)
}
Write-Host 'Generated the jittered scene vertex shaders'
[AuroraPrep]::MakeScreenVS($pack)
Write-Host 'Generated shaderpack\programs\ScreenVS.glsl'
[AuroraPrep]::MakeSSAOFS($pack)
Write-Host 'Generated shaderpack\programs\SSAOFS.glsl'
