# Cutter 架构

## 目标与边界

Cutter 当前是原生 macOS 菜单栏应用。系统集成继续由 AppKit、ScreenCaptureKit 和 CoreGraphics 负责；未来可复用的图像语义与平台外壳保持分离。

```text
全局快捷键 / 菜单栏命令
          |
      AppDelegate
          |
 ScreenCaptureKitBackend  -- 屏幕权限、主显示器、冻结画面
          |
 RegionSelectionController -- 全屏无边框窗口与会话生命周期
          |
 RegionSelectionView       -- 选区、尺寸、预设、标注、撤销重做
          |
   +------+-----------------------+
   |                              |
ImageClipboard               ImageFileWriter
   |                              |
系统剪贴板                  ~/Pictures/Cutter
```

应用没有本地 HTTP 服务，也没有账户、云同步或网络上传路径。

## 模块

### `Application`

`AppDelegate` 负责：

- 创建菜单栏图标和菜单。
- 注册 `⌥⌘2` 全局快捷键。
- 调度立即或延时截图；倒计时期间再次触发快捷键会取消任务。
- 串联捕获、选区和输出流程。
- 持久化上次使用的输出动作。
- 根据复制、存储或复制并存储显示准确的完成反馈。

### `Capture`

- `ScreenCaptureBackend`：屏幕捕获抽象。
- `ScreenCaptureKitBackend`：冻结主显示器图像、枚举普通窗口，并通过 `desktopIndependentWindow` 过滤器直接捕获选定窗口。
- `CaptureWorkspace`：一次捕获准备阶段产生的主显示器图像和按前后顺序排列的窗口元数据。
- `CaptureSettings`：鼠标指针、默认输出和存储目录。
- `CaptureCountdownController`：位于主显示器中央的非激活倒计时 HUD；捕获前和取消后负责隐藏窗口。
- `CaptureSizePreset` / `CaptureSizePresetStore`：内置尺寸、自定义尺寸校验、去重和 `UserDefaults` 持久化。
- `ImageFileWriter`：PNG 本机输出。

### `Selection`

`RegionSelectionController` 创建一个位于 `screenSaver` 层级的无边框 AppKit 窗口，持有一次截图选择会话，并通过 continuation 返回最终图像和输出动作。

`RegionSelectionView` 负责：

- 矩形、正方形、圆形和邮票打孔选区。
- 窗口悬停命中、点击锁定，以及 Space/拖动切换自由区域。
- 八个缩放手柄、选区移动和屏幕边界限制。
- 精确像素输入、输入状态反馈和尺寸预设菜单。
- 选择、画笔、直线、箭头、数字、字母、矩形框、文本、高亮、马赛克和模糊标注。
- 五个快捷标注色，以及通过 `NSColorWell` / `NSColorPanel` 选择的任意系统颜色。
- 标注选择、移动、删除、撤销和重做。
- 选中标注后的上下文编辑：线宽、字号、复制、层级、多选和六种对齐方式。
- 操作条布局、避让和辅助功能语义。
- 将选区和标注渲染成最终 `CGImage`。

### `Permissions`、`Clipboard` 与 `Shortcuts`

- `ScreenCapturePermission`：查询和申请屏幕录制权限。
- `ImageClipboard`：将图像发布到 macOS 剪贴板。
- `GlobalShortcutService`：注册和释放全局快捷键。

## 坐标空间

捕获图像使用物理像素；AppKit 选区窗口使用界面点数。

```text
AppKit 选区点数
  -- xScale / yScale --> 捕获图像像素矩形
  -- 裁剪 -----------> 选区 CGImage
  -- 标注映射 -------> 裁剪图像像素坐标
```

缩放比例来自捕获图像像素尺寸与覆盖窗口尺寸之比。尺寸输入和预设都以最终截图像素为单位。

