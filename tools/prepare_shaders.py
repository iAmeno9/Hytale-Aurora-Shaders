#!/usr/bin/env python3
"""Prepare Aurora from the player's NativeAOT client (ELF on Linux, PE on Windows).

No game sources are bundled. Keep the shader edits in sync with prepare_shaders.ps1.
"""
import argparse
from collections import Counter
from io import BytesIO
from pathlib import Path
import re
import struct
import tempfile
import zipfile

ROOT = Path(__file__).resolve().parent.parent


def native_uint(data, pos):
    """Read a NativeFormat unsigned integer, rejecting truncated resource records."""
    first = data[pos]
    for size in range(1, 5):
        if not first & (1 << (size - 1)):
            end = pos + size
            if end > len(data):
                raise ValueError("Truncated NativeFormat integer")
            value = first >> size
            for i in range(1, size):
                value |= data[pos + i] << (8 * i - size)
            return value, end
    return struct.unpack_from("<I", data, pos + 1)[0], pos + 5


def occurrences(data, pattern):
    pos = data.find(pattern)
    while pos >= 0:
        yield pos
        pos = data.find(pattern, pos + 1)


def extract(executable):
    data = executable.read_bytes()
    assembly = b"HytaleClient, Version=1.0.0.0, Culture=neutral, PublicKeyToken=null"
    prefix = "HytaleClient.Graphics.Shaders."
    resources = {}
    for match in occurrences(data, assembly):
        try:
            length, pos = native_uint(data, match + len(assembly))
            if not 0 < length <= 512 or pos + length > len(data):
                continue
            name = data[pos:pos + length].decode("ascii")
            if not name.startswith(prefix):
                continue
            name = name[len(prefix):]
            if not re.fullmatch(r"[A-Za-z0-9_]+\.glsl", name):
                raise ValueError(f"Unsafe shader resource name: {name!r}")
            offset, pos = native_uint(data, pos + length)
            size, pos = native_uint(data, pos)
            resources[name] = (offset, size)
        except (IndexError, struct.error, UnicodeDecodeError):
            continue
    mains = [r for n, r in resources.items() if n.endswith(("FS.glsl", "VS.glsl"))]
    if not mains:
        raise ValueError(f"No shader resources found in {executable}")
    version = b"#version 410 core"
    first = min(offset for offset, _ in mains)
    bases = (p - first for p in occurrences(data, version) if p >= first)
    base = max(bases, key=lambda b: sum(data.startswith(version, b + o) for o, _ in mains), default=-1)
    if base < 0 or sum(data.startswith(version, base + o) for o, _ in mains) < (len(mains) + 1) // 2:
        raise ValueError(f"Could not locate the shader data in {executable}")
    result = {}
    for name, (offset, size) in resources.items():
        if size <= 0 or base + offset + size > len(data):
            raise ValueError(f"Truncated shader resource: {name}")
        result[name] = data[base + offset:base + offset + size].decode("utf-8-sig").replace("\r\n", "\n")
    return result


def build_index(sources):
    included = {name for text in sources.values() for name in re.findall(r'#include\s*"([^"]+)"', text)}
    lines = {name: {line.strip() for line in text.splitlines() if line.strip()} for name, text in sources.items()}
    counts = Counter(line for group in lines.values() for line in group)
    output = []
    for name in sorted(sources):
        if name in included:
            continue
        signatures = [line for line in lines[name] if counts[line] == 1 and len(line) >= 20
                      and "\t" not in line and not line.startswith(("#include", "#version"))]
        signatures.sort(key=lambda line: (line.startswith("//"), -len(line), line))
        if signatures:
            output.append("\t".join([name[:-5]] + signatures[:3]))
    return "\n".join(output) + "\n"


def replace(source, anchor, replacement):
    if anchor not in source:
        raise ValueError(f"Game shader changed; anchor not found: {anchor[:100]!r}")
    return source.replace(anchor, replacement, 1)


