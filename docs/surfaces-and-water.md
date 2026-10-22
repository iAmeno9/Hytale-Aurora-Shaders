# Surfaces, ambient occlusion, water and reflections

## Block materials

Blocks are recognised from the game's own textures at install and given a material: plain, polished, metal or porous, with a level within each. The rules are in `tools/material_rules.txt`, which both the Windows and the Linux installer read, so the two always agree. Re-run the installer after editing it; the game picks the new `materials.txt` up on the next shader reload.

- Dry wood, bricks, soil, gravel, plants and ordinary rough rock stay matte. Smooth clay, chalk and packed-soil bricks are matte despite their names, and marble cobble is rough stone.
- Polished stone is graded by how smooth the cut is, from sandstone and concrete slabs (a slight sheen) through cut stone and basalt to marble, glazed tiles and obsidian-like cooled magma. Metals: polished plates, plain metal, and dull goblin iron, rust and scrap. Ice and glass keep their own values.
- Smoother materials carry less of the generated texture relief, so polished stone, ice and metal plates reflect cleanly instead of breaking into grain.
- **Rain** is two things. A water film settles on top of surfaces, much less on walls, and little on what drinks it in. Soaking darkens what absorbs water: wood a little, soil, grass, moss, cloth and hay a lot, polished stone and metal not at all. Grass, soil and leaf-litter ground soak but never turn glossy. The film reflects off the flat block face rather than the texture relief, and it lingers while the ground is still wet after the rain.
- DLSS Ray Reconstruction's guide images use the same material function as the lighting, so RR denoises the surface that was actually lit, including wet ones.

Controls (Ores & materials): **Material gloss**, **Rain wetness** (the water film), **Rain soaking** (how much rain darkens absorbent blocks), **Smooth material relief** (how much polished stone, ice and metal give up the texel relief; zero bevels them like rough blocks); **Puddle strength** is under Water & glass.

## Ambient occlusion

**Lighting → Ambient occlusion method: Hytale SSAO / GTAO.** GTAO measures, per pixel, how much of the hemisphere above a surface is open, from the depth buffer. Corners, recesses, and objects resting on the ground are shaded by their real geometry. Bright materials lose less light to it, because light bounces between the occluding faces. Only indirect light is darkened (sky fill, torch light and the minimum cave light); the sun is left to the shadows. Foliage keeps Hytale's SSAO.

- **GTAO quality:** Low traces 2 directions × 4 steps per point, Medium 2 × 6, High 3 × 8.
- **GTAO radius:** how far around a surface occluders count, fading out smoothly toward the edge.
- **Ambient occlusion:** the existing strength slider, used by both methods.
- **Sky light from open directions:** with Sky-derived sky lighting, GTAO also finds the mean direction the sky is open from (the bent normal). Walls in recesses and under overhangs are then lit from the opening rather than from where they face. It takes no extra samples.

GTAO is traced at half resolution, one point per 2×2 pixels, in the same extra pass as the light shafts. Each pixel then blends the four nearest points, weighted by depth and normal. If the hook can't set up that pass, GTAO runs per pixel instead. The sampling pattern rotates per point and frame, and Aurora TAA or DLSS resolves it. At High on an M4 Pro at 4112x2516, tracing at half resolution took the frame from 46.7 to 39.6 ms. Per pixel at Medium, it had added about 0.3 ms to the lighting pass (4.42 → 4.74 ms) on the original test scene.

## Water colour

**Water & glass → Water colour model: Classic / Enhanced.** Enhanced absorbs light per colour along its path through the water: red first, then green. Hytale's water tint is the colour that survives longest, so a blue lake and a green swamp keep their own colours. Shallow edges stay clear and deep water takes the water's colour. The light reaching the bed travels its own path, longer under a low sun, so the bed of a deep pool is dim even where the water above it is thin to look through. Reflections keep their strength in shallow water, because it is the surface that reflects. **Water clarity** sets how far light travels before it takes the water's colour. Underwater views are unchanged.

## Finishing (Post-processing)

All three are off by default.
- **Highlight colour protection:** applies the tonemap curve to the brightest channel and keeps the others in proportion. Very bright coloured light (lava, coloured lanterns, a low sun) then holds its hue instead of draining to white. Only highlights are affected.
- **White balance (temperature, tint):** warmer or cooler, greener or more magenta, at unchanged brightness.
- **Adaptive exposure:** the eye adjusting to the dark. The image brightens where little sky is in view (caves, deep interiors), by up to **Adaptation strength**. It follows Hytale's own temporally smoothed eye brightness, so it eases in without flicker and needs no history buffer. Night outdoors stays dark.

Glowing blocks keep their exact displayed colour through white balance and adaptive exposure: the inverse-tonemap emission mapping undoes both. Highlight protection, by design, keeps them a little more saturated.

## Reflections

Screen-space reflections refine every hit by bisection, so reflections no longer step. A ray that runs into the back of a surface is rejected. Confidence fades for hits behind thick objects, toward the screen edge, near the end of the march, and on rays turning back toward the camera, and the reflection blends to the sky by that confidence. Rough reflections read a blurrier image the further away the reflected surface is, like a widening cone. **Screen-space GI → Refined reflections** switches this on (the default); off restores the previous reflections. **Material reflection steps** still sets the march length.

## Quality profiles

The built-in profiles (RTX and Non-RTX) now include the upgrades by measured cost. Ground mist depends on your world's altitude and the aurora is a matter of taste, so neither is switched on by a profile. Refined reflections are on everywhere.

| Tier | Adds |
|---|---|
| Medium and up | Sky-derived lighting, Enhanced water, Enhanced atmosphere |
| High | GTAO at Low quality |
| Highest | GTAO at Medium quality, plus Detailed cloud lighting |
| Ultra | GTAO at High quality, plus Detailed cloud lighting |

Profiles live in the hook DLL (`hook/profiles.h`), so they take effect after reinstalling.
