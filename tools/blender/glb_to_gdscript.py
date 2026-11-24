"""Convert the props GLB exported by lte_props.py into the addon's mesh data.

    python tools/blender/glb_to_gdscript.py lte_props.glb addons/lowpoly_terrain_editor/mesh/detail_mesh_data.gd

Plain Python 3 (no dependency). Each mesh node carrying an "lte_key" extra
becomes one entry of DetailMeshData.PROPS:
- "pal": palette, one r, g, b per material (base colour factor);
- "v": vertices, x, y, z in Godot axes (glTF is already Y-up), rounded to mm;
- "t": triangles, a, b, c, palette index, clockwise seen from outside (Godot);
- "thin": indices of triangles whose material ends with "_thin" (double-sided);
- "ao", "jit": shading parameters from the object's extras.
"""

import json
import struct
import sys

COMPONENT = {5121: ("B", 1), 5123: ("H", 2), 5125: ("I", 4), 5126: ("f", 4)}
COUNT = {"SCALAR": 1, "VEC2": 2, "VEC3": 3, "VEC4": 4}


def read_glb(path):
    data = open(path, "rb").read()
    magic, version, length = struct.unpack_from("<III", data, 0)
    assert magic == 0x46546C67, "not a GLB file"
    offset = 12
    doc, binary = None, b""
    while offset < length:
        chunk_len, chunk_type = struct.unpack_from("<II", data, offset)
        chunk = data[offset + 8:offset + 8 + chunk_len]
        if chunk_type == 0x4E4F534A:
            doc = json.loads(chunk.decode("utf-8"))
        elif chunk_type == 0x004E4942:
            binary = chunk
        offset += 8 + chunk_len
    return doc, binary


def accessor(doc, binary, index):
    acc = doc["accessors"][index]
    view = doc["bufferViews"][acc["bufferView"]]
    fmt, size = COMPONENT[acc["componentType"]]
    n = COUNT[acc["type"]]
    stride = view.get("byteStride", size * n)
    base = view.get("byteOffset", 0) + acc.get("byteOffset", 0)
    out = []
    for i in range(acc["count"]):
        values = struct.unpack_from("<" + fmt * n, binary, base + i * stride)
        out.append(values if n > 1 else values[0])
    return out


def fmt_list(values):
    parts = []
    for v in values:
        if isinstance(v, float):
            s = ("%.3f" % v).rstrip("0").rstrip(".")
            parts.append("0" if s in ("-0", "") else s)
        else:
            parts.append(str(v))
    return ", ".join(parts)


def convert(doc, binary):
    props = {}
    for node in doc.get("nodes", []):
        extras = node.get("extras", {})
        if "mesh" not in node or "lte_key" not in extras:
            continue
        mesh = doc["meshes"][node["mesh"]]
        palette, verts, tris, thin = [], [], [], []
        vert_index = {}
        for prim in mesh["primitives"]:
            mat = doc["materials"][prim["material"]]
            rgb = tuple(round(c, 3) for c in mat.get("pbrMetallicRoughness", {}).get("baseColorFactor", [1, 1, 1, 1])[:3])
            is_thin = mat.get("name", "").endswith("_thin")
            key = (rgb, is_thin)
            if key not in palette:
                palette.append(key)
            pal_index = palette.index(key)
            positions = accessor(doc, binary, prim["attributes"]["POSITION"])
            indices = accessor(doc, binary, prim["indices"])
            remap = []
            for p in positions:
                q = tuple(round(c, 3) + 0.0 for c in p)
                if q not in vert_index:
                    vert_index[q] = len(verts)
                    verts.append(q)
                remap.append(vert_index[q])
            for i in range(0, len(indices), 3):
                a, b, c = remap[indices[i]], remap[indices[i + 1]], remap[indices[i + 2]]
                if a == b or b == c or a == c:
                    continue
                # glTF: counter-clockwise front faces. Godot: clockwise.
                if is_thin:
                    thin.append(len(tris) // 4)
                tris += [a, c, b, pal_index]
        props[extras["lte_key"]] = {
            "pal": [c for (rgb, _thin) in palette for c in rgb],
            "v": [c for v in verts for c in v],
            "t": tris,
            "thin": thin,
            "ao": [float(x) for x in extras.get("lte_ao", [0.7, 0.6])],
            "jit": float(extras.get("lte_jitter", 0.05)),
        }
    return props


def write_gdscript(props, path):
    lines = [
        "@tool",
        "extends RefCounted",
        "## Low-poly prop meshes modelled in Blender by tools/blender/lte_props.py",
        "## and converted by tools/blender/glb_to_gdscript.py. Do not edit by hand.",
        "##",
        "## Per prop: \"pal\" palette (r, g, b per entry), \"v\" vertices (x, y, z in",
        "## cell units, origin at the base), \"t\" triangles (a, b, c vertex indices",
        "## clockwise seen from outside, then a palette index), \"thin\" indices of",
        "## double-sided triangles (blades), \"ao\" (darkest factor at the base, height",
        "## where it fades out), \"jit\" per-triangle shade jitter.",
        "",
        "const PROPS := {",
    ]
    for key in sorted(props):
        p = props[key]
        lines.append('\t"%s": {' % key)
        lines.append('\t\t"pal": [%s],' % fmt_list(p["pal"]))
        lines.append('\t\t"v": [%s],' % fmt_list([float(x) for x in p["v"]]))
        lines.append('\t\t"t": [%s],' % fmt_list(p["t"]))
        lines.append('\t\t"thin": [%s],' % fmt_list(p["thin"]))
        lines.append('\t\t"ao": [%s],' % fmt_list(p["ao"]))
        lines.append('\t\t"jit": %s,' % fmt_list([p["jit"]]))
        lines.append("\t},")
    lines.append("}")
    with open(path, "w", encoding="utf-8", newline="\n") as fh:
        fh.write("\n".join(lines) + "\n")


def main():
    if len(sys.argv) != 3:
        print(__doc__)
        sys.exit(1)
    doc, binary = read_glb(sys.argv[1])
    props = convert(doc, binary)
    write_gdscript(props, sys.argv[2])
    for key in sorted(props):
        p = props[key]
        print("%-16s %4d tris  %4d verts  %2d colours  %3d thin" % (
            key, len(p["t"]) // 4, len(p["v"]) // 3, len(p["pal"]) // 3, len(p["thin"])))


if __name__ == "__main__":
    main()
