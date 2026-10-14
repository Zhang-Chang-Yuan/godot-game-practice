# -*- coding: utf-8 -*-
"""用 Blender 4.5 的 bpy / mathutils 生成 7 个涂色图案的区域多边形 JSON。

为什么用 Blender：本玩法是 **2D 涂色**，需要的是「可点击填充的封闭区域多边形」，
3D 模型在这里是多余的。所以把 Blender 当作 **2D 几何生成器** 使用：

  - mathutils.geometry.interpolate_bezier  把少量控制点插值成平滑的有机轮廓（花瓣/叶/翅/尾）
  - mathutils.geometry.tessellate_polygon  校验每个多边形是简单多边形（能三角化成 n-2 个三角形）
  - bpy.data.meshes.from_pydata + calc_loop_triangles  把多边形建成真实网格做二次校验

运行：
  & "C:\\Hub\\program\\blender 4.5\\blender.exe" -b --factory-startup --python tools/generate_patterns.py

输出：assets/patterns/{flower,grass,butterfly,dog,bee,cat,pig}.json
完全确定性：不使用 random，同一份脚本跑两次输出逐字节相同。
"""

import bpy
import json
import math
import os
import sys
from mathutils import Vector
from mathutils.geometry import interpolate_bezier, tessellate_polygon

CANVAS = 512
HERE = os.path.dirname(os.path.abspath(__file__))
OUT_DIR = os.path.join(os.path.dirname(HERE), "assets", "patterns")

MAX_POINTS = 22
MIN_AREA = 120.0


# ---------------------------------------------------------------- 几何工具

def _dedupe(pts, eps=0.35):
    """去掉相邻重复点（含首尾重复）"""
    out = []
    for p in pts:
        if not out or math.hypot(p[0] - out[-1][0], p[1] - out[-1][1]) > eps:
            out.append([float(p[0]), float(p[1])])
    if len(out) > 1 and math.hypot(out[0][0] - out[-1][0], out[0][1] - out[-1][1]) <= eps:
        out.pop()
    return out


def _cap(pts, max_n=MAX_POINTS):
    """等间隔抽稀到不超过 max_n 个点（保证顶点数可控）"""
    if len(pts) <= max_n:
        return pts
    step = len(pts) / float(max_n)
    return [pts[int(i * step)] for i in range(max_n)]


def _round(pts, nd=1):
    return [[round(p[0], nd), round(p[1], nd)] for p in pts]


def ellipse(cx, cy, rx, ry, n=20, rot_deg=0.0):
    """（可旋转的）椭圆"""
    a = math.radians(rot_deg)
    ca, sa = math.cos(a), math.sin(a)
    pts = []
    for i in range(n):
        t = 2.0 * math.pi * i / n
        x, y = rx * math.cos(t), ry * math.sin(t)
        pts.append([cx + x * ca - y * sa, cy + x * sa + y * ca])
    return pts


def capsule(x0, y0, x1, y1, width, n=8):
    """从 (x0,y0) 到 (x1,y1) 的胶囊（两端半圆）——用于茎、腿、身体、条纹"""
    a = math.atan2(y1 - y0, x1 - x0)
    r = width * 0.5
    pts = []
    for i in range(n + 1):                      # 端 A 半圆
        ang = a + math.pi * 0.5 + math.pi * i / n
        pts.append([x0 + r * math.cos(ang), y0 + r * math.sin(ang)])
    for i in range(n + 1):                      # 端 B 半圆
        ang = a - math.pi * 0.5 + math.pi * i / n
        pts.append([x1 + r * math.cos(ang), y1 + r * math.sin(ang)])
    return _dedupe(pts)


