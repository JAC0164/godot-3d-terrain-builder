"""Low-poly detail props for the Lowpoly Terrain Editor (Godot addon).

Run inside Blender: paste it in the Scripting tab (or send it through the
Blender MCP) followed by

    build_all()                       # (re)models every prop in "LTE_Props"
    export_glb(r"<somewhere>/lte_props.glb")

then, outside Blender:

    python tools/blender/glb_to_gdscript.py <somewhere>/lte_props.glb addons/lowpoly_terrain_editor/mesh/detail_mesh_data.gd

Conventions (same as the addon's DetailMeshes):
- 1 Blender unit = 1 terrain cell. Props are about 1 unit tall (the layer Scale
  is then their height in cells); grass tufts and stones are at real size.
- Origin at the base, the object slightly sunk (z = -0.05).
- Blender is Z-up: the export converts to Godot Y-up (x, z, -y), so the skull's
  muzzle, along Godot +Z, points to Blender -Y.
- One material per colour: the export writes a palette and one palette index per
  triangle. Faces with the "thin" attribute (blades, leaves) are exported to be
  drawn from both sides with an upward normal.
- Every prop is rebuilt from code with fixed seeds: tweak the numbers here and
  run build_all() again rather than editing the meshes by hand.
"""

import math
import random

import bmesh
import bpy
from mathutils import Matrix, Vector, noise

COLLECTION = "LTE_Props"
SPACING = 2.2

# Godot-side colours (linear-ish, same values as the addon used before).
BARK = (0.43, 0.33, 0.25)
BAOBAB_BARK = (0.62, 0.52, 0.45)
LEAVES = (0.42, 0.49, 0.22)
DRY_LEAVES = (0.55, 0.52, 0.29)
BONE = (0.92, 0.89, 0.8)
HORN = (0.5, 0.45, 0.38)
DEAD_WOOD = (0.6, 0.56, 0.5)


def _mix(a, b, t):
    return tuple(a[i] + (b[i] - a[i]) * t for i in range(3))


def _scale(c, f):
    return tuple(min(c[i] * f, 1.0) for i in range(3))


def _collection():
    coll = bpy.data.collections.get(COLLECTION)
    if coll is None:
        coll = bpy.data.collections.new(COLLECTION)
        bpy.context.scene.collection.children.link(coll)
    return coll


# Prop state: a dict (the Blender MCP safe mode forbids class definitions).

def new_prop(key, seed=1):
    pr = {}
    pr['key'] = key
    pr['bm'] = bmesh.new()
    pr['col_layer'] = pr['bm'].faces.layers.int.new("pal")
    pr['thin_layer'] = pr['bm'].faces.layers.int.new("thin")
    pr['palette'] = []
    pr['rng'] = random.Random(seed)
    pr['seed'] = seed
    pr['ao'] = (0.7, 0.6)  # darkest factor at z=0, height where it fades out
    pr['jitter'] = 0.05
    return pr

# -- colours ----------------------------------------------------------------
def col(pr, rgb, thin=False):
    key = (tuple(round(v, 3) for v in rgb), bool(thin))
    if key not in pr['palette']:
        pr['palette'].append(key)
    return pr['palette'].index(key)

# -- raw faces --------------------------------------------------------------
def vert(pr, pos):
    return pr['bm'].verts.new(Vector(pos))

def face(pr, verts, rgb, thin=False):
    """verts: BMVerts in counter-clockwise order seen from outside."""
    try:
        f = pr['bm'].faces.new(verts)
    except ValueError:
        return None
    f[pr['col_layer']] = col(pr, rgb, thin)
    f[pr['thin_layer']] = 1 if thin else 0
    return f

def tri(pr, a, b, c, rgb, thin=False):
    return face(pr, [vert(pr, a), vert(pr, b), vert(pr, c)], rgb, thin)