def snippet(name):
    return (ROOT / "tools" / "mapchunk" / name).read_text(encoding="utf-8-sig")


def material_mips(source):
    source = replace(source, "#version 410 core\n", "#version 410 core\nuniform float uHookTextureLodBias;\n")
    source = re.sub(r"texture\((uTexture[012]?),\s*(vec3\([^()]*\))\)", r"texture(\1, \2, uHookTextureLodBias)", source)
    return source.replace("dFdx(fragTexCoords), dFdy(fragTexCoords)",
                          "dFdx(fragTexCoords) * exp2(uHookTextureLodBias), dFdy(fragTexCoords) * exp2(uHookTextureLodBias)")


def make_blocky_model_fs(source):
    source = replace(source, "#version 410 core\n", "#version 410 core\n#extension GL_ARB_shader_image_load_store : enable\n#include \"AU_Settings.glsl\"\n")
    source = replace(source, '#include "ModelVFX_inc.glsl"\n',
                     '#if AU_VOXEL_WORLD && !USE_DISTORTION_RT && !USE_SCENE_DATA_OVERRIDE && !FIRST_PERSON_VIEW\n'
                     '#define AU_VOX_WRITER_ONLY\n#include "AU_Voxel.glsl"\n#endif\n#include "ModelVFX_inc.glsl"\n')
    capture = ('#if AU_VOXEL_WORLD && !USE_SCENE_DATA_OVERRIDE && !FIRST_PERSON_VIEW\n'
               '    if (CONDITION && !hasHighlight) {\n'
               '        vec3 auEmission = color.rgb * staticLightColor.rgb;\n'
               '        float auPeak = max(auEmission.r, max(auEmission.g, auEmission.b));\n'
               '        if (auPeak > 0.001) AU_RecordEmitterAt(fragPositionWS + CameraPosition - normalWS * 0.04, auEmission, min(auEmission.r, min(auEmission.g, auEmission.b)) < auPeak * 0.8);\n'
               '    }\n#endif\n')
    gbuffer = '    writeToGBuffer(color.rgb, normalWS, defLight, staticLightColor.a, hasSSAO, hasBloom, false, outColor0, outColor1, outColor2);'
    source = replace(source, gbuffer, capture.replace('CONDITION', 'hasBloom') + gbuffer)
    forward = '    color.rgb *= computeSimpleLightColor(normalWS, shadingMode);'
    source = replace(source, forward, capture.replace('CONDITION', 'shadingMode == SHADING_FULLBRIGHT') + forward)
    return material_mips(source)


def make_batcher_fs(source):
    anchor = 'layout(origin_upper_left) in vec4 gl_FragCoord;'
    if anchor not in source:
        raise ValueError('Batcher2DFS: fragment coordinate declaration not found')
    position = source.index(anchor) + len(anchor)
    return (source[:position] + '\nuniform vec2 uHookUIFragmentScale;\n'
            '#define auUIFragmentCoord vec4(gl_FragCoord.xy * uHookUIFragmentScale, gl_FragCoord.zw)\n'
            + source[position:].replace('gl_FragCoord', 'auUIFragmentCoord'))


def make_shadow_chunk_vs(source):
    declaration = "flat out float fragAtlasPage;\n"
    source = replace(source, declaration, declaration + "flat out uint auSSSShadowSeed;\nflat out int auSSSShadowPass;\n")
    return replace(source, "void main()\n{\n", "void main()\n{\n#if ALPHA_TEST\n"
                   "    auSSSShadowSeed = uint(vertDoubleSidedAndBlockId & 32767) * 0x9e3779b9u ^ (vertNormalAndNodeId & 0xffffffu);\n"
                   "#if SHADOW_VERSION\n"
                   "    auSSSShadowPass = (vertTintColorAndShadingAndEffect & 31u) <= 15u && ((vertTintColorAndShadingAndEffect >> 6) & 3u) != 2u ? 1 : 0;\n"
                   "#else\n    auSSSShadowPass = 0;\n#endif\n#endif\n")


