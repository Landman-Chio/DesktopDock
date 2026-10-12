# DesktopDock · 桌面应用收纳容器

一个常驻桌面的**高斯玻璃**面板：固定 4 列 × 4 行图标，第 5 行是搜索栏，更多应用用滚轮滑出来。

```
┌──────────────────────────────┐
│ 应用容器 · 16      ✎  ◡  ⏻  │  ← 编辑 / 隐藏 / 退出（图标按钮）
│  [◧]  [▦]  [◈]  [▣]         │
│  [◎]  [◍]  [◒]  [◐]         │  ← 4×4，滚轮上下滑动看更多
│  [◔]  [◕]  [◑]  [◖]         │
│  [◗]  [◘]  [◙]  [◚]         │
│  🔍 输入名称筛选…             │  ← 搜索栏
│   滚轮浏览 · 点击启动 · 拖动移动│
└──────────────────────────────┘
```

## 快速开始

双击 **`启动容器.vbs`**（无控制台窗口、无 UAC 弹窗）。

## 操作说明

| 操作 | 效果 |
|---|---|
| 点击图标 | 启动该程序，面板自动回到未筛选状态 |
| 滚轮 | 上下滑动应用区（16 个放不下时使用） |
| 搜索框输入 | 实时筛选；**搜索范围是全部 70 个应用**，不限于已勾选的 |
| 搜索框按 Enter | 直接启动第一个结果 |
| 搜索框按 Esc / 点 ✕ | 清空搜索 |
| 拖动面板空白处或顶部按钮左侧区域 | 移动位置并自动保存 |
| **Ctrl + Alt + D** | 全局快捷键，隐藏 / 唤出容器 |
| 右键面板 | 编辑 / 隐藏 / 退出 |

## 三个按钮（macOS 交通灯样式）

面板**没有标题栏**，右上角只有三个小圆点按钮（静止是圆点、悬停放大并显示符号），从左到右：

| 图标 | 功能 |
|---|---|
| ✎ 铅笔 | 打开编辑器：勾选应用 + 调整顺序 |
| ◡ 闭眼 | 隐藏容器（移出屏幕，Ctrl+Alt+D 可唤回） |
| ⏻ 电源 | 退出 DesktopDock |

## 选应用与调整顺序

点 ✎ 打开编辑器（**非模态**，容器仍可操作）：

- 左侧「当前显示顺序」：已选应用列表，每行有 ▲ ▼ ✕ 三个按钮，可**上移 / 下移 / 移除**
- 右侧「全部应用」：勾选即加入容器，**加入顺序即显示顺序**
- 顶部搜索框可过滤
- 「全选 / 全不选 / 保存 / 取消」

应用来自用户与全局开始菜单、桌面与公共桌面的快捷方式，自动跳过卸载程序、帮助文档、网址书签等。

## 配置文件

`config.json` 由程序自动维护：

| 字段 | 含义 | 默认 |
|---|---|---|
| `x` / `y` | 容器位置（逻辑坐标） | 右下角 |
| `width` / `height` | 面板尺寸 | 216 × 242 |
| `cols` / `rows` | 每行几列、可见几行 | 4 / 4 |
| `itemW` / `itemH` | 每个图标格尺寸 | 53 / 40 |
| `pinned` | 已选应用名列表（顺序即显示顺序） | `[]` |
| `dockMode` | `normal`（顶层窗口，会被其他窗口盖住）/ `desktop`（嵌入桌面图标层） | `normal` |
| `theme` | `auto`（跟随 Windows 深浅模式）/ `dark` / `light` | `auto` |
| `glass` | `capture`（抓屏高斯模糊）/ `blur` `acrylic`（走 DWM，部分机器无效）/ `none` | `capture` |
| `blurRadius` | 高斯模糊半径，**越大越糊越明显** | `22` |
| `topmost` | 是否常驻最前 | `false` |
| `selfcheck` | 启动 3 秒后把面板自身渲染成 `selfcheck-internal.png`，用于排查渲染问题 | `false` |

### 让它更"玻璃"一点

两个旋钮：

- **`blurRadius`**（默认 22）：模糊强度。想要更明显的磨砂感就加大到 30~40。
- **面板透明度**：在代码顶部的 `$Script:Palette` 里改 `panel` 的 alpha。深色 `#B3101418`、浅色 `#B3FFFFFF`，
  把 `B3`（70%）降到 `80`（50%）会更透。

### 深浅模式跟随

`theme: "auto"` 时每 3 秒检查一次 Windows 的「应用界面」深浅设置，
**变化就立刻换肤，不需要重启**。已验证：系统切深色后 12 秒内跟随，切回浅色 6 秒内跟上。