# -- primitives -------------------------------------------------------------
def tube(pr, points, radii, sides, colors, cap=True, jitter=0.0, flat_first=True,
         twist=0.0, tip=0.4):
    """Faceted tube along a polyline. colors: one rgb per segment (or one)."""
    pts = [Vector(p) for p in points]
    if not isinstance(colors, list):
        colors = [colors] * (len(pts) - 1)
    rings = []
    u_prev = None
    for i, p in enumerate(pts):
        if i == 0:
            d = (pts[1] - pts[0]).normalized()
        elif i == len(pts) - 1:
            d = (pts[i] - pts[i - 1]).normalized()
        else:
            d = ((pts[i] - pts[i - 1]).normalized() + (pts[i + 1] - pts[i]).normalized()).normalized()
        if i == 0 and flat_first and abs(d.z) > 0.6:
            u, v = Vector((1, 0, 0)), Vector((0, 1, 0))
            ring_d = Vector((0, 0, 1))
        else:
            if u_prev is None:
                ref = Vector((0, 0, 1)) if abs(d.z) < 0.9 else Vector((1, 0, 0))
                u = ref.cross(d).normalized()
            else:
                u = (u_prev - d * u_prev.dot(d)).normalized()
            v = d.cross(u).normalized()
            ring_d = d
        u_prev = u
        ring = []
        for k in range(sides):
            a = math.tau * k / sides + twist * i
            r = radii[i]
            if jitter > 0.0:
                q = p + (u * math.cos(a) + v * math.sin(a)) * 3.0
                r *= 1.0 + jitter * noise.noise(q * 2.3 + Vector((pr['seed'] % 7, 0, 0)))
            ring.append(vert(pr, p + (u * math.cos(a) + v * math.sin(a)) * r))
        rings.append((ring, ring_d))
    for i in range(len(rings) - 1):
        r0, r1 = rings[i][0], rings[i + 1][0]
        for k in range(sides):
            j = (k + 1) % sides
            face(pr, [r0[k], r0[j], r1[j], r1[k]], colors[i])
    if cap:
        last, d = rings[-1]
        end = pts[-1] + d * radii[-1] * tip
        c = vert(pr, end)
        for k in range(sides):
            face(pr, [last[k], last[(k + 1) % sides], c], colors[-1])
    return rings

def blob(pr, center, radii, rgb, seed=0, rough=0.18, under=None, subdiv=1, flat_bottom=None):
    """Faceted lumpy ellipsoid (icosphere subdiv 1 = 20 triangles)."""
    tmp = bmesh.new()
    bmesh.ops.create_icosphere(tmp, subdivisions=subdiv, radius=1.0)
    rng = random.Random(seed)
    offsets = {}
    for v in tmp.verts:
        k = (round(v.co.x, 3), round(v.co.y, 3), round(v.co.z, 3))
        offsets[k] = 1.0 + rough * (rng.random() * 2.0 - 1.0)
    c = Vector(center)
    mapping = {}
    for v in tmp.verts:
        k = (round(v.co.x, 3), round(v.co.y, 3), round(v.co.z, 3))
        p = Vector((v.co.x * radii[0], v.co.y * radii[1], v.co.z * radii[2])) * offsets[k] + c
        if flat_bottom is not None:
            p.z = max(p.z, flat_bottom)
        mapping[v] = vert(pr, p)
    for f in tmp.faces:
        col = rgb
        if under is not None and f.normal.z < -0.35:
            col = under
        face(pr, [mapping[v] for v in f.verts], col)
    tmp.free()

def pad(pr, center, rx, ry, top, bottom, sides, rgb_top, rgb_side, rgb_bottom, seed=0, droop=0.03, rot=0.0):
    """Flat canopy plate: domed faceted top, thin rim, flat underside."""
    rng = random.Random(seed)
    c = Vector(center)
    upper, lower = [], []
    for k in range(sides):
        a = math.tau * k / sides + rot + rng.uniform(-0.18, 0.18)
        r = 1.0 + rng.uniform(-0.16, 0.12)
        x, y = math.cos(a) * rx * r, math.sin(a) * ry * r
        z = -droop * rng.uniform(0.5, 1.3)
        upper.append(vert(pr, c + Vector((x, y, z))))
        lower.append(vert(pr, c + Vector((x * 0.86, y * 0.86, z - bottom * 0.7))))
    t = vert(pr, c + Vector((rng.uniform(-0.04, 0.04), rng.uniform(-0.04, 0.04), top)))
    b = vert(pr, c + Vector((0, 0, -bottom)))
    for k in range(sides):
        j = (k + 1) % sides
        face(pr, [upper[k], upper[j], t], rgb_top)
        face(pr, [lower[k], upper[k], upper[j], lower[j]][::-1], rgb_side)
        face(pr, [lower[j], lower[k], b], rgb_bottom)