标注在一次选择会话中使用覆盖窗口坐标保存。移动选区时，当前标注及撤销/重做快照应用同一实际位移，因此标注相对选区的位置保持不变；输出时再映射到裁剪图像像素。文本通过临时原生 `NSTextField` 输入，提交后成为可移动、可删除的文本标注。每个标注同时保存线宽和字号，多选编辑会通过同一撤销栈更新选中对象。

隐私标注中的马赛克和模糊使用标注创建时生成的独立随机种子，生成与原始画面无关的随机内容；马赛克使用随机色块，模糊先生成随机低频纹理再对随机纹理做 Core Image 模糊。预览、移动、撤销和导出复用同一随机种子，因此效果稳定且不会把原始像素送入隐私滤镜。

智能窗口选择只接收完整位于主显示器、`windowLayer == 0`、尺寸达到最低阈值且不属于 Cutter 进程的窗口。ScreenCaptureKit 窗口 frame 使用全局显示器坐标；`RegionSelectionView` 将它转换为覆盖窗口的左下原点坐标。单击窗口后，完成动作通过注入的异步窗口捕获闭包取得独立窗口图像，再复用现有标注渲染器；一旦用户移动、缩放或输入新尺寸，窗口来源失效并退回冻结屏幕区域裁剪。

自定义颜色通过 expanded `NSColorWell` 接入 AppKit 共享 `NSColorPanel`。选择会话创建时，颜色面板临时提升到截图遮罩之上；会话完成或取消时关闭面板并恢复原窗口层级。标注对象保存标准 RGB `NSColor`，因此快捷色和任意自定义色共享同一预览、撤销和导出路径。

邮票模式保持独立宽高。预览阶段沿选区四边绘制并填充等距孔位；输出阶段在背景和标注全部渲染完成后使用 `.clear` 混合模式清除边缘圆孔，画布边界自然截取圆孔外侧，形成透明半圆打孔。极小选区会跳过孔位生成，避免孔洞吞掉全部内容。

## 尺寸预设

内置预设是代码常量，不写入用户偏好。自定义预设使用 `capture.customSizePresets` 保存为 JSON，并遵循以下约束：

- 宽高范围为 2–32768 像素。
- 不保存内置尺寸的重复项。
- 不保存重复的自定义尺寸。
- 保持用户添加顺序。
- 无法解码或不合法的数据不会进入菜单。

应用非正方形预设时会切换到矩形选区。选区尺寸超出屏幕时，`fittedSelectionRect` 会先限制尺寸，再移动原点使选区保持在屏幕范围内；界面随后显示实际可用尺寸。

## 本机持久化

`UserDefaults` 当前保存：

- `capture.includeCursor`
- `capture.output`
- `capture.downloadDirectory`
- `capture.customSizePresets`
- `capture.delaySeconds`

这些设置只描述本机截图行为，不包含截图图像本身。

## 构建路径

仓库保留两条构建路径：

1. `swift build`：由 SwiftPM 自动发现 `Sources/CutterMac` 下的源文件。
2. `scripts/build-dev.sh`：直接调用 `swiftc`，源文件列表必须显式维护。

`scripts/build-app.sh` 先调用 `build-dev.sh`，再把可执行文件放入 `.build/Cutter.app` 并使用本机开发身份签名。新增 Swift 文件时，应同时验证 SwiftPM、直接编译和 `.app` 打包三条路径。

## 未来可复用核心

长期方向仍是把图像变换、标注文档、撤销重做、编码策略和滚动拼接迁入可复用核心，macOS 外壳只保留屏幕权限、显示器发现、坐标转换、快捷键、剪贴板和窗口管理。

在核心边界真正建立前，不创建临时的第二套标注或渲染模型；当前 Swift 实现保持单一数据流，避免未来迁移前先产生内部重复架构。

## 当前未实现

- 窗口截图和全屏截图。
- 多显示器同时选择。
- 贴图置顶。
- 滚动截图。
- 屏幕录制和视频编辑。