def make_shadow_chunk_fs(source):
    source = replace(source, "#version 410 core\n", '#version 410 core\n#include "AU_Settings.glsl"\n'
                     '#if AU_SSS && AU_SSS_VOXEL == 2 && ALPHA_TEST\n'
                     'uniform sampler2DArray uHookMaterials;\nflat in uint auSSSShadowSeed;\nflat in int auSSSShadowPass;\n'
                     '#include "AU_SSSMask.glsl"\n#endif\n')
    return replace(source, "    float opacity = texture(uTexture, vec3(fragTexCoords, fragAtlasPage), MIP_LOD_BIAS).a;\n",
                   "    float opacity = texture(uTexture, vec3(fragTexCoords, fragAtlasPage), MIP_LOD_BIAS).a;\n" + snippet("shadow-fragment.glsl"))


def make_map_chunk(source):
    s = replace(source, "#endif // !DEFERRED\n\n#if USE_OVERLAY",
                "#endif // !DEFERRED\n\n" + snippet("includes.glsl") + "\n#if USE_OVERLAY")
    s = replace(s, "    if (shadingMode == SHADING_REFLECTIVE)\n    {\n"
                "        vec4 shininess = computeFakeShininess(texColor.rgb, normalWS, CameraDirection.xyz);\n"
                "        light = max(light, vec3(shininess.a));\n        albedo.rgb += shininess.rgb;\n    }\n",
                "    // (Hytale fake shininess removed by Aurora Shaders)\n")
    anchor = "writeToGBuffer(albedo, normalWS, light, fragStaticLight.a, hasSSAO, hasBloom, useCleanShadowBackfaces, outColor0, outColor1, outColor2);\n"
    s = replace(s, anchor, anchor + "    outColor0.a = (round(outColor0.a * 255.0) + 128.0 + 4.0 * (auMatClass > 0.0 ? auMatLevel : round(clamp(auOreGlow, 0.0, 1.0) * 7.0)) + 32.0 * auMatClass) / 255.0;   // Aurora: pure glow (128), ore glow / material level (bits 2-4), material class (bits 5-6)\n")
    s = replace(s, "    bool useCleanShadowBackfaces = effectID > EFFECT_WIND;\n\n#if DEFERRED\n\n    writeToGBuffer(",
                "    bool useCleanShadowBackfaces = effectID > EFFECT_WIND;\n\n#if DEFERRED\n" + snippet("gennormals.glsl") + "\n" + snippet("emitters.glsl") + "\n    writeToGBuffer(")
    s = replace(s, "    color.a = isWater(effectID) ? 1.0 : texColor.a;\n",
                "#if AU_FORWARD\n    color.a = isWater(effectID) || auGlass ? 1.0 : texColor.a;\n#else\n"
                "    color.a = isWater(effectID) ? 1.0 : texColor.a;\n#endif\n")
    lit = "    outColor0.rgb = albedo * light * shadow;\n    outColor0.a = texColor.a;\n"
    s = replace(s, lit, lit + "\n" + snippet("lighting.glsl"))
    start = s.find("    if (isWater(effectID) && uWaterQuality >= 1)\n    {\n        vec2 screenUV")
    end = s.find('    // Warning : because of precision issue "with the UVs",')
    if start < 0 or end < start:
        raise ValueError("MapChunkFS: game shader changed, water block not found")
    water = s[start:end]
    body = water[water.index("{\n") + 2:water.rindex("}")]
    s = s[:start] + "    if (isWater(effectID) && uWaterQuality >= 1)\n    {\n#if AU_FORWARD && AU_WATER\n" + snippet("water.glsl") + "#else\n" + body + "#endif\n    }\n\n" + s[end:]
    s = replace(s, "#if USE_FOG\n    // Apply fog\n    outColor0.rgb = mix(outColor0.rgb, fragFog.rgb, fragFog.w);\n"
                "    hasBloom = hasBloom && fragFog.w < 0.9;\n#endif // USE_FOG",
                "#if USE_FOG\n#if AU_FORWARD\n#if AU_BIOME_ATMOSPHERE\n    AU_ApplyBiomeFog(outColor0.rgb, fragFog);\n#else\n    DoAUFog(outColor0.rgb, fragPositionWS, auDither, fragStaticLight.a);\n#endif\n"
                "    outColor0.rgb = AU_AddVL(outColor0.rgb, auForwardVL);\n#else\n"
                "    // Apply fog\n    outColor0.rgb = mix(outColor0.rgb, fragFog.rgb, fragFog.w);\n#endif\n"
                "    hasBloom = hasBloom && fragFog.w < 0.9;\n#endif // USE_FOG")
    s = replace(s, "#version 410 core\n", "#version 410 core\n#extension GL_ARB_shader_image_load_store : enable\n")
    return material_mips(s)


