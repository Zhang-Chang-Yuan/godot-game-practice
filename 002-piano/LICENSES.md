# 第三方资源与授权

本工程包含第三方音频采样。**再分发时必须保留下列署名**（CC BY 3.0 的强制要求）。

---

## 1. 钢琴采样 —— `audio/piano/*.mp3`（88 个文件）

| 项目 | 内容 |
|---|---|
| 音色 | FluidR3_GM 音色库中的 `acoustic_grand_piano` |
| 采样作者 | **Frank Wen** &lt;getfrank@gmail.com&gt;（FluidR3 / FluidR3_GM.sf2，出处见下方第 ③ 条） |
| 采样授权 | **Creative Commons Attribution 3.0（CC BY 3.0）** |
| 打包分发 | [gleitz/midi-js-soundfonts](https://github.com/gleitz/midi-js-soundfonts)（`gh-pages` 分支） |
| 打包者 / 授权 | © 2012 Benjamin Gleitzman，**MIT License** |
| 实际下载地址 | `https://raw.githubusercontent.com/gleitz/midi-js-soundfonts/gh-pages/FluidR3_GM/acoustic_grand_piano-mp3.js` |
| 覆盖范围 | **A0 – C8，完整 88 键**，每键一个独立采样（无音高移位） |
| 格式 | MP3，44.1 kHz / **Joint Stereo**（MP3 帧头声道模式，88/88 一致），单个文件 14,327–25,585 字节，合计约 1.97 MB |
| 实测时长 | **3.129 秒**（88 个文件完全一致；由 Godot 4.7.2 解码器实测 `AudioStream.get_length()`） |
| 实测解码 | **88/88 成功**，全部为 `AudioStreamMP3`，无加载失败 |

### 必须随附的署名文本

> Piano samples: FluidR3_GM soundfont (`acoustic_grand_piano`), by Frank Wen,
> licensed under [Creative Commons Attribution 3.0](https://creativecommons.org/licenses/by/3.0/us/).
> Packaged for the web as [midi-js-soundfonts](https://github.com/gleitz/midi-js-soundfonts)
> by Benjamin Gleitzman (MIT License).

### 授权与归属的原文出处

本工程涉及**两个层级**的第三方声明。逐条列出出处，不做合并归因：

**① CC BY 3.0 声明（针对本次实际下载的渲染版）**
- 出处：`midi-js-soundfonts` 仓库 `gh-pages` 分支的 `README.md`
- 原文：`Fluid Soundfont / Generated from FluidR3_GM.sf2 / Released under Creative Commons Attribution 3.0 license`
- 链接：https://raw.githubusercontent.com/gleitz/midi-js-soundfonts/gh-pages/README.md

**② MIT 声明（针对打包仓库的代码/脚本）**
- 出处：同仓库 `LICENSE.txt`
- 原文：`Copyright (C) 2012 Benjamin Gleitzman (gleitz@mit.edu)` + 标准 MIT 条款
- 链接：https://raw.githubusercontent.com/gleitz/midi-js-soundfonts/gh-pages/LICENSE.txt

**③ 「Frank Wen 是 Fluid / FluidR3_GM 作者」这一条不在上面两个文件里**
- 出处：Debian `fluid-soundfont` 包的 `debian/copyright`
- 原文：`Frank Wen <getfrank@gmail.com>` / `Copyright © 2000-2002, 2008 Frank Wen`
- 链接：https://sources.debian.org/data/main/f/fluid-soundfont/3.1-5.3/debian/copyright

> **⚠️ 授权层级差异（重要）**：第 ③ 条出处同时记载了作者本人的声明
> `I hereby release Fluid under the MIT license`——即**原始音色库按 MIT 发布**；
> 而第 ① 条把 `midi-js-soundfonts` 的渲染版标为 **CC BY 3.0**。
> 两者是不同层级、不同来源的声明。
> **本工程按更严格的一方（CC BY 3.0）履行署名义务**——完整署名同时满足 MIT 的要求。

### 重命名与转写说明（重要）

上游用**降号**记法（`Bb0`、`Db1`、`Ab7`），本工程统一改成**升号**，并把 `#` 换成 `s`：

| 上游键名 | 本工程文件名 |
|---|---|
| `A0` | `A0.mp3` |
| `Bb0` | `As0.mp3` |
| `Db1` | `Cs1.mp3` |
| `Ab7` | `Gs7.mp3` |
| `C8` | `C8.mp3` |

- 降号 → 升号映射：`Db→C#`、`Eb→D#`、`Gb→F#`、`Ab→G#`、`Bb→A#`
- `#` → `s` 的原因：`#` 在 Godot 的 `res://` 资源路径里有 URL fragment 歧义，不安全
- 转换规则与 [`MusicTheory.midi_to_filename()`](../scripts/music_theory.gd) 逐字一致；
  抽取时做过**集合全等校验**：期望 88 个文件名，实际写出 88 个，**缺失 0、多余 0**

---

## 2. 节拍器点击音

**不含任何第三方资源。**

重音（1600 Hz）与弱拍（900 Hz）的 PCM 数据由
[`metronome.gd`](../scripts/autoload/metronome.gd) 的 `_make_click_stream()`
在运行时用正弦波 + 指数衰减包络**代码生成**
（44.1 kHz / 16 bit / 单声道 / 40 ms / 首尾淡入淡出防爆音），
不读取任何外部音频文件，也不使用 `AudioStreamGenerator`。

---

## 3. 引擎与运行时

| 项目 | 授权 |
|---|---|
| Godot Engine 4.7.2 stable | MIT License —— https://godotengine.org |

本工程未引入任何第三方 Godot 插件或 GDExtension。