def petal(cx, cy, angle_deg, length, width, res=8):
    """从 (cx,cy) 沿 angle_deg 方向伸出的花瓣/叶/翅/尾。

    用两段三次贝塞尔拼成闭合轮廓（这是真正用到 Blender 几何库的地方）。
    """
    a = math.radians(angle_deg)
    ca, sa = math.cos(a), math.sin(a)

    def P(d, off):
        return Vector((cx + ca * d - sa * off, cy + sa * d + ca * off))

    base = P(0.0, 0.0)
    tip = P(length, 0.0)
    seg_a = [base, P(length * 0.30, -width * 0.85), P(length * 0.72, -width * 0.78), tip]
    seg_b = [tip, P(length * 0.72, +width * 0.78), P(length * 0.30, +width * 0.85), base]

    pts = []
    for seg in (seg_a, seg_b):
        pts.extend(interpolate_bezier(seg[0], seg[1], seg[2], seg[3], res))
    return _dedupe([[v.x, v.y] for v in pts])


# ---------------------------------------------------------------- 校验（真的用 bpy）

def shoelace_area(pts):
    acc = 0.0
    n = len(pts)
    for i in range(n):
        x0, y0 = pts[i]
        x1, y1 = pts[(i + 1) % n]
        acc += x0 * y1 - x1 * y0
    return abs(acc) * 0.5


def tessellate_ok(pts):
    """用 mathutils.geometry.tessellate_polygon 校验是简单多边形：应得 n-2 个三角形"""
    vecs = [Vector((p[0], p[1], 0.0)) for p in pts]
    try:
        tris = tessellate_polygon([vecs])
    except Exception:
        return False, -1
    return len(tris) == len(pts) - 2, len(tris)


def mesh_ok(pts):
    """用 bpy 把多边形建成真实网格并三角化，返回三角形数（-1 表示失败）"""
    me = bpy.data.meshes.new("_validate_tmp")
    try:
        me.from_pydata([(p[0], p[1], 0.0) for p in pts], [], [list(range(len(pts)))])
        me.update()
        me.calc_loop_triangles()
        return len(me.loop_triangles)
    except Exception:
        return -1
    finally:
        bpy.data.meshes.remove(me)


# ---------------------------------------------------------------- 7 个图案

def pattern_flower():
    r = []
    r.append(("stem", "花茎", capsule(256, 300, 256, 468, 16), 1))
    r.append(("leaf_l", "左叶", petal(248, 382, 197, 78, 46), 2))
    r.append(("leaf_r", "右叶", petal(264, 404, 343, 78, 46), 2))
    r.append(("core", "花心", ellipse(256, 244, 36, 36), 10))
    for i, ang in enumerate((-90, -18, 54, 126, 198)):
        a = math.radians(ang)
        bx = 256 + 36 * math.cos(a)
        by = 244 + 36 * math.sin(a)
        r.append(("petal_%d" % i, "花瓣%d" % (i + 1), petal(bx, by, ang, 96, 58), 5))
    return r


def pattern_grass():
    r = [("mound", "土堆", ellipse(256, 462, 168, 40), 1)]
    spec = [(130, -78, 150, 30), (180, -86, 210, 34), (226, -92, 260, 36),
            (286, -88, 240, 34), (336, -94, 190, 32), (386, -82, 140, 28)]
    for i, (x, ang, ln, w) in enumerate(spec):
        r.append(("blade_%d" % i, "草叶%d" % (i + 1), petal(x, 450, ang, ln, w), 2))
    return r


def pattern_butterfly():
    r = [
        ("body", "身体", capsule(256, 200, 256, 372, 26), 3),
        ("antenna_l", "左触角", petal(252, 200, -125, 62, 10), 4),
        ("antenna_r", "右触角", petal(260, 200, -55, 62, 10), 4),
        ("wing_ul", "左上翅", ellipse(160, 234, 66, 54, rot_deg=22), 2),
        ("wing_ur", "右上翅", ellipse(352, 234, 66, 54, rot_deg=-22), 2),
        ("wing_ll", "左下翅", ellipse(172, 328, 56, 46, rot_deg=-14), 2),
        ("wing_lr", "右下翅", ellipse(340, 328, 56, 46, rot_deg=14), 2),
    ]
    return r