def make_map_chunk_vs(s):
    s = replace(s, "#version 410 core\n", "#version 410 core\n#extension GL_ARB_shader_image_load_store : enable\n"
                "// Aurora terrain vertices and voxel grid; generated by tools/prepare_shaders.py.\n")
    s = replace(s, '#include "Shading_inc.glsl"\n', '#include "Shading_inc.glsl"\n#include "AU_Settings.glsl"\n'
                '#if AU_VOXEL_WORLD && !ALPHA_BLEND && !USE_SCENE_DATA_OVERRIDE\n'
                'uniform sampler2DArray uTexture;\nuniform sampler2DArray uHookMaterials;\nout vec3 auEmitterPositionWS;\n#include "AU_Emission.glsl"\n'
                '#define AU_VOX_WRITER_ONLY\n#include "AU_Voxel.glsl"\n#endif\n')
    s = replace(s, "    fragPackedData = packData(effectID, shadingMode);\n", snippet("voxelize.glsl") + "\n    fragPackedData = packData(effectID, shadingMode);\n")
    s = replace(s, "uniform mat4 uModelMatrix;\n", "uniform mat4 uModelMatrix;\nuniform vec2 uHookJitter;\n")
    s = replace(s, "#endif // ALPHA_BLEND\n\n    float lightExposition;\n", "#endif // ALPHA_BLEND\n#if !USE_SCENE_DATA_OVERRIDE\n"
                "    gl_Position.xy += uHookJitter * gl_Position.w;\n#endif\n\n    float lightExposition;\n")
    mx = "    fragStaticLight.rgb = max(SunLightColor.rgb * SunLightColor.a * staticLight.a, staticLight.rgb * StaticLightMultiplier);\n"
    return replace(s, mx, "#if DEFERRED && !USE_SCENE_DATA_OVERRIDE\n"
                   "    fragStaticLight.rgb = staticLight.rgb * StaticLightMultiplier;   // Aurora: pure glow (AU_GBUFFER_PURE_GLOW)\n"
                   "#else\n" + mx + "#endif\n")


def make_particle_fs(s):
    call = "    processOIT(color, fragDepthVS, sceneLinearDepth, screenUV, blendMode, hasBloom, outColor0, outColor1);\n"
    if call not in s:
        raise ValueError("ParticleFS: game shader changed, processOIT call not found")
    s = s.replace(call, "    if (hasBloom) color.rgb = AU_InverseTonemap(pow(clamp(color.rgb, 0.0, 0.88), vec3(2.2)));   // Aurora\n" + call)
    nl = s.index("\n") + 1
    return s[:nl] + '#include "AU_Tonemap.glsl"\n' + s[nl:]