def blade(pr, root, direction, height, width, lean, bend, rgb, segments=2):
    """Grass blade: thin strip that bends outward, `segments` quads + tip
    (segments=0: one triangle, what the dense grass layers use)."""
    d = Vector((direction[0], direction[1], 0)).normalized()
    side = Vector((-d.y, d.x, 0))
    base = Vector(root)
    pts = []
    for s in range(segments + 1):
        f = s / (segments + 1)
        off = d * (lean * f + bend * f * f) + Vector((0, 0, height * f * (1.0 - 0.25 * f * f)))
        w = width * (1.0 - f * 0.75)
        pts.append((base + off - side * w, base + off + side * w))
    f = 1.0
    tip = base + d * (lean + bend) + Vector((0, 0, height * (0.75 if segments else 1.0)))
    prev = [vert(pr, pts[0][0]), vert(pr, pts[0][1])]
    for s in range(1, segments + 1):
        cur = [vert(pr, pts[s][0]), vert(pr, pts[s][1])]
        face(pr, [prev[0], prev[1], cur[1], cur[0]], rgb, thin=True)
        prev = cur
    face(pr, [prev[0], prev[1], vert(pr, tip)], rgb, thin=True)

# -- object -------------------------------------------------------------------
def finish(pr, slot):
    bmesh.ops.triangulate(pr['bm'], faces=pr['bm'].faces[:])
    bmesh.ops.remove_doubles(pr['bm'], verts=pr['bm'].verts[:], dist=1e-5)
    bmesh.ops.dissolve_degenerate(pr['bm'], edges=pr['bm'].edges[:], dist=1e-5)
    bmesh.ops.triangulate(pr['bm'], faces=[f for f in pr['bm'].faces if len(f.verts) > 3])
    name = "LTE_" + pr['key']
    old = bpy.data.objects.get(name)
    if old is not None:
        mesh_old = old.data
        bpy.data.objects.remove(old, do_unlink=True)
        if mesh_old.users == 0:
            bpy.data.meshes.remove(mesh_old)
    mesh = bpy.data.meshes.new(name)
    pr['bm'].to_mesh(mesh)
    pr['bm'].free()
    for i, (rgb, thin) in enumerate(pr['palette']):
        mat_name = "LTE_%s_%d%s" % (pr['key'], i, "_thin" if thin else "")
        mat = bpy.data.materials.get(mat_name) or bpy.data.materials.new(mat_name)
        mat.diffuse_color = (rgb[0], rgb[1], rgb[2], 1.0)
        mat.use_nodes = True
        bsdf = next((n for n in mat.node_tree.nodes if n.type == "BSDF_PRINCIPLED"), None)
        if bsdf is not None:
            bsdf.inputs[0].default_value = (rgb[0], rgb[1], rgb[2], 1.0)
            for inp in bsdf.inputs:
                if inp.name == "Roughness":
                    inp.default_value = 0.95
        mesh.materials.append(mat)
    pal = mesh.attributes["pal"].data
    for poly in mesh.polygons:
        poly.material_index = pal[poly.index].value
        poly.use_smooth = False
    obj = bpy.data.objects.new(name, mesh)
    obj["lte_key"] = pr['key']
    obj["lte_ao"] = list(pr['ao'])
    obj["lte_jitter"] = pr['jitter']
    obj.location = ((slot % 5) * SPACING, -(slot // 5) * SPACING * 1.4, 0.0)
    _collection().objects.link(obj)
    return obj


# =============================================================================
# Props
# =============================================================================

GREY_LOW = (0.62, 0.62, 0.62)
WHITE = (1.0, 1.0, 1.0)


def make_dry_grass_tuft():
    """Sahel dry grass (Andropogon-like): tall, thin, straw blades leaning out."""
    p = new_prop("dry_grass_tuft", 3)
    p['ao'] = (0.6, 0.42)
    p['jitter'] = 0.06
    n = 7
    for i in range(n):
        a = math.tau * i / n + 0.5 * math.sin(i * 2.3)
        d = (math.cos(a), math.sin(a))
        h = 0.48 + 0.22 * abs(math.sin(i * 1.7))
        root = (d[0] * 0.04, d[1] * 0.04, -0.02)
        blade(p, root, d, h, 0.03, 0.1 + 0.05 * (i % 2), 0.1, WHITE if i % 3 else _scale(WHITE, 0.9), segments=0)
    return p


def make_grass_tuft():
    """Short green tuft: a few wider bent blades."""
    p = new_prop("grass_tuft", 4)
    p['ao'] = (0.66, 0.3)
    p['jitter'] = 0.06
    n = 6
    for i in range(n):
        a = math.tau * i / n + 0.4 * math.sin(i * 2.9)
        d = (math.cos(a), math.sin(a))
        h = 0.3 + 0.14 * abs(math.sin(i * 1.3))
        root = (d[0] * 0.035, d[1] * 0.035, -0.02)
        blade(p, root, d, h, 0.045, 0.06, 0.08, WHITE if i % 2 else _scale(WHITE, 0.92), segments=0)
    return p


def make_rock():
    """Faceted boulder: squashed, irregular icosahedron with a flat bottom."""
    p = new_prop("rock", 5)
    p['ao'] = (0.72, 0.5)
    p['jitter'] = 0.07
    blob(p, (0, 0, 0.16), (0.55, 0.45, 0.36), (0.9, 0.9, 0.9), seed=11, rough=0.34,
         under=(0.7, 0.7, 0.7), flat_bottom=-0.06)
    blob(p, (0.32, -0.22, 0.06), (0.24, 0.2, 0.16), (0.82, 0.82, 0.82), seed=12, rough=0.3,
         under=(0.68, 0.68, 0.68), flat_bottom=-0.06)
    return p


def make_pebbles():
    """Three laterite stones of different sizes."""
    p = new_prop("pebbles", 6)
    p['ao'] = (0.75, 0.25)
    p['jitter'] = 0.08
    blob(p, (-0.12, -0.05, 0.07), (0.2, 0.16, 0.16), (0.92, 0.92, 0.92), seed=3, rough=0.25, flat_bottom=-0.04)
    blob(p, (0.2, 0.1, 0.05), (0.13, 0.12, 0.12), (0.85, 0.85, 0.85), seed=5, rough=0.25, flat_bottom=-0.04, subdiv=1)
    # smallest one: an octahedron is enough
    tmp_c = Vector((0.04, -0.27, 0.02))
    pts = [tmp_c + Vector(v) for v in ((0.09, 0, 0), (-0.08, 0.01, 0), (0, 0.07, 0), (0.01, -0.07, 0), (0, 0, 0.08), (0, 0, -0.03))]
    vs = [vert(p, q) for q in pts]
    col = (0.8, 0.8, 0.8)
    for a, b in ((0, 2), (2, 1), (1, 3), (3, 0)):
        face(p, [vs[a], vs[b], vs[4]], col)
        face(p, [vs[b], vs[a], vs[5]], col)
    return p


def make_shrub():
    """Sahel shrub (Guiera / Combretum): a few olive clumps on thin stems."""
    p = new_prop("shrub", 7)
    p['ao'] = (0.62, 0.55)
    p['jitter'] = 0.07
    olive = _mix(LEAVES, DRY_LEAVES, 0.45)
    blob(p, (0.0, 0.0, 0.52), (0.42, 0.38, 0.3), olive, seed=1, rough=0.2, under=_scale(olive, 0.72))
    blob(p, (0.3, 0.12, 0.34), (0.3, 0.28, 0.24), _mix(LEAVES, DRY_LEAVES, 0.75), seed=2, rough=0.2,
           under=_scale(DRY_LEAVES, 0.7))
    blob(p, (-0.28, -0.14, 0.36), (0.3, 0.3, 0.25), _mix(LEAVES, DRY_LEAVES, 0.2), seed=3, rough=0.2,
           under=_scale(LEAVES, 0.72))
    blob(p, (0.05, -0.3, 0.26), (0.22, 0.2, 0.18), DRY_LEAVES, seed=4, rough=0.2, under=_scale(DRY_LEAVES, 0.72))
    for d in ((0.18, 0.08), (-0.16, -0.08), (0.02, -0.18)):
        tube(p, [(0, 0, -0.04), (d[0], d[1], 0.3)], [0.035, 0.02], 3, BARK, cap=False)
    return p


def make_acacia():
    """Umbrella thorn acacia: slim leaning trunk, 3 forked limbs, layered flat canopy."""
    p = new_prop("acacia", 8)
    p['ao'] = (0.6, 0.35)
    p['jitter'] = 0.05
    dark = _scale(BARK, 0.78)
    fork = Vector((0.05, -0.02, 0.36))
    # The trunk goes a bit past the fork and is capped (a knot); every limb
    # starts inside it, so no gap shows where they split.
    tube(p, [(0, 0, -0.05), (0.02, 0.0, 0.18), fork, fork + Vector((0, 0, 0.035))],
         [0.065, 0.05, 0.042, 0.034], 5, [dark, BARK, BARK], cap=True, jitter=0.08, tip=0.6)
    root = fork - Vector((0, 0, 0.045))
    limbs = [
        [(-0.18, 0.08, 0.6), (-0.42, 0.16, 0.8)],
        [(0.26, -0.1, 0.62), (0.5, -0.12, 0.8)],
        [(0.1, 0.24, 0.64), (0.14, 0.42, 0.84)],
        [(0.02, -0.26, 0.66), (-0.06, -0.4, 0.84)],
    ]
    for mid, tip in limbs:
        tube(p, [root, mid, tip], [0.04, 0.024, 0.012], 4, BARK, cap=True)
    # thin twigs splitting from the limbs (they start a little inside the limb)
    for a, b in (((-0.18, 0.08, 0.6), (-0.2, -0.12, 0.8)), ((0.26, -0.1, 0.62), (0.3, 0.14, 0.82))):
        a = Vector(a)
        tube(p, [a + (fork - a).normalized() * 0.03, b], [0.018, 0.008], 3, BARK, cap=True)
    top = LEAVES
    top_light = _scale(LEAVES, 1.12)
    side = _scale(LEAVES, 0.88)
    under = _scale(LEAVES, 0.74)
    pad(p, (0.04, 0.0, 0.86), 0.7, 0.6, 0.06, 0.05, 9, top, side, under, seed=2, droop=0.035)
    pad(p, (0.36, -0.2, 0.9), 0.36, 0.3, 0.05, 0.04, 7, top_light, side, under, seed=5, droop=0.025)
    pad(p, (-0.34, 0.24, 0.89), 0.34, 0.3, 0.05, 0.04, 7, _scale(LEAVES, 1.05), side, under, seed=7, droop=0.025)
    pad(p, (0.1, 0.3, 0.93), 0.26, 0.22, 0.04, 0.03, 6, top_light, side, under, seed=9, droop=0.02)
    return p


def make_baobab():
    """Baobab in the dry season: bottle trunk, stubby root-like bare branches, hanging fruits."""
    p = new_prop("baobab", 9)
    p['ao'] = (0.62, 0.45)
    p['jitter'] = 0.04
    dark = _scale(BAOBAB_BARK, 0.8)
    light = _scale(BAOBAB_BARK, 1.08)
    tube(p, 
        [(0, 0, -0.06), (0, 0, 0.08), (0.0, 0.0, 0.26), (0.01, 0.0, 0.44), (0.02, 0.01, 0.58)],
        [0.25, 0.23, 0.23, 0.2, 0.14],
        9, [dark, BAOBAB_BARK, BAOBAB_BARK, light], cap=True, jitter=0.12, tip=0.2,
    )
    top = Vector((0.02, 0.01, 0.54))
    rng = random.Random(4)
    tips = []
    n = 7
    for i in range(n):
        a = math.tau * i / n + rng.uniform(-0.3, 0.3)
        d = Vector((math.cos(a), math.sin(a), 0))
        spread = rng.uniform(0.26, 0.34)
        elbow = top + d * spread + Vector((0, 0, rng.uniform(0.05, 0.11)))
        tip = elbow + d * rng.uniform(0.12, 0.18) + Vector((0, 0, rng.uniform(0.1, 0.17)))
        tube(p, [top - d * 0.05, elbow, tip], [0.085, 0.05, 0.018], 5, [BAOBAB_BARK, light], cap=True)
        # small fork at the tip
        side = Vector((-d.y, d.x, 0)) * (0.07 if i % 2 else -0.07)
        tube(p, [elbow + (tip - elbow) * 0.4, tip + side + Vector((0, 0, 0.04))], [0.022, 0.008], 3, light, cap=True)
        tips.append((elbow, d))
    # monkey-bread fruits hanging on stalks under three branches
    # short upright branches in the middle of the crown
    for a in (0.6, 2.8, 4.9):
        d = Vector((math.cos(a), math.sin(a), 0))
        tube(p, [top, top + d * 0.1 + Vector((0, 0, 0.2))], [0.06, 0.02], 4, light, cap=True)
    fruit = (0.6, 0.6, 0.45)
    for i in (0, 2, 4, 5):
        elbow, d = tips[i]
        hang = elbow + d * 0.05 - Vector((0, 0, 0.02))
        tube(p, [hang, hang - Vector((0, 0, 0.06))], [0.004, 0.004], 3, BAOBAB_BARK, cap=False)
        c = hang - Vector((0, 0, 0.09))
        vs = [vert(p, c + Vector(o)) for o in ((0.018, 0, 0), (0, 0.018, 0), (-0.018, 0, 0), (0, -0.018, 0),
                                               (0, 0, 0.032), (0, 0, -0.036))]
        for a, b in ((0, 1), (1, 2), (2, 3), (3, 0)):
            face(p, [vs[a], vs[b], vs[4]], fruit)
            face(p, [vs[b], vs[a], vs[5]], _scale(fruit, 0.8))
    return p


def make_termite_mound():
    """Cathedral termite mound (Macrotermes): ribbed main spire, two side spires,
    a lumpy apron. Light grey: the layer tints it with the soil colour."""
    p = new_prop("termite_mound", 10)
    p['ao'] = (0.7, 0.5)
    p['jitter'] = 0.05
    low = (0.8, 0.8, 0.8)
    mid = (0.9, 0.9, 0.9)
    high = (1.0, 1.0, 1.0)

    def spire(base, height, radius, sides, seed):
        rng = random.Random(seed)
        pts, radii = [], []
        steps = 5
        for k in range(steps + 1):
            f = k / steps
            pts.append((base[0] + 0.04 * math.sin(f * 4 + seed), base[1] + 0.04 * math.cos(f * 3 + seed),
                        base[2] + height * f))
            radii.append(radius * (1.0 - 0.88 * f ** 0.9) * rng.uniform(0.92, 1.08))
        cols = [_mix(low, high, k / steps) for k in range(steps)]
        rings = tube(p, pts, radii, sides, cols, cap=True, jitter=0.0, tip=0.6)
        # ribs: push every other ring vertex out
        for ring, d in rings[1:-1]:
            centre = sum((v.co for v in ring), Vector()) / len(ring)
            for i, v in enumerate(ring):
                if i % 2 == 0:
                    v.co = centre + (v.co - centre) * 1.18

    spire((0, 0, 0.02), 1.0, 0.28, 8, 1)
    spire((0.2, 0.1, 0.0), 0.62, 0.17, 6, 2)
    spire((-0.13, -0.18, 0.0), 0.46, 0.15, 6, 3)
    blob(p, (0.0, 0.0, 0.0), (0.44, 0.4, 0.16), low, seed=4, rough=0.15, flat_bottom=-0.06)
    blob(p, (0.22, -0.16, 0.0), (0.18, 0.16, 0.12), mid, seed=6, rough=0.2, flat_bottom=-0.06)
    return p


def make_zebu_skull():
    """Bleached Gobra zebu skull lying on the ground, long lyre-shaped horns.
    Muzzle along Godot +Z (Blender -Y); about 0.6 tall, 1 wide."""
    p = new_prop("zebu_skull", 11)
    p['ao'] = (0.72, 0.18)
    p['jitter'] = 0.04
    bone_dark = _scale(BONE, 0.86)
    hole = (0.17, 0.13, 0.1)

    def mirror_pair(pts):
        return [(x, y, z) for (x, y, z) in pts], [(-x, y, z) for (x, y, z) in pts]

    # Cranium + face as one lofted shape from the poll (back, +Y) to the muzzle (-Y).
    sections = [
        # y, half width, top z, bottom z
        (0.2, 0.15, 0.2, 0.04),
        (0.1, 0.17, 0.24, 0.02),
        (-0.02, 0.15, 0.22, 0.02),
        (-0.16, 0.1, 0.17, 0.03),
        (-0.3, 0.075, 0.12, 0.03),
        (-0.42, 0.06, 0.09, 0.03),
    ]
    rings = []
    for y, w, top, bot in sections:
        mid = (top + bot) * 0.5
        ring = [(w, y, bot + 0.01), (w * 1.05, y, mid), (w * 0.78, y, top), (0.0, y, top + 0.015),
                (-w * 0.78, y, top), (-w * 1.05, y, mid), (-w, y, bot + 0.01), (0.0, y, bot)]
        rings.append([vert(p, q) for q in ring])
    for i in range(len(rings) - 1):
        a, b = rings[i], rings[i + 1]
        for k in range(8):
            j = (k + 1) % 8
            col = BONE if k in (1, 2, 3, 4, 5) else bone_dark
            face(p, [a[k], a[j], b[j], b[k]], col)
    # back cap (poll) and muzzle cap
    face(p, rings[0][::-1], bone_dark)
    face(p, rings[-1], bone_dark)
    # eye sockets: dark triangles set on the sides of the forehead
    for s in (1, -1):
        # eye orbit: a short bony ring sticking out of the side, dark inside
        rings_o = tube(p, [(s * 0.12, -0.04, 0.18), (s * 0.185, -0.06, 0.2)], [0.05, 0.045], 6, BONE, cap=False)
        last = rings_o[-1][0]
        face(p, last, hole)
        # nostril
        if s > 0:
            tri(p, (0.04, -0.43, 0.1), (0.015, -0.43, 0.1), (0.03, -0.43, 0.06), hole)
        else:
            tri(p, (-0.015, -0.43, 0.1), (-0.04, -0.43, 0.1), (-0.03, -0.43, 0.06), hole)
        # horn: out from the poll, back and up, tips turning in (lyre)
        horn = [(s * 0.13, 0.16, 0.2), (s * 0.28, 0.2, 0.22), (s * 0.4, 0.22, 0.32),
                (s * 0.44, 0.2, 0.46), (s * 0.4, 0.16, 0.58), (s * 0.32, 0.12, 0.64)]
        tube(p, horn, [0.06, 0.05, 0.04, 0.03, 0.02, 0.008], 5,
               [BONE, _mix(BONE, HORN, 0.5), HORN, _scale(HORN, 0.85), _scale(HORN, 0.7)], cap=True)
    # rest the skull on the ground (half sunk in the sand)
    for v in p['bm'].verts:
        v.co.z -= 0.045
    return p


def make_dead_tree():
    """Dead tree by a dried waterhole: crooked bleached trunk, bare forked branches,
    a broken stub and roots."""
    p = new_prop("dead_tree", 12)
    p['ao'] = (0.6, 0.4)
    p['jitter'] = 0.05
    dark = _scale(DEAD_WOOD, 0.72)
    light = _scale(DEAD_WOOD, 1.12)
    bend = Vector((0.06, 0.02, 0.3))
    fork = Vector((0.1, -0.03, 0.56))
    tube(p, [(0, 0, -0.05), (0.02, 0.0, 0.12), bend, fork, fork + Vector((0, 0, 0.03))],
           [0.062, 0.052, 0.045, 0.036, 0.03], 5,
           [dark, DEAD_WOOD, DEAD_WOOD, DEAD_WOOD], cap=True, jitter=0.1, tip=0.6)
    root = fork - Vector((0, 0, 0.04))
    branches = [
        [(-0.12, -0.06, 0.76), (-0.32, -0.04, 0.88), (-0.4, 0.06, 1.0)],
        [(0.28, -0.08, 0.82), (0.42, 0.04, 0.96)],
        [(0.12, 0.16, 0.86), (0.06, 0.3, 1.04)],
    ]
    for br in branches:
        tube(p, [root] + br, [0.034] + [0.02] * (len(br) - 1) + [0.006], 4, [DEAD_WOOD] + [light] * len(br), cap=True)
    # twigs
    for a, b in (((-0.12, -0.06, 0.76), (-0.14, -0.22, 0.94)), ((0.28, -0.08, 0.82), (0.4, -0.2, 0.86)),
                 ((0.12, 0.16, 0.86), (0.24, 0.24, 0.98))):
        a = Vector(a)
        tube(p, [a + (fork - a).normalized() * 0.03, b], [0.016, 0.004], 3, light, cap=True)
    # broken stub
    tube(p, [bend - Vector((0, 0, 0.04)), bend + Vector((-0.16, 0.05, 0.06))], [0.026, 0.02], 4, DEAD_WOOD, cap=True, tip=0.0)
    # roots
    for a in (0.3, 2.4, 4.3):
        d = Vector((math.cos(a), math.sin(a), 0))
        tube(p, [(0, 0, 0.06), tuple(d * 0.12 + Vector((0, 0, 0.0))), tuple(d * 0.2 + Vector((0, 0, -0.05)))],
               [0.035, 0.022, 0.006], 4, dark, cap=True)
    return p


# Explicit calls: the Blender MCP safe mode refuses calls through a variable.
def build_all():
    return [
        finish(make_grass_tuft(), 0), finish(make_dry_grass_tuft(), 1), finish(make_rock(), 2),
        finish(make_pebbles(), 3), finish(make_shrub(), 4), finish(make_acacia(), 5),
        finish(make_baobab(), 6), finish(make_termite_mound(), 7), finish(make_zebu_skull(), 8),
        finish(make_dead_tree(), 9),
    ]


def stats():
    out = []
    coll = bpy.data.collections.get(COLLECTION)
    names = sorted(o.name for o in coll.objects)
    for name in names:
        obj = coll.objects[name]
        me = obj.data
        dims = obj.dimensions
        out.append("%-20s tris=%4d  size x=%.2f y=%.2f z=%.2f  colours=%d" % (
            obj["lte_key"], len(me.polygons), dims.x, dims.y, dims.z, len(me.materials)))
    return "\n".join(out)


# =============================================================================
# Export: one GLB with every prop (materials = palette, "_thin" materials are
# double-sided blades), converted for Godot by tools/blender/glb_to_gdscript.py.
# =============================================================================

def export_glb(path):
    bpy.ops.object.select_all(action="DESELECT")
    for obj in bpy.data.collections[COLLECTION].objects:
        obj.select_set(True)
    bpy.ops.export_scene.gltf(filepath=path, export_format="GLB", use_selection=True,
                              export_extras=True, export_apply=False)
    return path
