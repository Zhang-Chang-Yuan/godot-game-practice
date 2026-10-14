# -*- coding: utf-8 -*-
"""
Learn About Geometry — Blender 4.5 asset factory
=================================================
Builds six primitive shapes and exports each one as a single-file GLB:

    Cube     正方体    - default cube, square faces
    Cuboid   长方体    - scaled cube, compare with the cube
    Sphere   球体      - UV sphere, low-poly (Segments=16, Rings=8)
    Cylinder 圆柱体    - 12 vertices, curved surface + round caps
    Cone     圆锥体    - sharp tip, contrast with the cylinder
    Pyramid  四棱锥    - 4-sided cone, pyramid silhouette

Material: flat, matte, kid-friendly colors.
Roughness = 0.9 (0.8~1 range), Metallic = 0, Specular = 0 -> no harsh highlights.

Run headless:
    "C:\\Hub\\program\\blender 4.5\\blender.exe" -b --factory-startup --python export_geometry.py

A canonical copy of this script lives in the project at tools/export_geometry.py
"""

import os
import traceback

import bpy

PROJECT_DIR = r"C:\Hub\workspace\godot-game-practice\001-learn-about-geometry"
MODELS_DIR = os.path.join(PROJECT_DIR, "models")
TMP_DIR = os.path.join(PROJECT_DIR, "tmp")

os.makedirs(MODELS_DIR, exist_ok=True)
os.makedirs(TMP_DIR, exist_ok=True)

# name, color (linear-ish sRGB float), factory, kwargs, z-lift for preview
SHAPES = [
    ("Cube", (0.882, 0.294, 0.294), "cube", dict(size=1.6), 0.80),
    ("Cuboid", (0.941, 0.541, 0.141), "cube", dict(size=1.0, scale=(0.9, 0.65, 1.8)), 0.90),
    ("Sphere", (0.231, 0.510, 0.910), "sphere", dict(radius=0.85, segments=16, ring_count=8), 0.85),
    ("Cylinder", (0.208, 0.722, 0.478), "cylinder", dict(vertices=12, radius=0.7, depth=1.7), 0.85),
    ("Cone", (0.608, 0.349, 0.816), "cone", dict(vertices=12, radius1=0.75, radius2=0.0, depth=1.8), 0.90),
    ("Pyramid", (0.949, 0.761, 0.188), "cone", dict(vertices=4, radius1=0.95, radius2=0.0, depth=1.5), 0.75),
]


# ---------------------------------------------------------------- scene utils
def clean_scene():
    """Remove every object and purge orphaned data blocks."""
    if bpy.context.object and bpy.context.object.mode != 'OBJECT':
        bpy.ops.object.mode_set(mode='OBJECT')
    bpy.ops.object.select_all(action='SELECT')
    bpy.ops.object.delete(use_global=False)
    purge_orphans()


def purge_orphans():
    for block in (bpy.data.meshes, bpy.data.curves, bpy.data.materials,
                  bpy.data.cameras, bpy.data.lights, bpy.data.images):
        for item in list(block):
            if item.users == 0:
                block.remove(item)


def make_material(name, rgb):
    """Pure matte color material: no metallic, no specular highlight."""
    mat = bpy.data.materials.new(name + "Mat")
    mat.diffuse_color = (*rgb, 1.0)
    mat.use_nodes = True
    bsdf = mat.node_tree.nodes.get("Principled BSDF")
    bsdf.inputs["Base Color"].default_value = (*rgb, 1.0)
    bsdf.inputs["Roughness"].default_value = 0.9
    bsdf.inputs["Metallic"].default_value = 0.0
    try:  # Blender 4.x input, kills the shiny dot highlights
        bsdf.inputs["Specular IOR Level"].default_value = 0.0
    except KeyError:
        pass
    return mat


def add_shape(name, color, kind, kw):
    """Create one primitive at the origin, centered, transform baked."""
    if kind == "cube":
        bpy.ops.mesh.primitive_cube_add(size=kw["size"], scale=kw.get("scale", (1, 1, 1)))
        obj = bpy.context.active_object
        bpy.ops.object.transform_apply(location=False, rotation=False, scale=True)
    elif kind == "sphere":
        bpy.ops.mesh.primitive_uv_sphere_add(radius=kw["radius"],
                                             segments=kw["segments"],
                                             ring_count=kw["ring_count"])
        obj = bpy.context.active_object
    elif kind == "cylinder":
        bpy.ops.mesh.primitive_cylinder_add(vertices=kw["vertices"],
                                            radius=kw["radius"],
                                            depth=kw["depth"])
        obj = bpy.context.active_object
    elif kind == "cone":
        bpy.ops.mesh.primitive_cone_add(vertices=kw["vertices"],
                                        radius1=kw["radius1"],
                                        radius2=kw["radius2"],
                                        depth=kw["depth"])
        obj = bpy.context.active_object
    else:
        raise ValueError("unknown kind: %s" % kind)

    obj.name = name
    obj.data.name = name + "Mesh"
    obj.location = (0.0, 0.0, 0.0)
    obj.data.materials.append(make_material(name, color))
    return obj