def make_ssao_fs(s):
    # The game's SSAOFS without its taps where the pack's GTAO replaces them (DeferredFS): only
    # foliage and two-sided models, the surfaces without clean backfaces, still use this occlusion.
    # The shadow mask this pass also filters is untouched.
    s = replace(s, '#include "Noise_inc.glsl"\n', '#include "Noise_inc.glsl"\n#include "AU_Settings.glsl"\n')
    return replace(s, "    if (ssaoDistanceScale < 1.0)\n",
                   "#if AU_AO_METHOD == 1\n"
                   "    if (ssaoDistanceScale < 1.0 && texture(uGBufferTexture, fragTexCoords).a <= 0.5)   // Aurora\n"
                   "#else\n"
                   "    if (ssaoDistanceScale < 1.0)\n"
                   "#endif\n")


def make_jittered_vs(s):
    s, count = re.subn(r"void\s+main\s*\(\s*(?:void)?\s*\)", "void auGameMain()", s, count=1)
    if not count:
        raise ValueError("Vertex shader: main() not found")
    guard = "USE_SCENE_DATA_OVERRIDE" in s
    return s + "\n// Aurora camera jitter (zero without DLSS).\nuniform vec2 uHookJitter;\nvoid main()\n{\n    auGameMain();\n" + ("#if !USE_SCENE_DATA_OVERRIDE\n" if guard else "") + "    gl_Position.xy += uHookJitter * gl_Position.w;\n" + ("#endif\n" if guard else "") + "}\n"


def make_screen_vs(s):
    s, count = re.subn(r"void\s+main\s*\(\s*(?:void)?\s*\)", "void auGameMain()", s, count=1)
    if not count or "USE_FAR_CORNERS" not in s:
        raise ValueError("ScreenVS: game shader changed, main() or USE_FAR_CORNERS not found")
    return s + ("\n// Aurora: the sky's ambient light per facing for the deferred lighting (include/AU_SkyLight.glsl).\n"
                "#if USE_FAR_CORNERS\n#define AU_SKY_LIGHT_VERTEX 1\n#include \"SceneData_inc.glsl\"\n#include \"AU_SkyLight.glsl\"\n#endif\n"
                "void main()\n{\n    auGameMain();\n#if USE_FAR_CORNERS\n    AU_SkyLightVertex();\n#endif\n}\n")


MATERIAL_RULES = Path(__file__).with_name("material_rules.txt")


def load_material_rules(path=MATERIAL_RULES):
    rules = []
    for number, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        fields = line.split("#", 1)[0].split()
        if not fields:
            continue
        conditions = []
        for condition in fields[2:]:
            kind, _, words = condition.partition(":")
            if kind not in ("prefix", "contains", "exact") or not words:
                raise ValueError(f"{path.name}:{number}: bad condition {condition!r}")
            conditions.append((kind, tuple(words.split("|"))))
        if len(fields) < 3 or not (0 <= int(fields[0]) <= 3 and 0 <= int(fields[1]) <= 7):
            raise ValueError(f"{path.name}:{number}: expected <class 0-3> <level 0-7> <condition>...")
        rules.append((int(fields[0]), int(fields[1]), conditions))
    return rules


def classify(name, rules=None):
    n = name.lower()
    tests = {"prefix": lambda words: n.startswith(words), "contains": lambda words: any(w in n for w in words),
             "exact": lambda words: n in words}
    for kind, level, conditions in rules if rules is not None else load_material_rules():
        if all(tests[test](words) for test, words in conditions):
            return kind, level
    return 0, 0


def build_materials(assets):
    from PIL import Image
    lines = []
    rules = load_material_rules()
    with zipfile.ZipFile(assets) as archive:
        for entry in archive.infolist():
            if not entry.filename.startswith("Common/BlockTextures/") or not entry.filename.endswith(".png"):
                continue
            name = Path(entry.filename).stem
            kind, level = classify(name, rules)
            if kind == 0:
                continue
            with Image.open(BytesIO(archive.read(entry))) as image:
                if image.size != (32, 32):
                    continue
                fingerprint = 2166136261
                for rgba in image.convert("RGBA").getdata():
                    for value in rgba if rgba[3] else (0, 0, 0, 0):
                        fingerprint = ((fingerprint ^ value) * 16777619) & 0xffffffff
                lines.append(f"{fingerprint:08x} {kind} {level} {name}")
    return "# fingerprint class level texture (tools/prepare_shaders.py)\n" + "\n".join(sorted(lines)) + "\n"