def pattern_dog():
    r = [
        ("body", "身体", ellipse(256, 318, 68, 88), 1),
        ("leg_0", "左前腿", capsule(212, 402, 212, 476, 26), 1),
        ("leg_1", "右前腿", capsule(244, 402, 244, 478, 26), 1),
        ("leg_2", "左后腿", capsule(272, 402, 272, 478, 26), 1),
        ("leg_3", "右后腿", capsule(304, 402, 304, 476, 26), 1),
        ("tail", "尾巴", petal(322, 302, -38, 96, 26), 2),
        ("ear_l", "左耳", ellipse(188, 106, 28, 42, rot_deg=20), 2),
        ("ear_r", "右耳", ellipse(324, 106, 28, 42, rot_deg=-20), 2),
        ("head", "头", ellipse(256, 168, 76, 66), 3),
        ("muzzle", "嘴部", ellipse(256, 224, 34, 20), 4),
        ("nose", "鼻子", ellipse(256, 202, 15, 11), 5),
        ("eye_l", "左眼", ellipse(230, 160, 11, 12), 4),
        ("eye_r", "右眼", ellipse(282, 160, 11, 12), 4),
    ]
    return r


def pattern_bee():
    r = [
        ("body", "身体", ellipse(300, 252, 92, 64), 2),
        ("stinger", "螫针", petal(390, 252, 8, 42, 18), 2),
        ("head", "头", ellipse(152, 250, 42, 40), 3),
        ("antenna_l", "左触角", petal(136, 216, -125, 52, 9), 4),
        ("antenna_r", "右触角", petal(160, 214, -60, 52, 9), 4),
        ("stripe_0", "条纹1", capsule(268, 206, 268, 298, 24), 3),
        ("stripe_1", "条纹2", capsule(308, 200, 308, 304, 24), 3),
        ("stripe_2", "条纹3", capsule(348, 212, 348, 292, 24), 3),
        ("wing_l", "左翅", ellipse(258, 162, 42, 28, rot_deg=24), 4),
        ("wing_r", "右翅", ellipse(326, 158, 42, 28, rot_deg=-20), 4),
    ]
    return r


def pattern_cat():
    r = [
        ("body", "身体", ellipse(256, 320, 62, 84), 1),
        ("leg_0", "左前腿", capsule(214, 398, 214, 474, 24), 1),
        ("leg_1", "右前腿", capsule(242, 400, 242, 478, 24), 1),
        ("leg_2", "左后腿", capsule(270, 400, 270, 478, 24), 1),
        ("leg_3", "右后腿", capsule(298, 398, 298, 474, 24), 1),
        ("tail", "尾巴", petal(312, 330, -50, 110, 22), 2),
        ("ear_l", "左耳", petal(212, 128, -125, 62, 44), 2),
        ("ear_r", "右耳", petal(300, 128, -55, 62, 44), 2),
        ("head", "头", ellipse(256, 176, 72, 62), 3),
        ("muzzle", "嘴部", ellipse(256, 206, 26, 16), 4),
        ("nose", "鼻子", ellipse(256, 196, 11, 9), 5),
        ("eye_l", "左眼", ellipse(232, 168, 10, 13), 4),
        ("eye_r", "右眼", ellipse(280, 168, 10, 13), 4),
    ]
    return r


