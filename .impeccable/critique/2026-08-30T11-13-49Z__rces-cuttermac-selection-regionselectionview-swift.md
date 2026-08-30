---
target: 操作条
total_score: 14
max_score: 40
na_heuristics:
p0_count: 0
p1_count: 4
timestamp: 2026-08-30T11-13-49Z
slug: rces-cuttermac-selection-regionselectionview-swift
---
## Design Health Score

| # | Heuristic | Score | Key Issue |
|---|-----------|------:|-----------|
| 1 | Visibility of System Status | 2 | 有选中态，但尺寸错误静默回退，预览与导出不完全一致 |
| 2 | Match System / Real World | 2 | 文案可懂，但原生 macOS 本地保存使用“下载”不自然 |
| 3 | User Control and Freedom | 1 | 进入标注工具后无法回到选择模式，多数标注也不能撤销 |
| 4 | Consistency and Standards | 1 | 高亮默认输出与 Enter 永远复制相冲突，自绘点击行为也不符合原生按钮 |
| 5 | Error Prevention | 1 | 输出在鼠标按下时即被武装，拖出按钮后松开仍执行 |
| 6 | Recognition Rather Than Recall | 2 | 文字标签可识别，但颜色主要依赖视觉，缺少工具提示和辅助描述 |
| 7 | Flexibility and Efficiency | 2 | 有 Enter/Esc/Delete，但保存、形状、工具和颜色几乎只能用鼠标 |
| 8 | Aesthetic and Minimalist Design | 2 | 分组紧凑，但 19 个同时可见的选择压平了主次层级 |
| 9 | Error Recovery | 1 | 尺寸错误无说明，画笔/直线/箭头错误无法删除或撤销 |
| 10 | Help and Documentation | 0 | 无上下文提示、工具说明、辅助功能描述或恢复指导 |
| **Total** | | **14/40** | **Poor** |

## Design Specificity Verdict

操作条与选区绑定、根据上下空间选择位置，这些是截图工具特有的合理设计；但整体仍像一个把所有功能都排开的开发者控制面板。形状、标注、颜色、尺寸和输出同时争夺注意力，没有体现 Cutter“快速、可预测、少决策”的产品原则。

自动检测器对 Swift 文件返回 0 条结果，但 Swift 不在其声明的可扫描扩展名中，因此这是无覆盖造成的低信号结果，不能视为界面干净。独立技术检查通过真实 `RegionSelectionView` 的受控 AppKit 渲染复现了固定 304×128 操作条，并确认接近全屏的选区会让操作条覆盖选中内容。真实桌面捕获受 macOS 隐私自动化限制，未获得可靠截图，也没有可见浏览器覆盖层。

## Overall Impression

选区、尺寸与操作条的空间关联做得对，但完成一次普通截图时出现的决策过多。最大的机会是把它从“所有能力的常驻面板”改成“一个清晰的完成动作 + 按需展开的编辑能力”。

## What's Working

- 操作条贴近选区，并优先尝试放在选区上下方，保持了操作对象与控制器的关联。
- 实时像素尺寸、可编辑宽高、八个缩放手柄和移动能力，提供了真正有用的精确控制。
- Esc、Enter、Delete 与持久化输出偏好说明产品已经考虑高频截屏工作流。

## Priority Issues

### [P1] 标注模式会困住用户

选择画笔、直线、箭头、数字或字母后，没有“选择/指针”按钮恢复 `.none`。选区内点击会优先创建标注，移动选区和调整选区因此变得不可预测。

**Fix**：增加默认的“选择”工具；Esc 优先退出当前工具，再取消截图；让手柄在任何工具状态下都可用。建议命令：`$impeccable harden`。

### [P1] 自绘控件失去了 macOS 原生交互与辅助功能

形状、工具、颜色和输出全由 `NSAttributedString`、`NSBezierPath` 与手写命中测试完成，没有按钮角色、辅助标签、焦点顺序或键盘导航；两个真实文本框还关闭了焦点环。

**Fix**：优先改为 `NSButton`、`NSSegmentedControl`、可访问色板和 `NSTextField` 的原生组合；若保留自绘，必须实现完整 `NSAccessibility` 子元素、选中态与键盘焦点。建议命令：`$impeccable audit`。

### [P1] 默认动作、预览与实际结果互相矛盾

操作条会高亮记忆的默认输出，但 Enter 始终执行复制；进行中的标注固定显示红色；箭头预览只画直线，导出才出现箭头头部。

**Fix**：让 Enter 执行 `defaultOutput`；复用同一套预览/导出绘制逻辑；进行中标注使用当前颜色。建议命令：`$impeccable harden`。

### [P1] 标注错误缺少恢复路径

只有数字和字母标签可被选中或删除，画笔、直线与箭头不能选择、删除、撤销或重做。一笔画错就只能重新截图。

**Fix**：所有标注操作统一进入撤销栈，支持 Cmd-Z/Cmd-Shift-Z；所有类型都可选择，Delete 删除当前选中标注。建议命令：`$impeccable harden`。

### [P2] 主次层级过平，操作条也无法处理边缘空间

3 个形状、5 个工具、5 个颜色、2 个尺寸输入和 4 个输出动作同时出现；四个输出按钮等宽，默认动作并不突出。固定 304×128 布局在大选区或窄屏空间里会覆盖内容，黑色色点在黑底上也几乎不可见。

**Fix**：把记忆的输出变成唯一主按钮，其他输出放进相邻菜单；标注颜色仅在进入标注模式后显示；增加四象限放置、紧凑模式与避让逻辑；为黑色色点加常驻描边。建议命令：`$impeccable distill` 与 `$impeccable adapt`。

## Persona Red Flags

- **Alex（高频用户）**：Enter 不遵循已记忆输出；工具和其他输出没有快捷键；无撤销使一次误操作就要重来。
- **Jordan（首次用户）**：固定选区后直接面对近 20 个选择；高亮的输出看起来像模式而不是立即执行按钮；“下载”不符合 macOS 保存语义。
- **Sam（依赖辅助功能）**：几乎全部控件都不在辅助功能树中；颜色命中区只有约 16.8×32 pt，可见色点仅 14×14 pt；文本框没有可见焦点环。

## Minor Observations

- 光标附近的尺寸浮层与操作条里的宽高输入重复呈现同一信息。
- 无效或超出屏幕的尺寸会静默恢复或裁切，没有解释。
- 输出在 mouse-down 时进入待执行状态，mouse-up 不检查指针是否仍在原按钮内。
- 字母标注超过 Z 后会进入标点符号，而不是 AA、AB。
- README 同时说标注已支持、又说标注仍在计划中，产品状态表述矛盾。

## Questions to Consider

- 标注究竟应是截图流程的默认组成，还是用户显式进入的第二阶段？
- 如果 Cutter 已记住输出偏好，是否应该只显示一个与 Enter 一致的主按钮，把其他输出藏进菜单？
- 三个常驻形状选择，是否比撤销、选择工具和明确完成动作更值得占据第一层级？