def prepare(executable, pack, assets=None):
    sources = extract(executable)
    generated = {
        "MapChunkFS.glsl": make_map_chunk(sources["MapChunkFS.glsl"]),
        "MapChunkVS.glsl": make_map_chunk_vs(sources["MapChunkVS.glsl"]),
        "ParticleFS.glsl": make_particle_fs(sources["ParticleFS.glsl"]),
        "BlockyModelFS.glsl": make_blocky_model_fs(sources["BlockyModelFS.glsl"]),
        "Batcher2DFS.glsl": make_batcher_fs(sources["Batcher2DFS.glsl"]),
        "ZOnlyChunkVS.glsl": make_shadow_chunk_vs(sources["ZOnlyChunkVS.glsl"]),
        "ZOnlyChunkFS.glsl": make_shadow_chunk_fs(sources["ZOnlyChunkFS.glsl"]),
        "SSAOFS.glsl": make_ssao_fs(sources["SSAOFS.glsl"]),
    }
    for name in ("BlockyModelVS", "ParticleVS", "SkyAndCloudsVS", "BasicVS", "BasicFogVS", "BeamVS", "TextVS"):
        generated[name + ".glsl"] = make_jittered_vs(sources[name + ".glsl"])
    generated["ScreenVS.glsl"] = make_screen_vs(sources["ScreenVS.glsl"])
    index = build_index(sources)
    assets = assets or executable.parent.parent / "Assets.zip"
    materials = build_materials(assets) if assets.is_file() else "# Assets.zip unavailable; no block materials\n"
    # Validate all anchors before replacing any working files.
    outputs = {"index.txt": index, "materials.txt": materials}
    if assets.is_file():
        from build_emitters import build_emitters
        import json
        records, report = build_emitters(assets)
        outputs["emitters.txt"] = "\n".join(sorted(records)) + "\n"
        outputs["emitters.json"] = json.dumps(report, indent=2) + "\n"
        from build_sss import build_masks
        outputs["sss-masks.bin"] = build_masks(assets, pack / "sss")
    else:
        outputs["emitters.txt"] = ""
        outputs["emitters.json"] = "[]\n"
        outputs["sss-masks.bin"] = b"AUSSS001" + struct.pack("<I", 0)
    outputs.update(("original/" + name, value) for name, value in sources.items())
    outputs.update(("programs/" + name, value) for name, value in generated.items())
    for name, value in outputs.items():
        dest = pack / name
        dest.parent.mkdir(parents=True, exist_ok=True)
        options = {"mode": "wb"} if isinstance(value, bytes) else {"mode": "w", "encoding": "utf-8"}
        with tempfile.NamedTemporaryFile(dir=dest.parent, delete=False, **options) as temp:
            temp.write(value)
        Path(temp.name).replace(dest)
    print(f"Prepared {len(sources)} original shaders, {len(generated)} overrides and {len(index.splitlines())} index entries in {pack}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--exe", type=Path, required=True, help="Installed HytaleClient binary")
    parser.add_argument("--pack", type=Path, default=ROOT / "shaderpack")
    parser.add_argument("--assets", type=Path, help="Assets.zip (default: next to Client)")
    args = parser.parse_args()
    try:
        prepare(args.exe.resolve(), args.pack.resolve(), args.assets)
    except (OSError, ValueError, KeyError, ImportError, zipfile.BadZipFile) as error:
        parser.exit(1, f"Shader preparation failed: {error}\n")


if __name__ == "__main__":
    main()
