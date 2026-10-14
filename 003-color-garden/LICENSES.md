# 第三方资源与授权

## 结论：本工程**不含任何第三方素材**

7 个图案（小花 / 小草 / 蝴蝶 / 小狗 / 蜜蜂 / 小猫 / 小猪）的**全部图形数据都是本仓库自己生成的**，
由 `tools/generate_patterns.py` 在 **Blender 4.5.14 LTS** 里运行（bpy / mathutils）产出，
输出为 `assets/patterns/*.json`（每个图案的区域多边形）。

- **没有**引用任何外部图片、图标、字体或音频文件
- **没有**引入任何第三方 Godot 插件或 GDExtension
- 图案的几何形状由脚本里的参数方程 + 贝塞尔插值计算得出，**完全确定性**（无随机数），
  同一份脚本跑两次输出逐字节相同

因此本工程可以按你选择的任意许可证再分发（音频/图片授权问题不存在）。

---

## 用到的工具（各自的许可证）

| 工具 | 用途 | 授权 |
|---|---|---|
| [Blender](https://www.blender.org/) 4.5.14 LTS | 运行 `tools/generate_patterns.py`，把 Blender 当作 **2D 几何生成器** | GPL（**只在生成阶段使用，不参与运行时**；生成出的 JSON 数据不受 GPL 约束） |
| [Godot Engine](https://godotengine.org/) 4.7.2 | 游戏运行时 | MIT |

> **为什么用 Blender 却不产出 3D 模型**：本玩法是 2D 涂色，需要的是「可点击填充的封闭区域多边形」，
> 3D 模型在这里是多余的。所以把 Blender 当 2D 几何库使用：
> `mathutils.geometry.interpolate_bezier` 做有机轮廓插值、
> `mathutils.geometry.tessellate_polygon` 校验多边形是简单多边形、
> `bpy.data.meshes.from_pydata` + `calc_loop_triangles` 做二次网格校验。

---

## 重新生成图案

```powershell
& "C:\Hub\program\blender 4.5\blender.exe" -b --factory-startup --python tools\generate_patterns.py
```

脚本自带自检：顶点数、重复点、坐标越界、可三角化性、面积下限、id 唯一性、区域数范围，
任何一条不满足就打印 `ERROR: ...` 并以退出码 1 结束。全部通过时打印 `ALL_OK`。