def pattern_pig():
    r = [
        ("body", "身体", ellipse(256, 322, 74, 86), 1),
        ("leg_0", "左前腿", capsule(206, 400, 206, 470, 26), 1),
        ("leg_1", "右前腿", capsule(238, 402, 238, 474, 26), 1),
        ("leg_2", "左后腿", capsule(274, 402, 274, 474, 26), 1),
        ("leg_3", "右后腿", capsule(306, 400, 306, 470, 26), 1),
        ("tail", "尾巴", ellipse(338, 294, 18, 18), 2),
        ("ear_l", "左耳", petal(206, 122, -118, 52, 46), 2),
        ("ear_r", "右耳", petal(306, 122, -62, 52, 46), 2),
        ("head", "头", ellipse(256, 176, 76, 66), 3),
        ("snout", "猪鼻", ellipse(256, 208, 34, 24), 4),
        ("nostril_l", "左鼻孔", ellipse(246, 208, 8, 10), 5),
        ("nostril_r", "右鼻孔", ellipse(266, 208, 8, 10), 5),
        ("eye_l", "左眼", ellipse(230, 166, 10, 11), 4),
        ("eye_r", "右眼", ellipse(282, 166, 10, 11), 4),
    ]
    return r


PATTERNS = [
    ("flower", "小花", pattern_flower),
    ("grass", "小草", pattern_grass),
    ("butterfly", "蝴蝶", pattern_butterfly),
    ("dog", "小狗", pattern_dog),
    ("bee", "蜜蜂", pattern_bee),
    ("cat", "小猫", pattern_cat),
    ("pig", "小猪", pattern_pig),
]


# ---------------------------------------------------------------- 主流程

def build_pattern(name, display, fn):
    errs = []
    regions = []
    seen = set()
    for rid, label, raw, z in fn():
        pts = _round(_cap(_dedupe(raw)))
        if rid in seen:
            errs.append("%s: id 重复" % rid)
        seen.add(rid)
        if len(pts) < 3:
            errs.append("%s: 顶点不足 3" % rid)
            continue
        for (x, y) in pts:
            if x < 0.0 or x > CANVAS or y < 0.0 or y > CANVAS:
                errs.append("%s: 坐标越界 (%.1f, %.1f)" % (rid, x, y))
        ok_t, nt = tessellate_ok(pts)
        if not ok_t:
            errs.append("%s: tessellate 失败（三角形 %d，期望 %d）" % (rid, nt, len(pts) - 2))
        mt = mesh_ok(pts)
        if mt != len(pts) - 2:
            errs.append("%s: bpy 网格三角化异常（%d，期望 %d）" % (rid, mt, len(pts) - 2))
        ar = shoelace_area(pts)
        if ar <= MIN_AREA:
            errs.append("%s: 面积过小 %.1f" % (rid, ar))
        regions.append({"id": rid, "label": label, "polygon": pts, "z": int(z)})

    if len(regions) < 6 or len(regions) > 16:
        errs.append("区域数 %d 不在 6~16" % len(regions))

    data = {
        "version": 1,
        "name": name,
        "display_name": display,
        "width": CANVAS,
        "height": CANVAS,
        "regions": regions,
    }
    return data, errs


def main():
    if not os.path.isdir(OUT_DIR):
        os.makedirs(OUT_DIR)

    rows = []
    all_errs = []
    for name, display, fn in PATTERNS:
        data, errs = build_pattern(name, display, fn)
        path = os.path.join(OUT_DIR, "%s.json" % name)
        with open(path, "w", encoding="utf-8") as f:
            json.dump(data, f, ensure_ascii=False, indent=1)
            f.write("\n")
        total_area = sum(shoelace_area(r["polygon"]) for r in data["regions"])
        nverts = sum(len(r["polygon"]) for r in data["regions"])
        rows.append((name, len(data["regions"]), total_area, nverts, "OK" if not errs else "FAIL"))
        for e in errs:
            all_errs.append("%s: %s" % (name, e))

    print("")
    print("%-10s | %6s | %10s | %7s | %s" % ("name", "区域数", "总面积", "顶点数", "校验"))
    print("-" * 52)
    for name, cnt, area, nv, st in rows:
        print("%-10s | %6d | %10.0f | %7d | %s" % (name, cnt, area, nv, st))

    if all_errs:
        print("")
        for e in all_errs:
            print("ERROR: %s" % e)
        print("FAILED")
        sys.exit(1)

    print("")
    print("ALL_OK")
    print("输出目录: %s" % OUT_DIR)


main()