它读的是 `HKCU\SOFTWARE\Microsoft\Windows\CurrentVersion\Themes\Personalize\AppsUseLightTheme`，
跟 [ThemeAutoSwitch](https://github.com/Landman-Chio/ThemeAutoSwitch) 写的是同一处 —— 所以两个工具可以配合使用。

### 窗口层级：只停留在桌面

| `dockMode` | 行为 | 可靠性 |
|---|---|---|
| `normal`（默认） | 普通顶层窗口、**不置顶**。点一下或用 `Ctrl+Alt+D` 唤到最前；被其他窗口盖住 | 所有系统都能渲染 |
| `desktop` | 嵌入桌面图标层，**其他窗口不会盖住它**，真正做到"只在桌面" | ⚠️ 依赖桌面层级结构，部分机器不渲染 |

先用探针自查你的机器适不适合 `desktop`：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\DesktopDock.ps1 -Action probe
```

它会枚举桌面窗口层级并给出结论。**如果提示"桌面层级结构异常"，就保持 `normal`。**

> ⚠️ 改 `height` 时要保证 **26(按钮) + itemH×rows + 34(搜索) + 22(提示) ≤ height**，
> 否则后面的区域会被挤出窗口导致点不到。
## 开机自启

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\autostart.ps1 -Action install
powershell -NoProfile -ExecutionPolicy Bypass -File .\autostart.ps1 -Action status
powershell -NoProfile -ExecutionPolicy Bypass -File .\autostart.ps1 -Action remove
```

只在「启动」文件夹放一个快捷方式，不需要管理员权限。

## 卸载

删掉整个 `DesktopDock` 文件夹即可。若启用了开机自启，先跑一次 `-Action remove`。

本工具**不写注册表、不装服务、不加驱动、不改系统设置**，纯用户态运行。

## 实现说明（改代码必读）

| 文件 | 作用 |
|---|---|
| `DesktopDock.ps1` | 主程序：WPF 界面、应用扫描、搜索、编辑器、拖动、快捷键 |
| `native.cs` | Win32 互操作：高斯玻璃、z 序、圆角、键盘钩子 |
| `启动容器.vbs` | 静默启动器 |
| `autostart.ps1` | 开机自启开关 |
| `desktopdock.log` | 运行日志 |

### 玻璃效果怎么实现的（重要）

**没有用 DWM。** 试过 `SetWindowCompositionAttribute` 的 `ACCENT_ENABLE_ACRYLICBLURBEHIND` 和
`ACCENT_ENABLE_BLURBEHIND`：**两个都返回成功，但屏幕上什么都不画**（像素采样证实面板内是纯黑，
和无玻璃时一模一样）。而用大不透明度白色染色时，它会输出**整块纯白** —— 这就是最初你看到的白屏。

现在用的是自实现方案，不依赖任何系统 API：

1. 用 `Graphics.CopyFromScreen` 抓取面板背后的桌面区域（比窗口大一圈，避免模糊后边缘发暗）
2. 用 `DrawingVisual` 把抓到的图按窗口位置对齐画到窗口尺寸的画布上
3. 套 WPF `BlurEffect`（`Gaussian`、半径 18）
4. 作为最底层 `Image`，上面压一层随主题变化的面板色，再上面才是内容

副作用是**背后的画面不会实时更新** —— 拖动窗口时会重新抓取，但如果有窗口在容器下面移动，
玻璃里的倒影不会跟着变。对桌面挂件来说可以接受。

### 踩过的坑（都是实测确认的）

1. **桌面 WorkerW 嵌入不可行**。试过把窗口 `SetParent` 到桌面图层（那样 Win+D 不会隐藏它），
   `SetParent` 成功、`SetWindowPos` 返回 True、窗口矩形也正确，但在 Windows 11 26100 上
   **完全不渲染** —— 肉眼和截图都证实了。改用「顶层窗口 + `WS_EX_TOPMOST`」。

2. **不能用 `WS_EX_NOACTIVATE`**。它会占住「不抢焦点」，但代价是窗口**永远拿不到键盘输入**，
   搜索框就没法用。现在只用 `WS_EX_TOOLWINDOW`（不进任务栏/Alt+Tab）。

3. **`SetWindowPos` 的 `hWndInsertAfter` 不能传 `IntPtr.Zero`**（那等于 `HWND_TOP`），
   会**摘掉 `WS_EX_TOPMOST`**，窗口就被别的窗口盖住了。要用 `HWND_TOPMOST`（见 `MoveKeepTop`）。

4. **别在分层窗口上改 z 序**。亚克力模糊会让窗口带 `WS_EX_LAYERED`，此时再调
   `SetWindowPos` 改 z 序会让**进程直接异常退出**（不写任何日志）。隐藏/唤出因此改成
   「取消置顶 + 移到屏幕外」，不用 `Window.Hide()`（同样会崩）。

5. **鼠标「抬起」消息收不到**。分层窗口下 WPF 的隐式鼠标捕获失效，`MouseLeftButtonUp`
   连预览事件都不触发。所以点击判定改成：按下瞬间入队，180ms 后校验光标位移，
   超过 4 像素就当拖动撤销（见 `$Script:QueueClick`）。

6. **`$Script:DragMoved` 必须在控件按下时重置**。窗口级按下处理器遇到 TextBox 会提前 return，
   标志会一直停在 `true`，导致之后所有点击都被误判成拖动而失效。

7. **`UniformGrid` 必须 `VerticalAlignment='Top'`**。否则结果少时整个网格会被垂直居中，
   图标位置随结果数量漂移，点击位置对不上。

8. **函数返回数组要用逗号**：`return ,$list`。否则单元素数组会被 PowerShell 拆成标量，
   调用方拿到的不是数组，`$list.Count` 会变成空值。

9. **`.ps1` 必须存成 UTF-8 with BOM**，否则 PowerShell 5.1 在中文系统上按 ANSI 读，
   中文字符会吃掉字符串引号导致解析失败。而且**脚本运行中无法重写自身**（文件被占用），
   改完要么先退出程序，要么用另一个进程写。

10. **150% 缩放下坐标要当心**。进程声明 PerMonitorV2 后，WPF 的 `ActualWidth` 是 DIP、
   `GetWindowRect` 是物理像素，两者相差 1.5 倍；而 DPI 不感知的进程调 `SetCursorPos`
   时系统还会再缩放一次。`Apply-Position` 里统一用 `Get-Scale` 换算。