def export_glb(obj, path):
    bpy.ops.object.select_all(action='DESELECT')
    obj.select_set(True)
    bpy.context.view_layer.objects.active = obj
    bpy.context.view_layer.update()
    bpy.ops.export_scene.gltf(
        filepath=path,
        export_format='GLB',
        use_selection=True,
        export_apply=True,
        export_yup=True,
        export_animations=False,
        export_skins=False,
        export_tangents=False,
        export_materials='EXPORT',
        export_image_format='AUTO',
    )


def tri_count(obj):
    dg = bpy.context.evaluated_depsgraph_get()
    ev = obj.evaluated_get(dg)
    me = ev.to_mesh()
    nv = len(me.vertices)
    tris = sum(len(p.vertices) - 2 for p in me.polygons)
    ev.to_mesh_clear()
    return nv, tris


# ---------------------------------------------------------------- main build
def main():
    print("=" * 64)
    print("Learn About Geometry - building 6 shapes")
    print("=" * 64)
    report = []
    for name, color, kind, kw, _lift in SHAPES:
        clean_scene()
        obj = add_shape(name, color, kind, kw)
        verts, tris = tri_count(obj)
        path = os.path.join(MODELS_DIR, name + ".glb")
        export_glb(obj, path)
        size_kb = os.path.getsize(path) / 1024.0
        report.append((name, path, verts, tris, size_kb))
        print("[OK] %-8s verts=%3d tris=%4d  %8.1f KB  -> %s" % (name, verts, tris, size_kb, path))

    print("-" * 64)
    print("%d GLB files written to %s" % (len(report), MODELS_DIR))
    render_preview()


# ---------------------------------------------------------------- preview
def render_preview():
    """Workbench preview image of all six shapes (falls back to Cycles)."""
    try:
        clean_scene()

        # ground plane
        bpy.ops.mesh.primitive_plane_add(size=40, location=(0, 0, 0))
        ground = bpy.context.active_object
        ground.name = "Ground"
        ground_mat = make_material("Ground", (0.93, 0.93, 0.95))
        ground.data.materials.append(ground_mat)

        # six shapes in a row
        models = []
        step = 2.5
        for i, (name, color, kind, kw, lift) in enumerate(SHAPES):
            obj = add_shape(name, color, kind, kw)
            obj.location = ((i - (len(SHAPES) - 1) / 2.0) * step, 0.0, lift)
            models.append(obj)

        scene = bpy.context.scene
        scene.render.engine = 'BLENDER_WORKBENCH'
        scene.display.shading.light = 'STUDIO'
        scene.display.shading.color_type = 'TEXTURE'
        scene.display.shading.show_shadows = True
        scene.render.resolution_x = 1280
        scene.render.resolution_y = 480
        scene.render.image_settings.file_format = 'PNG'

        bpy.ops.object.camera_add(location=(0.5, 12.5, 4.2), rotation=(1.35, 0.0, 0.0))
        cam = bpy.context.active_object
        cam.data.lens = 55
        scene.camera = cam

        bpy.ops.object.light_add(type='SUN', location=(0, 0, 6))
        sun = bpy.context.active_object
        sun.data.energy = 0.6

        out = os.path.join(TMP_DIR, "preview_shapes.png")
        scene.render.filepath = out
        try:
            bpy.ops.render.render(write_still=True)
            print("[OK] workbench preview -> %s" % out)
        except Exception as werr:
            print("[WARN] workbench failed (%s), trying Cycles..." % werr)
            scene.render.engine = 'CYCLES'
            scene.cycles.samples = 16
            scene.cycles.use_denoising = False
            bpy.ops.render.render(write_still=True)
            print("[OK] cycles preview -> %s" % out)
    except Exception:
        print("[ERROR] preview render failed:")
        traceback.print_exc()


main()
