<#
    DesktopDock - 桌面应用收纳容器
    ------------------------------------------------------------
    固定尺寸的玻璃面板：4 列 × 4 行应用图标 + 第 5 行搜索栏。
    滚动滚轮浏览更多应用，点击图标启动，拖动面板移动位置。
    纯用户态工具：不装服务、不加驱动、不动系统设置。删掉文件夹即完全卸载。
#>

$ErrorActionPreference = 'Stop'

#region ============ 基础与配置 ============
$Script:AppDir  = Split-Path -Parent $MyInvocation.MyCommand.Path
$Script:GlassBlur = 18   # 高斯模糊半径(物理像素)
$Script:GlassUpdates = 0
$Script:BasePath = $Script:AppDir   # 统一以此为准: 后面有个 $root 控件变量, 同名会互相覆盖
$Script:CfgPath = Join-Path $Script:BasePath 'config.json'
$Script:LogPath = Join-Path $Script:BasePath 'desktopdock.log'
$Script:CsPath  = Join-Path $Script:BasePath 'native.cs'

function Write-Log([string]$msg) {
    try { Add-Content -Path $Script:LogPath -Value ("[{0}] {1}" -f (Get-Date -Format 'HH:mm:ss'), $msg) -Encoding UTF8 } catch {}
}

$Script:Defaults = [ordered]@{
    x      = -9999
    y      = -9999
    width  = 416
    height = 500
    cols   = 4
    rows   = 4
    itemW  = 96
    itemH  = 92
    pinned = @()
    glass  = 'capture'   # capture=抓屏高斯模糊 / blur|acrylic=DWM(本机无效, 保留备用) / none=关闭
    tint   = '#00000000'
    winBg  = '#CC101218'
    topmost = $true
    selfcheck = $false
}

function Get-Config {
    $raw = $null
    if (Test-Path $Script:CfgPath) {
        try { $raw = Get-Content -Raw -Encoding UTF8 $Script:CfgPath | ConvertFrom-Json } catch { $raw = $null }
    }
    $cfg = [ordered]@{}
    foreach ($k in $Script:Defaults.Keys) {
        if ($raw -and ($raw.PSObject.Properties.Name -contains $k)) { $cfg[$k] = $raw.$k } else { $cfg[$k] = $Script:Defaults[$k] }
    }
    return $cfg
}
function Ensure-Config {
    # 首次运行自动生成配置(参照 config.example.json 的字段), 方便用户看到可改什么
    if (Test-Path $Script:CfgPath) { return }
    try {
        ($Script:Defaults | ConvertTo-Json) | Set-Content -Path $Script:CfgPath -Encoding UTF8
        Write-Log "已生成默认配置: $($Script:CfgPath)"
    } catch { Write-Log ("生成默认配置失败: {0}" -f $_.Exception.Message) }
}
function Save-Config($cfg) {
    try {
        ($cfg | ConvertTo-Json -Depth 6) | Set-Content -Path $Script:CfgPath -Encoding UTF8
        Write-Log '配置已保存'
    } catch { Write-Log "配置保存失败: $($_.Exception.Message)" }
}
function New-RowDef([string]$mode, [double]$v = 0) {
    $rd = New-Object System.Windows.Controls.RowDefinition
    if ($mode -eq 'auto') { $rd.Height = New-Object System.Windows.GridLength(1, [System.Windows.GridUnitType]::Auto) }
    elseif ($mode -eq 'star') { $rd.Height = New-Object System.Windows.GridLength(1, [System.Windows.GridUnitType]::Star) }
    else { $rd.Height = New-Object System.Windows.GridLength($v, [System.Windows.GridUnitType]::Pixel) }
    return $rd
}
#endregion

#region ============ 原生互操作 ============
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Xaml, System.Drawing, System.Windows.Forms | Out-Null
if (-not (Test-Path $Script:CsPath)) { throw "缺少 native.cs: $($Script:CsPath)" }
Add-Type -TypeDefinition (Get-Content -Raw -Encoding UTF8 $Script:CsPath) -Language CSharp | Out-Null

# 必须声明 DPI 感知, 否则 WPF 坐标会被系统再缩放一次, 定位会漂移
try {
    Add-Type -Namespace DshDpi -Name Ctx -MemberDefinition @'
[DllImport("user32.dll")] public static extern bool SetProcessDpiAwarenessContext(IntPtr value);
[DllImport("shcore.dll")] public static extern int SetProcessDpiAwareness(int value);
'@ -ErrorAction Stop
    if (-not [DshDpi.Ctx]::SetProcessDpiAwarenessContext([IntPtr](-4))) { [void][DshDpi.Ctx]::SetProcessDpiAwareness(2) }
    Write-Log 'DPI 感知: PerMonitorV2'
} catch { Write-Log "DPI 设置失败: $($_.Exception.Message)" }
#endregion

#region ============ 应用扫描 ============
$Script:Apps = @()

function Get-ShortcutInfo([string]$lnkPath) {
    $sh = New-Object -ComObject WScript.Shell
    try {
        $l = $sh.CreateShortcut($lnkPath)
        return [pscustomobject]@{ Target = $l.TargetPath; Args = $l.Arguments; Icon = $l.IconLocation }
    } catch { return $null }
    finally { if ($sh) { [void][Runtime.InteropServices.Marshal]::ReleaseComObject($sh) } }
}

function Get-AppIconPath([string]$iconLoc, [string]$target) {
    if ($iconLoc) {
        $p = ($iconLoc -split ',')[0].Trim().Trim('"')
        if ($p -and (Test-Path $p)) { return $p }
    }
    if ($target -and (Test-Path $target)) {
        if ([IO.Path]::GetExtension($target).ToLower() -in '.exe', '.dll', '.ico') { return $target }
    }
    return $null
}

function Invoke-ScanApps {
    $dirs = @(
        (Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs'),
        (Join-Path $env:ProgramData 'Microsoft\Windows\Start Menu\Programs'),
        ([Environment]::GetFolderPath('Desktop')),
        (Join-Path $env:PUBLIC 'Desktop')
    ) | Where-Object { $_ -and (Test-Path $_) } | Select-Object -Unique

    $skip = 'uninstall|卸载|remove|readme|说明|help|帮助|website|官网|repair|修复|documentation|更新日志|changelog|release note|license|许可|网站|grabber help|idm help'
    $map = @{}
    $i = 0
    foreach ($d in $dirs) {
        foreach ($f in (Get-ChildItem -Path $d -Recurse -File -Filter '*.lnk' -ErrorAction SilentlyContinue)) {
            if ($f.BaseName -match $skip) { continue }
            $info = Get-ShortcutInfo $f.FullName
            if (-not $info) { continue }
            if ($info.Target -match 'msiexec|unins\d*\.exe') { continue }
            $name = $f.BaseName.Trim()
            if (-not $name) { continue }
            $key = $name.ToLower()
            if ($map.ContainsKey($key)) { continue }
            $map[$key] = [pscustomobject]@{
                id       = 'app{0:d3}' -f $i
                name     = $name
                path     = $f.FullName
                target   = $info.Target
                iconPath = (Get-AppIconPath $info.Icon $info.Target)
                search   = ($name + ' ' + [IO.Path]::GetFileNameWithoutExtension($info.Target)).ToLower()
            }
            $i++
        }
    }
    $Script:Apps = @($map.Values | Sort-Object name)
    Write-Log ("扫描到 {0} 个应用" -f $Script:Apps.Count)
}
#endregion

#region ============ 图标与启动 ============
$Script:IconCache = @{}
function Get-Icon([string]$path, [int]$size) {
    if (-not $path) { return $null }
    $key = "$path|$size"
    if ($Script:IconCache.ContainsKey($key)) { return $Script:IconCache[$key] }
    $src = $null
    try {
        if (Test-Path $path) {
            if ([IO.Path]::GetExtension($path).ToLower() -eq '.ico') {
                $ico = New-Object System.Drawing.Icon($path, $size, $size)
            } else {
                $ico = [System.Drawing.Icon]::ExtractAssociatedIcon($path)
            }
            if ($ico) {
                $src = [System.Windows.Interop.Imaging]::CreateBitmapSourceFromHIcon(
                    $ico.Handle, [System.Windows.Int32Rect]::Empty,
                    [System.Windows.Media.Imaging.BitmapSizeOptions]::FromEmptyOptions())
                $ico.Dispose()
                $src.Freeze()
            }
        }
    } catch { $src = $null }
    $Script:IconCache[$key] = $src
    return $src
}

function Start-App($app) {
    try {
        Start-Process -FilePath $app.path -ErrorAction Stop
        Write-Log ("已启动: {0}" -f $app.name)
    } catch {
        Write-Log ("首个方式失败: {0}" -f $_.Exception.Message)
        try {
            if ($app.target -and (Test-Path $app.target)) {
                Start-Process -FilePath $app.target -ErrorAction Stop
                Write-Log ("已启动(直接目标): {0}" -f $app.name)
            } else {
                Write-Log 'no target'
            }
        } catch { Write-Log ("启动失败: {0}" -f $_.Exception.Message) }
    }
}

function New-Icon([string]$kind, [double]$size, $brush) {
    $geo = switch ($kind) {
        'pencil' { 'M2,14 L3.2,10.6 L11,2.8 L14.2,6 L6.4,13.8 Z M12,1.8 L15.2,5 L16.6,3.6 A1.2,1.2 0 0 0 16.6,1.9 L15.1,0.4 A1.2,1.2 0 0 0 13.4,0.4 Z' }
        'eyeoff' { 'M1,9 C3.2,5.4 6,3.6 9,3.6 C12,3.6 14.8,5.4 17,9 C14.8,12.6 12,14.4 9,14.4 C6,14.4 3.2,12.6 1,9 Z M2.2,2.2 L15.8,15.8' }
        'power'  { 'M9,1.4 L9,8.4 M15.2,4.2 A7.4,7.4 0 1 1 2.8,4.2' }
        'search' { 'M7.6,1.6 A6,6 0 1 1 7.59,1.6 Z M12,12 L15.6,15.6' }
        'close'  { 'M3,3 L14,14 M14,3 L3,14' }
        'up'     { 'M8.5,2 L14.5,9 L2.5,9 Z' }
        'down'   { 'M8.5,15 L2.5,8 L14.5,8 Z' }
        default  { 'M2,2 L15,2 L15,15 L2,15 Z' }
    }
    $cv = New-Object System.Windows.Controls.Canvas
    $cv.Width = $size; $cv.Height = $size
    $p = New-Object System.Windows.Shapes.Path
    $p.Data = [System.Windows.Media.Geometry]::Parse($geo)
    if ($kind -in @('eyeoff', 'power', 'search', 'close')) {
        $p.Stroke = $brush
        $p.StrokeThickness = 1.7
        $p.StrokeStartLineCap = 'Round'
        $p.StrokeEndLineCap = 'Round'
        $p.StrokeLineJoin = 'Round'
    } else {
        $p.Fill = $brush
    }
    $sx = $size / 17.0
    $p.RenderTransform = New-Object System.Windows.Media.ScaleTransform($sx, $sx)
    $cv.Children.Add($p) | Out-Null
    return $cv
}

# 用 Border 而不是 Button: 带 WS_EX_NOACTIVATE 的窗口里 Button 的 Click 收不到。
# 又因为亚克力模糊让窗口变成分层窗口, 鼠标"抬起"消息根本不会送到 WPF(连预览事件都没有),
# 所以按下瞬间就触发, 再挂 180ms 校验: 若期间发生了拖动则撤销。
function New-IconButton([string]$kind, [string]$tip, $action) {
    $bd = New-Object System.Windows.Controls.Border
    $bd.Width = 30; $bd.Height = 30
    $bd.CornerRadius = New-Object System.Windows.CornerRadius 8
    $bd.Background = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.Color]::FromArgb(1, 255, 255, 255))
    $bd.ToolTip = $tip
    $bd.Cursor = 'Hand'
    $bd.Margin = New-Object System.Windows.Thickness 2, 0, 2, 0
    $bd.Child = (New-Icon $kind 15 $brushText)
    $bd.add_MouseEnter({ $this.Background = $brushHover })
    $bd.add_MouseLeave({ $this.Background = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.Color]::FromArgb(1, 255, 255, 255)) })
    # 不用闭包捕获: 把动作挂到控件属性上, 处理器里用 $this 取(闭包在此调用路径下不可靠)
    $bd | Add-Member -NotePropertyName DockAction -NotePropertyValue $action -Force
    $bd | Add-Member -NotePropertyName DockTag -NotePropertyValue $kind -Force
    $bd.add_MouseLeftButtonDown({
        $Script:DragMoved = $false
        $act = $this.DockAction
        if ($act) { & $Script:QueueClick $act $this.DockTag }
    })
    return $bd
}
#endregion

#region ============ 界面 ============
Write-Log '=== DesktopDock 启动 ==='
Ensure-Config
$cfg = Get-Config
Invoke-ScanApps

# 玻璃染色 #AARRGGBB -> DWM 需要的 0xAABBGGRR
# 注意: DWM 的 GradientColor 给成高不透明度的白色会直接输出纯白, 把整个窗口盖住,
# 所以这里只让玻璃负责"模糊", 色调交给窗口自身背景(winBg), 染色默认全透明。
$tintArgb = $cfg.tint
if ($tintArgb -notmatch '^#([0-9A-Fa-f]{8})$') { $tintArgb = '#00000000' }
$ta = [Convert]::ToInt32($tintArgb.Substring(1, 2), 16)
$tr = [Convert]::ToInt32($tintArgb.Substring(3, 2), 16)
$tg = [Convert]::ToInt32($tintArgb.Substring(5, 2), 16)
$tb = [Convert]::ToInt32($tintArgb.Substring(7, 2), 16)
$tintAbgr = [int](($ta -shl 24) -bor ($tb -shl 16) -bor ($tg -shl 8) -bor $tr)

# 窗口自身背景(决定玻璃色调与透明度)
$winBgArgb = $cfg.winBg
if ($winBgArgb -notmatch '^#([0-9A-Fa-f]{8})$') { $winBgArgb = '#CC101218' }
$wa2 = [Convert]::ToInt32($winBgArgb.Substring(1, 2), 16)
$wr2 = [Convert]::ToInt32($winBgArgb.Substring(3, 2), 16)
$wg2 = [Convert]::ToInt32($winBgArgb.Substring(5, 2), 16)
$wb2 = [Convert]::ToInt32($winBgArgb.Substring(7, 2), 16)

$brushPanel = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.Color]::FromArgb($wa2, $wr2, $wg2, $wb2))
$brushEdge  = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.Color]::FromArgb(78, 255, 255, 255))
$brushHover = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.Color]::FromArgb(52, 255, 255, 255))
$brushText  = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.Color]::FromArgb(255, 248, 250, 255))
$brushDim   = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.Color]::FromArgb(215, 228, 233, 245))
$brushField = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.Color]::FromArgb(64, 0, 0, 0))

$win = New-Object System.Windows.Window
$win.WindowStyle = 'None'
$win.ResizeMode = 'NoResize'
$win.ShowInTaskbar = $false
$win.AllowsTransparency = $false          # 玻璃模糊要求非分层窗口
$win.Background = $brushPanel
$win.WindowStartupLocation = 'Manual'
$win.Width = $cfg.width
$win.Height = $cfg.height
$win.FontFamily = 'Microsoft YaHei UI'
$win.Cursor = 'Arrow'
$win.Topmost = [bool]$cfg.topmost    # 常驻最前, 否则会被别的窗口盖住

$rootBorder = New-Object System.Windows.Controls.Border
$rootBorder.Background = $brushPanel
$rootBorder.BorderBrush = $brushEdge
$rootBorder.BorderThickness = New-Object System.Windows.Thickness 1
$win.Content = $rootBorder

# 玻璃背景层: 里面放"抓取面板背后桌面 + 高斯模糊"的图, 上面压一层染色, 再上面才是内容。
# 不用 DWM 的 SetWindowCompositionAttribute —— 实测在目标机器上它返回成功但不画任何东西。
$bgHost = New-Object System.Windows.Controls.Grid
$rootBorder.Child = $bgHost

$bgImage = New-Object System.Windows.Controls.Image
$bgImage.Stretch = 'Fill'
$bgImage.HorizontalAlignment = 'Stretch'
$bgImage.VerticalAlignment = 'Stretch'
$bgHost.Children.Add($bgImage) | Out-Null

$bgTint = New-Object System.Windows.Controls.Border
$bgTint.Background = $brushPanel
$bgTint.HorizontalAlignment = 'Stretch'
$bgTint.VerticalAlignment = 'Stretch'
$bgHost.Children.Add($bgTint) | Out-Null

$root = New-Object System.Windows.Controls.Grid
$root.Background = [System.Windows.Media.Brushes]::Transparent
$bgHost.Children.Add($root) | Out-Null

# 行高之和必须 <= 窗口高度, 否则后面的行会被挤出窗口(点不到)。
# 44(标题) + 4*92(图标区) + 50(搜索) + 26(底部提示) = 488, 窗口高度取 500 留余量。
$root.RowDefinitions.Add((New-RowDef 'pixel' 44)) | Out-Null
$root.RowDefinitions.Add((New-RowDef 'pixel' ($cfg.itemH * $cfg.rows))) | Out-Null
$root.RowDefinitions.Add((New-RowDef 'pixel' 50)) | Out-Null
$root.RowDefinitions.Add((New-RowDef 'pixel' 26)) | Out-Null

# ---- 标题栏 ----
$hdr = New-Object System.Windows.Controls.Border
$hdr.Background = [System.Windows.Media.Brushes]::Transparent
$hdr.Padding = New-Object System.Windows.Thickness 12, 6, 8, 2
$hdr.Cursor = 'SizeAll'
[System.Windows.Controls.Grid]::SetRow($hdr, 0)
$root.Children.Add($hdr) | Out-Null

$hGrid = New-Object System.Windows.Controls.Grid
$hdr.Child = $hGrid
$hc0 = New-Object System.Windows.Controls.ColumnDefinition
$hc1 = New-Object System.Windows.Controls.ColumnDefinition
$hc1.Width = New-Object System.Windows.GridLength(1, [System.Windows.GridUnitType]::Auto)
$hGrid.ColumnDefinitions.Add($hc0) | Out-Null
$hGrid.ColumnDefinitions.Add($hc1) | Out-Null

$title = New-Object System.Windows.Controls.TextBlock
$title.Text = '应用容器'
$title.Foreground = $brushText
$title.FontSize = 12.5
$title.FontWeight = 'SemiBold'
$title.VerticalAlignment = 'Center'
[System.Windows.Controls.Grid]::SetColumn($title, 0)
$hGrid.Children.Add($title) | Out-Null

$tools = New-Object System.Windows.Controls.StackPanel
$tools.Orientation = 'Horizontal'
$tools.VerticalAlignment = 'Center'
[System.Windows.Controls.Grid]::SetColumn($tools, 1)
$hGrid.Children.Add($tools) | Out-Null

# ---- 应用区: 4 列, 可见 4 行, 超出滚动 ----
$scroll = New-Object System.Windows.Controls.ScrollViewer
$scroll.VerticalScrollBarVisibility = 'Auto'
$scroll.HorizontalScrollBarVisibility = 'Disabled'
$scroll.CanContentScroll = $false
$scroll.Padding = New-Object System.Windows.Thickness 4, 6, 4, 0
$scroll.Background = [System.Windows.Media.Brushes]::Transparent
[System.Windows.Controls.Grid]::SetRow($scroll, 1)
$root.Children.Add($scroll) | Out-Null

$grid = New-Object System.Windows.Controls.Primitives.UniformGrid
$grid.Columns = $cfg.cols
$grid.Background = [System.Windows.Media.Brushes]::Transparent
# 必须顶端对齐: 否则结果少时整个网格会被垂直居中, 图标位置随结果数量漂移
$grid.VerticalAlignment = 'Top'
$grid.HorizontalAlignment = 'Stretch'
$scroll.Content = $grid

# ---- 搜索栏 ----
$searchWrap = New-Object System.Windows.Controls.Border
$searchWrap.Margin = New-Object System.Windows.Thickness 10, 4, 10, 2
$searchWrap.CornerRadius = New-Object System.Windows.CornerRadius 9
$searchWrap.Background = $brushField
$searchWrap.BorderBrush = $brushEdge
$searchWrap.BorderThickness = New-Object System.Windows.Thickness 0.8
[System.Windows.Controls.Grid]::SetRow($searchWrap, 2)
$root.Children.Add($searchWrap) | Out-Null

$sGrid = New-Object System.Windows.Controls.Grid
$sc0 = New-Object System.Windows.Controls.ColumnDefinition
$sc0.Width = New-Object System.Windows.GridLength(1, [System.Windows.GridUnitType]::Auto)
$sc1 = New-Object System.Windows.Controls.ColumnDefinition
$sc2 = New-Object System.Windows.Controls.ColumnDefinition
$sc2.Width = New-Object System.Windows.GridLength(1, [System.Windows.GridUnitType]::Auto)
$sGrid.ColumnDefinitions.Add($sc0) | Out-Null
$sGrid.ColumnDefinitions.Add($sc1) | Out-Null
$sGrid.ColumnDefinitions.Add($sc2) | Out-Null
$searchWrap.Child = $sGrid

$searchIcon = New-Icon 'search' 14 $brushDim
$searchIcon.VerticalAlignment = 'Center'
$searchIcon.Margin = New-Object System.Windows.Thickness 10, 0, 6, 0
[System.Windows.Controls.Grid]::SetColumn($searchIcon, 0)
$sGrid.Children.Add($searchIcon) | Out-Null

$searchBox = New-Object System.Windows.Controls.TextBox
$searchBox.Background = [System.Windows.Media.Brushes]::Transparent
$searchBox.BorderThickness = New-Object System.Windows.Thickness 0
$searchBox.Foreground = $brushText
$searchBox.CaretBrush = $brushText
$searchBox.FontSize = 12.5
$searchBox.VerticalContentAlignment = 'Center'
$searchBox.Padding = New-Object System.Windows.Thickness 0, 0, 0, 1
$searchBox.ToolTip = '输入名称筛选应用'
[System.Windows.Controls.Grid]::SetColumn($searchBox, 1)
$sGrid.Children.Add($searchBox) | Out-Null

$clearBtn = New-IconButton 'close' '清空搜索' { $searchBox.Text = '' }
$clearBtn.Width = 24; $clearBtn.Height = 24
$clearBtn.Visibility = 'Collapsed'
[System.Windows.Controls.Grid]::SetColumn($clearBtn, 2)
$sGrid.Children.Add($clearBtn) | Out-Null

# ---- 底部提示 ----
$hint = New-Object System.Windows.Controls.TextBlock
$hint.Text = '滚轮浏览 · 点击启动 · 拖动移动'
$hint.Foreground = $brushDim
$hint.FontSize = 10
$hint.Opacity = 0.7
$hint.HorizontalAlignment = 'Center'
$hint.VerticalAlignment = 'Center'
[System.Windows.Controls.Grid]::SetRow($hint, 3)
$root.Children.Add($hint) | Out-Null
#endregion

#region ============ 内容构建 ============
$Script:IsDragging = $false
$Script:DragMoved = $false
$Script:ClickStart = $null
$Script:ClickPending = $null
$Script:Hidden = $false
$Script:Hwnd = [IntPtr]::Zero

# 点击队列: 按下时先入队, 180ms 后校验。若这期间发生了拖动(位移超过 4 像素)就撤销,
# 这样既绕开"抬起消息收不到"的问题, 又不会把拖动误当成点击。
$Script:QueueClick = {
    param($action, $tag)
    if ($Script:DragMoved) { return }
    $c = [System.Windows.Forms.Cursor]::Position
    $Script:ClickPending = [pscustomobject]@{ Action = $action; Tag = $tag; X = $c.X; Y = $c.Y; Fired = $false }
    $Script:ClickTimer.Stop()
    $Script:ClickTimer.Start()
}

$Script:ClickTimer = New-Object System.Windows.Threading.DispatcherTimer
$Script:ClickTimer.Interval = [TimeSpan]::FromMilliseconds(180)
$Script:ClickTimer.add_Tick({
    $Script:ClickTimer.Stop()
    $p = $Script:ClickPending
    $Script:ClickPending = $null
    if (-not $p -or $p.Fired) { return }
    if ($Script:DragMoved) { Write-Log '点击被撤销(判定为拖动)'; return }
    $c = [System.Windows.Forms.Cursor]::Position
    if ([Math]::Abs($c.X - $p.X) -gt 4 -or [Math]::Abs($c.Y - $p.Y) -gt 4) {
        Write-Log '点击被撤销(光标已移开)'
        return
    }
    if ($p.Action) {
        Write-Log ("触发按钮: tag='{0}'" -f $p.Tag)
        & $p.Action
    } elseif ($p.Tag) {
        # tag 直接就是应用对象
        try {
                    Start-App $p.Tag
            } catch { Write-Log ("启动阶段异常: {0}" -f $_.Exception.ToString()) }
        try {
            if ($searchBox.Text) { $searchBox.Text = '' } else { Rebuild-Apps }
        } catch { Write-Log ("重建面板异常: {0}" -f $_.Exception.ToString()) }
    }
})

function Get-PinnedApps([string]$filter = '') {
    # 有搜索词时搜全部应用(否则没被勾进容器的应用就搜不到);
    # 无搜索词时只显示勾选那批, 没勾选过就默认取前 N 个。
    # 重要: 两个分支都必须用逗号返回 ,$x, 否则单元素数组会被 PowerShell 拆成标量,
    # 调用方拿到的不是数组, $list.Count 会变成空值。
    if ($filter) {
        $f = $filter.ToLower()
        return ,@($Script:Apps | Where-Object { $_.search.Contains($f) })
    }
    $names = @($cfg.pinned)
    $list = @()
    if ($names.Count -gt 0) {
        foreach ($n in $names) {
            $hit = $Script:Apps | Where-Object { $_.name -eq $n } | Select-Object -First 1
            if ($hit) { $list += $hit }
        }
    }
    if ($list.Count -eq 0) { $list = @($Script:Apps | Select-Object -First ($cfg.cols * $cfg.rows)) }
    return ,$list
}

function Build-AppTile($app) {
    $bd = New-Object System.Windows.Controls.Border
    $bd.Height = $cfg.itemH - 8
    $bd.Width = $cfg.itemW - 8
    $bd.CornerRadius = New-Object System.Windows.CornerRadius 9
    # 用近乎全透明的实心画刷而不是 Brushes.Transparent:
    # 透明画刷在空白区域不参与命中测试, 点到图标/文字之外就收不到事件。
    $bd.Background = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.Color]::FromArgb(1, 255, 255, 255))
    $bd.Tag = $app
    $bd.ToolTip = $app.name
    $bd.Cursor = 'Hand'

    $sp = New-Object System.Windows.Controls.StackPanel
    $sp.VerticalAlignment = 'Center'
    $bd.Child = $sp

    $img = New-Object System.Windows.Controls.Image
    $s = Get-Icon $app.iconPath 32
    if ($s) { $img.Source = $s }
    $img.Width = 32; $img.Height = 32
    $img.Stretch = 'Uniform'
    $sp.Children.Add($img) | Out-Null

    $t = New-Object System.Windows.Controls.TextBlock
    $t.Text = if ($app.name.Length -gt 7) { $app.name.Substring(0, 6) + '…' } else { $app.name }
    $t.Foreground = $brushText
    $t.FontSize = 10
    $t.TextAlignment = 'Center'
    $t.TextWrapping = 'NoWrap'
    $t.Margin = New-Object System.Windows.Thickness 0, 6, 0, 0
    $sp.Children.Add($t) | Out-Null

    $bd.add_MouseEnter({ $this.Background = $brushHover })
    $bd.add_MouseLeave({ $this.Background = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.Color]::FromArgb(1, 255, 255, 255)) })
    # 动作挂到控件属性; 应用对象用 $this.Tag(已在上面设过)
    # 直接把应用对象当 tag 交给点击队列, 不用闭包(闭包捕获在这里不可靠)
    $bd.add_MouseLeftButtonDown({
        # 必须在这里重置拖动标志: 窗口级的按下处理器遇到 TextBox 会提前 return,
        # 那样 DragMoved 会一直停在 true, 之后所有点击都会被误判成拖动而失效。
        $Script:DragMoved = $false
        if ($this.Tag) { & $Script:QueueClick $null $this.Tag }
    })
    return $bd
}

function Rebuild-Apps {
    $q = $searchBox.Text.Trim()
    $list = Get-PinnedApps $q
    $grid.Children.Clear()
    foreach ($a in $list) { $grid.Children.Add((Build-AppTile $a)) | Out-Null }
    $title.Text = if ($q) { "搜索结果 · $($list.Count)" } else { "应用容器 · $($list.Count)" }
    $clearBtn.Visibility = if ($q) { 'Visible' } else { 'Collapsed' }
    $scroll.ScrollToVerticalOffset(0)
    Write-Log ("面板内容: {0} 项, 筛选='{1}'" -f $list.Count, $q)
}

$searchBox.add_TextChanged({
    Rebuild-Apps
})

# 滚轮: 每次约 0.9 行, 平滑滚动
$win.add_MouseWheel({
    $target = $scroll.VerticalOffset - ($_.Delta / 120 * ($cfg.itemH * 0.9))
    $target = [Math]::Max(0, [Math]::Min($target, $scroll.ScrollableHeight))
    $scroll.ScrollToVerticalOffset($target)
    $_.Handled = $true
})

# 搜索框: 点击时抢键盘焦点, 并把实际屏幕坐标写进日志便于核对
$searchWrap.add_MouseLeftButtonDown({
    try {
        # WS_EX_NOACTIVATE 的窗口收不到键盘消息, 必须显式提升为前台窗口
        [void][Native]::SetForegroundWindow($Script:Hwnd)
        [void][Native]::SetFocus($Script:Hwnd)
    } catch { Write-Log ("提升前台失败: {0}" -f $_.Exception.Message) }
    [void]$searchBox.Focus()
})
$searchBox.add_GotFocus({
})
#endregion

#region ============ 拖动与定位 ============
function Get-Scale {
    if ($Script:Hwnd -eq [IntPtr]::Zero -or $win.ActualWidth -le 0) { return 1.0 }
    $r = New-Object Native+RECT
    [void][Native]::GetWindowRect($Script:Hwnd, [ref]$r)
    return (($r.Right - $r.Left) / $win.ActualWidth)
}

# 按物理像素移动窗口, 并保持置顶
function Move-WindowTo([int]$px, [int]$py) {
    try {
        if ($Script:Hwnd -eq [IntPtr]::Zero) { return }
        $scale = Get-Scale
        if ($scale -le 0) { $scale = 1 }
        $pw = [int]($win.Width * $scale)
        $ph = [int]($win.Height * $scale)
        [Native]::MoveKeepTop($Script:Hwnd, $px, $py, $pw, $ph)
        Update-GlassBackdrop $px $py $pw $ph
    } catch { Write-Log ("Move-WindowTo 异常: {0}" -f $_.Exception.Message) }
}

# 高斯玻璃背景: 抓取面板背后的桌面区域 -> 用 WPF 做高斯模糊 -> 贴回面板底层。
# 这是"真模糊"而不是单纯半透明, 而且不依赖 DWM 的 SetWindowCompositionAttribute
# (实测那个 API 在目标机器上返回成功但完全不画)。
function Update-GlassBackdrop([int]$px, [int]$py, [int]$pw, [int]$ph) {
    if ($cfg.glass -eq 'none') { return }
    if ($pw -le 0 -or $ph -le 0) { return }
    try {
        $wa = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
        # 采样范围要比窗口大一圈, 模糊后边缘才不会有暗边
        $pad = [int]($Script:GlassBlur * 2)
        $sx = [Math]::Max($wa.Left, $px - $pad)
        $sy = [Math]::Max($wa.Top,  $py - $pad)
        $sw = [Math]::Min($pw + $pad * 2, $wa.Right - $sx)
        $sh = [Math]::Min($ph + $pad * 2, $wa.Bottom - $sy)
        if ($sw -le 0 -or $sh -le 0) { return }

        $bmp = New-Object System.Drawing.Bitmap $sw, $sh
        $g = [System.Drawing.Graphics]::FromImage($bmp)
        $g.CopyFromScreen($sx, $sy, 0, 0, (New-Object System.Drawing.Size $sw, $sh))
        $g.Dispose()
        $hbm = $bmp.GetHbitmap()
        $src = [System.Windows.Interop.Imaging]::CreateBitmapSourceFromHBitmap(
            $hbm, [IntPtr]::Zero, [System.Windows.Int32Rect]::Empty,
            [System.Windows.Media.Imaging.BitmapSizeOptions]::FromEmptyOptions())
        [void][Native]::DeleteObject($hbm)
        $bmp.Dispose()

        # 用 DrawingVisual 把图按"偏移后"画到窗口大小的画布上, 这样模糊后的内容与背后的桌面对齐
        $dv = New-Object System.Windows.Media.DrawingVisual
        $dc = $dv.RenderOpen()
        $dc.DrawImage($src, (New-Object System.Windows.Rect (-($px - $sx)), (-($py - $sy)), $sw, $sh))
        $dc.Close()
        $rtb = New-Object System.Windows.Media.Imaging.RenderTargetBitmap($pw, $ph, 96, 96, [System.Windows.Media.PixelFormats]::Pbgra32)
        $rtb.Render($dv)

        # 只保留窗口范围内的部分
        $crop = New-Object System.Windows.Media.Imaging.CroppedBitmap($rtb, (New-Object System.Windows.Int32Rect 0, 0, $pw, $ph))
        $crop.Freeze()

        $eff = New-Object System.Windows.Media.Effects.BlurEffect
        $eff.Radius = $Script:GlassBlur
        $eff.KernelType = 'Gaussian'
        $eff.RenderingBias = 'Quality'
        $bgImage.Effect = $eff
        $bgImage.Source = $crop
        $bgImage.UpdateLayout()
        $Script:GlassUpdates++
        if ($Script:GlassUpdates % 20 -eq 1) { Write-Log ("玻璃背景更新 #{0}: 采样 {1}x{2} @({3},{4}) 半径 {5}" -f $Script:GlassUpdates, $sw, $sh, $sx, $sy, $Script:GlassBlur) }
    } catch { Write-Log ("Update-GlassBackdrop 异常: {0}" -f $_.Exception.Message) }
}

function Apply-Position {
    try {
        if ($Script:Hwnd -eq [IntPtr]::Zero) { Write-Log 'Apply-Position: 句柄还是零, 跳过'; return }
        $wa = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
        $scale = Get-Scale
        $pw = [int]($win.Width * $scale)
        $ph = [int]($win.Height * $scale)
        if ($cfg.x -le -9000 -or $cfg.y -le -9000) {
            $px = $wa.Right - $pw - [int](24 * $scale)
            $py = $wa.Bottom - $ph - [int](16 * $scale)
        } else {
            $px = [int]($cfg.x * $scale)
            $py = [int]($cfg.y * $scale)
        }
        $px = [Math]::Max($wa.Left, [Math]::Min($px, [Math]::Max($wa.Left, $wa.Right - $pw)))
        $py = [Math]::Max($wa.Top, [Math]::Min($py, [Math]::Max($wa.Top, $wa.Bottom - $ph)))
        # 用 WPF 的 Left/Top 定位(逻辑坐标), 不要自己调 SetWindowPos:
        # hWndInsertAfter 传 HWND_TOP 会摘掉 WS_EX_TOPMOST, 窗口就被别的窗口盖住了
        $win.Left = [double]$px / $scale
        $win.Top  = [double]$py / $scale
        $r = New-Object Native+RECT
        [void][Native]::GetWindowRect($Script:Hwnd, [ref]$r)
        Update-GlassBackdrop $r.Left $r.Top ($r.Right - $r.Left) ($r.Bottom - $r.Top)
        Write-Log ("定位: 设({0},{1}) {2}x{3} scale={4:N2} 工作区={5} 实际=({6},{7})-({8},{9})" -f `
            $px, $py, $pw, $ph, $scale, "$($wa.Width)x$($wa.Height)",
            $r.Left, $r.Top, $r.Right, $r.Bottom)
    } catch { Write-Log ("Apply-Position 异常: {0}" -f $_.Exception.Message) }
}

# 拖动: 全程只用物理像素。起点用 GetWindowRect 取真实窗口矩形,
# 不要用 $win.Left 再做 /scale 换算 —— 那会把物理坐标二次缩放, 窗口会被拉回原位。
$Script:DragStartCursor = $null
$Script:DragStartRect = $null
$Script:MoveLogged = 0

$root.add_PreviewMouseLeftButtonDown({
    $c0 = [System.Windows.Forms.Cursor]::Position
    if ($_.OriginalSource -is [System.Windows.Controls.TextBox]) { return }
    $r = New-Object Native+RECT
    [void][Native]::GetWindowRect($Script:Hwnd, [ref]$r)
    $Script:DragStartCursor = @($c0.X, $c0.Y)
    $Script:DragStartRect = @($r.Left, $r.Top)
    $Script:IsDragging = $true
    $Script:DragMoved = $false
    $Script:MoveLogged = 0
})

$root.add_PreviewMouseMove({
    if (-not $Script:IsDragging) { return }
    $c = [System.Windows.Forms.Cursor]::Position
    $dx = $c.X - $Script:DragStartCursor[0]
    $dy = $c.Y - $Script:DragStartCursor[1]
    if (-not $Script:DragMoved) {
        if ([Math]::Abs($dx) -lt 4 -and [Math]::Abs($dy) -lt 4) { return }
        $Script:DragMoved = $true
        Write-Log '判定为拖动开始'
    }
    $nx = [Math]::Max(0, $Script:DragStartRect[0] + $dx)
    $ny = [Math]::Max(0, $Script:DragStartRect[1] + $dy)
    Move-WindowTo $nx $ny
})

$root.add_PreviewMouseLeftButtonUp({
    if ($Script:IsDragging -and $Script:DragMoved) {
        $r = New-Object Native+RECT
        [void][Native]::GetWindowRect($Script:Hwnd, [ref]$r)
        $scale = Get-Scale
        if ($scale -le 0) { $scale = 1 }
        $cfg.x = [int]($r.Left / $scale)
        $cfg.y = [int]($r.Top / $scale)
        Save-Config $cfg
        Write-Log ("拖动结束 物理=({0},{1}) 存盘逻辑=({2},{3})" -f $r.Left, $r.Top, $cfg.x, $cfg.y)
    }
    $Script:IsDragging = $false
})

$win.add_MouseLeave({
    if ($Script:IsDragging) {
        $Script:IsDragging = $false
        if ($Script:DragMoved) {
            $cfg.x = [int]$win.Left; $cfg.y = [int]$win.Top
            Save-Config $cfg
        }
    }
})
#endregion

#region ============ 编辑器: 勾选 + 排序 ============
$Script:EditOrder = $null
$Script:EditorOpen = $false

$Script:OnEdit = {
    if ($Script:EditorOpen) { Write-Log '编辑器已打开, 忽略重复请求'; return }
    Write-Log '打开编辑器'
    $Script:DragMoved = $false
    $ed = New-Object System.Windows.Window
    $ed.Title = '选择应用并调整顺序'
    $ed.Width = 640; $ed.Height = 700
    $ed.WindowStartupLocation = 'CenterScreen'
    $ed.Background = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.Color]::FromRgb(30, 32, 40))
    $ed.FontFamily = 'Microsoft YaHei UI'

    $g = New-Object System.Windows.Controls.Grid
    $g.RowDefinitions.Add((New-RowDef 'auto')) | Out-Null
    $g.RowDefinitions.Add((New-RowDef 'star')) | Out-Null
    $g.RowDefinitions.Add((New-RowDef 'auto')) | Out-Null
    $ed.Content = $g

    $top = New-Object System.Windows.Controls.StackPanel
    $top.Margin = New-Object System.Windows.Thickness 14, 14, 14, 6
    $lb = New-Object System.Windows.Controls.TextBlock
    $lb.Text = "共扫描到 $($Script:Apps.Count) 个应用。右上勾选加入，左侧用 ▲▼ 调整顺序。"
    $lb.Foreground = $brushDim
    $lb.FontSize = 12
    $lb.TextWrapping = 'Wrap'
    $top.Children.Add($lb) | Out-Null
    $sbox = New-Object System.Windows.Controls.TextBox
    $sbox.Margin = New-Object System.Windows.Thickness 0, 8, 0, 0
    $sbox.Padding = New-Object System.Windows.Thickness 8, 6, 8, 6
    $sbox.FontSize = 13
    $sbox.ToolTip = '输入名称过滤'
    $top.Children.Add($sbox) | Out-Null
    [System.Windows.Controls.Grid]::SetRow($top, 0)
    $g.Children.Add($top) | Out-Null

    $split = New-Object System.Windows.Controls.Grid
    $split.Margin = New-Object System.Windows.Thickness 14, 4, 14, 4
    $lc = New-Object System.Windows.Controls.ColumnDefinition
    $lc.Width = New-Object System.Windows.GridLength(300, [System.Windows.GridUnitType]::Pixel)
    $split.ColumnDefinitions.Add($lc) | Out-Null
    $split.ColumnDefinitions.Add((New-Object System.Windows.Controls.ColumnDefinition)) | Out-Null
    [System.Windows.Controls.Grid]::SetRow($split, 1)
    $g.Children.Add($split) | Out-Null

    $leftWrap = New-Object System.Windows.Controls.DockPanel
    [System.Windows.Controls.Grid]::SetColumn($leftWrap, 0)
    $split.Children.Add($leftWrap) | Out-Null
    $lTitle = New-Object System.Windows.Controls.TextBlock
    $lTitle.Text = '当前显示顺序'
    $lTitle.Foreground = $brushText
    $lTitle.FontSize = 12
    $lTitle.Margin = New-Object System.Windows.Thickness 2, 0, 0, 6
    [System.Windows.Controls.DockPanel]::SetDock($lTitle, 'Top')
    $leftWrap.Children.Add($lTitle) | Out-Null
    $lScroll = New-Object System.Windows.Controls.ScrollViewer
    $lScroll.VerticalScrollBarVisibility = 'Auto'
    $lScroll.Margin = New-Object System.Windows.Thickness 0, 0, 10, 0
    $leftWrap.Children.Add($lScroll) | Out-Null
    $orderPanel = New-Object System.Windows.Controls.StackPanel
    $lScroll.Content = $orderPanel

    $rightWrap = New-Object System.Windows.Controls.DockPanel
    [System.Windows.Controls.Grid]::SetColumn($rightWrap, 1)
    $split.Children.Add($rightWrap) | Out-Null
    $rTitle = New-Object System.Windows.Controls.TextBlock
    $rTitle.Text = '全部应用（勾选加入）'
    $rTitle.Foreground = $brushText
    $rTitle.FontSize = 12
    $rTitle.Margin = New-Object System.Windows.Thickness 2, 0, 0, 6
    [System.Windows.Controls.DockPanel]::SetDock($rTitle, 'Top')
    $rightWrap.Children.Add($rTitle) | Out-Null
    $rScroll = New-Object System.Windows.Controls.ScrollViewer
    $rScroll.VerticalScrollBarVisibility = 'Auto'
    $rightWrap.Children.Add($rScroll) | Out-Null
    $allPanel = New-Object System.Windows.Controls.StackPanel
    $rScroll.Content = $allPanel

    $Script:EditOrder = New-Object System.Collections.ArrayList
    $seed = if (@($cfg.pinned).Count -gt 0) { @($cfg.pinned) } else { @((Get-PinnedApps) | ForEach-Object { $_.name }) }
    foreach ($s in $seed) { [void]$Script:EditOrder.Add($s) }

    $boxes = @{}

    function Update-OrderPanel {
        $orderPanel.Children.Clear()
        if ($Script:EditOrder.Count -eq 0) {
            $empty = New-Object System.Windows.Controls.TextBlock
            $empty.Text = '（还没选应用，从右边勾选）'
            $empty.Foreground = $brushDim
            $empty.FontSize = 12
            $orderPanel.Children.Add($empty) | Out-Null
            return
        }
        for ($i = 0; $i -lt $Script:EditOrder.Count; $i++) {
            $name = $Script:EditOrder[$i]
            $row = New-Object System.Windows.Controls.Border
            $row.CornerRadius = New-Object System.Windows.CornerRadius 6
            $row.Background = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.Color]::FromRgb(44, 47, 58))
            $row.Margin = New-Object System.Windows.Thickness 0, 2, 0, 2
            $row.Padding = New-Object System.Windows.Thickness 8, 3, 3, 3
            $rg = New-Object System.Windows.Controls.Grid
            $rc0 = New-Object System.Windows.Controls.ColumnDefinition
            $rc0.Width = New-Object System.Windows.GridLength(26, [System.Windows.GridUnitType]::Pixel)
            $rg.ColumnDefinitions.Add($rc0) | Out-Null
            $rg.ColumnDefinitions.Add((New-Object System.Windows.Controls.ColumnDefinition)) | Out-Null
            $rc2 = New-Object System.Windows.Controls.ColumnDefinition
            $rc2.Width = New-Object System.Windows.GridLength(1, [System.Windows.GridUnitType]::Auto)
            $rg.ColumnDefinitions.Add($rc2) | Out-Null
            $row.Child = $rg

            $no = New-Object System.Windows.Controls.TextBlock
            $no.Text = "$($i + 1)"
            $no.Foreground = $brushDim
            $no.FontSize = 11
            $no.VerticalAlignment = 'Center'
            [System.Windows.Controls.Grid]::SetColumn($no, 0)
            $rg.Children.Add($no) | Out-Null

            $nm = New-Object System.Windows.Controls.TextBlock
            $nm.Text = $name
            $nm.Foreground = $brushText
            $nm.FontSize = 12
            $nm.VerticalAlignment = 'Center'
            $nm.TextTrimming = 'CharacterEllipsis'
            [System.Windows.Controls.Grid]::SetColumn($nm, 1)
            $rg.Children.Add($nm) | Out-Null

            $btns = New-Object System.Windows.Controls.StackPanel
            $btns.Orientation = 'Horizontal'
            $btns.VerticalAlignment = 'Center'
            [System.Windows.Controls.Grid]::SetColumn($btns, 2)
            $rg.Children.Add($btns) | Out-Null

            $idx = $i
            $bUp = New-IconButton 'up' '上移' { & $Script:MoveOrder $idx -1 ${function:Update-OrderPanel} }
            $bDn = New-IconButton 'down' '下移' { & $Script:MoveOrder $idx 1 ${function:Update-OrderPanel} }
            $bRm = New-IconButton 'close' '移出容器' { & $Script:RemoveOrder $idx ${function:Update-OrderPanel} }
            foreach ($bb in @($bUp, $bDn, $bRm)) {
                $bb.Width = 22; $bb.Height = 22
                $bb.Margin = New-Object System.Windows.Thickness 1, 0, 1, 0
                $btns.Children.Add($bb) | Out-Null
            }
            $orderPanel.Children.Add($row) | Out-Null
        }
    }

    foreach ($a in $Script:Apps) {
        $cb = New-Object System.Windows.Controls.CheckBox
        $cb.Content = $a.name
        $cb.Foreground = $brushText
        $cb.FontSize = 12.5
        $cb.Margin = New-Object System.Windows.Thickness 2, 5, 2, 5
        $cb.Tag = $a.name
        if ($Script:EditOrder -contains $a.name) { $cb.IsChecked = $true }
        $boxes[$a.name] = $cb
        $allPanel.Children.Add($cb) | Out-Null
    }

    foreach ($kv in $boxes.GetEnumerator()) {
        $nm = $kv.Key
        $kv.Value.add_Click({
            if ($this.IsChecked) {
                if (-not $Script:EditOrder.Contains($nm)) { [void]$Script:EditOrder.Add($nm) }
            } else {
                $Script:EditOrder.Remove($nm)
            }
            Update-OrderPanel
        })
    }

    $sbox.add_TextChanged({
        $q = $sbox.Text.Trim().ToLower()
        foreach ($kv in $boxes.GetEnumerator()) {
            $kv.Value.Visibility = if (-not $q -or $kv.Key.ToLower().Contains($q)) { 'Visible' } else { 'Collapsed' }
        }
    })

    $btns = New-Object System.Windows.Controls.StackPanel
    $btns.Orientation = 'Horizontal'
    $btns.HorizontalAlignment = 'Right'
    $btns.Margin = New-Object System.Windows.Thickness 14, 6, 14, 14
    [System.Windows.Controls.Grid]::SetRow($btns, 2)
    $g.Children.Add($btns) | Out-Null

    function New-DlgButton([string]$text) {
        $b = New-Object System.Windows.Controls.Button
        $b.Content = $text
        $b.Padding = New-Object System.Windows.Thickness 16, 7, 16, 7
        $b.Margin = New-Object System.Windows.Thickness 8, 0, 0, 0
        $b.FontSize = 12.5
        return $b
    }
    $bAll  = New-DlgButton '全选'
    $bNone = New-DlgButton '全不选'
    $bOk   = New-DlgButton '保存'
    $btns.Children.Add($bAll) | Out-Null
    $btns.Children.Add($bNone) | Out-Null
    $btns.Children.Add($bOk) | Out-Null

    $bAll.add_Click({
        foreach ($a in $Script:Apps) { if (-not $Script:EditOrder.Contains($a.name)) { [void]$Script:EditOrder.Add($a.name) } }
        foreach ($kv in $boxes.GetEnumerator()) { $kv.Value.IsChecked = $true }
        Update-OrderPanel
    })
    $bNone.add_Click({
        $Script:EditOrder.Clear()
        foreach ($kv in $boxes.GetEnumerator()) { $kv.Value.IsChecked = $false }
        Update-OrderPanel
    })
    $bOk.add_Click({
        try {
            $cfg.pinned = @($Script:EditOrder)
            Save-Config $cfg
            Write-Log ("编辑器保存: {0} 项" -f $cfg.pinned.Count)
            Rebuild-Apps
            $ed.Close()
        } catch { Write-Log ("编辑器保存失败: {0}" -f $_.Exception.Message) }
    })
    $bCancel = New-DlgButton '取消'
    $btns.Children.Add($bCancel) | Out-Null
    $bCancel.add_Click({ $ed.Close() })

    $ed.add_Closed({
        # 编辑器关闭后恢复容器置顶
        $win.Topmost = [bool]$cfg.topmost
        $Script:EditorOpen = $false
        Write-Log '编辑器已关闭'
    })

    # 非模态显示: ShowDialog 会在容器线程上跑嵌套消息循环, 导致容器失去响应
    $Script:EditorOpen = $true
    $win.Topmost = $false      # 让编辑器能盖住容器
    $ed.Show()
}

$Script:MoveOrder = {
    param($idx, $delta, $refresh)
    $newIdx = $idx + $delta
    if ($newIdx -lt 0 -or $newIdx -ge $Script:EditOrder.Count) { return }
    $item = $Script:EditOrder[$idx]
    $Script:EditOrder.RemoveAt($idx)
    $Script:EditOrder.Insert($newIdx, $item)
    & $refresh
}
$Script:RemoveOrder = {
    param($idx, $refresh)
    $Script:EditOrder.RemoveAt($idx)
    & $refresh
}

$Script:Hidden = $false

# 隐藏/唤出: 不用 Window.Hide()/Show()。实测在分层窗口上 Hide() 会让进程异常退出,
# 改成"取消置顶 + 移到屏幕外", 视觉上等同于隐藏, 且完全可逆。
$Script:HideDock = {
    try {
        $win.Topmost = $false
        $win.Left = -4000
        $win.Top  = -4000
        $Script:Hidden = $true
        Write-Log '容器已隐藏(移出屏幕)'
    } catch { Write-Log ("隐藏失败: {0}" -f $_.Exception.Message) }
}
$Script:ShowDock = {
    try {
        # 不要在这里调 SetWindowPos 改 z 序: 分层窗口上改 z 序会让进程异常退出
        $win.Topmost = [bool]$cfg.topmost
        Apply-Position
        $Script:Hidden = $false
        Write-Log '容器已唤出'
    } catch { Write-Log ("唤出失败: {0}" -f $_.Exception.Message) }
}

# 标题栏按钮: 图标代替文字
$btnEdit = New-IconButton 'pencil' '编辑：选择应用并调整顺序' {
    try {
        & $Script:OnEdit
    } catch { Write-Log ("编辑失败: {0}" -f $_.Exception.ToString()) }
}
$btnHide = New-IconButton 'eyeoff' '隐藏容器（Ctrl+Alt+D 唤出）' {
    $c = [System.Windows.Forms.Cursor]::Position
    Write-Log ("点击坐标 ({0},{1}) 命中[隐藏]" -f $c.X, $c.Y)
    & $Script:HideDock
}
$btnExit = New-IconButton 'power' '退出 DesktopDock' {
    try {
        $win.Close()
    } catch { Write-Log ("退出失败: {0}" -f $_.Exception.ToString()) }
}
$tools.Children.Add($btnEdit) | Out-Null
$tools.Children.Add($btnHide) | Out-Null
$tools.Children.Add($btnExit) | Out-Null

$menu = New-Object System.Windows.Controls.ContextMenu
$miEdit = New-Object System.Windows.Controls.MenuItem; $miEdit.Header = '编辑应用列表'
$miHide = New-Object System.Windows.Controls.MenuItem; $miHide.Header = '隐藏容器'
$miExit = New-Object System.Windows.Controls.MenuItem; $miExit.Header = '退出 DesktopDock'
$miEdit.add_Click({ & $Script:OnEdit })
$miHide.add_Click({ & $Script:HideDock })
$miExit.add_Click({ $win.Close() })
$menu.Items.Add($miEdit) | Out-Null
$menu.Items.Add($miHide) | Out-Null
$menu.Items.Add($miExit) | Out-Null
$rootBorder.ContextMenu = $menu
#endregion

#region ============ 全局快捷键 ============
$Script:PendingToggle = $false
$Script:Hook = [IntPtr]::Zero
$Script:HotkeyProc = [Native+LowLevelKeyboardProc]{
    param([int]$nCode, [IntPtr]$wParam, [IntPtr]$lParam)
    if ($nCode -ge 0 -and ([int]$wParam -eq [Native]::WM_KEYDOWN -or [int]$wParam -eq [Native]::WM_SYSKEYDOWN)) {
        $kb = [Runtime.InteropServices.Marshal]::PtrToStructure($lParam, [Type][Native+KBDLLHOOKSTRUCT])
        if ($kb.vkCode -eq 0x44) {
            $m = [System.Windows.Forms.Control]::ModifierKeys
            if (($m -band [System.Windows.Forms.Keys]::Control) -and ($m -band [System.Windows.Forms.Keys]::Alt)) {
                $Script:PendingToggle = $true
                return [IntPtr]1
            }
        }
    }
    return [Native]::CallNextHookEx([IntPtr]::Zero, $nCode, $wParam, $lParam)
}

$poll = New-Object System.Windows.Threading.DispatcherTimer
$poll.Interval = [TimeSpan]::FromMilliseconds(120)
$poll.add_Tick({
    if (-not $Script:PendingToggle) { return }
    $Script:PendingToggle = $false
    if ($Script:Hidden) { Write-Log '快捷键: 唤出'; & $Script:ShowDock }
    else { Write-Log '快捷键: 隐藏'; & $Script:HideDock }
})
#endregion

#region ============ 启动 ============
$script:initDone = $false

$win.add_SourceInitialized({
    if ($script:initDone) { return }
    $script:initDone = $true
    try {
        $Script:Hwnd = (New-Object System.Windows.Interop.WindowInteropHelper $win).Handle
        [Native]::MakeToolWindow($Script:Hwnd)
        $ex = [Native]::GetWindowLong($Script:Hwnd, [Native]::GWL_EXSTYLE)
        Write-Log ("窗口句柄 0x{0:X} ExStyle=0x{1:X8}" -f [int64]$Script:Hwnd, $ex)

        if ($cfg.glass -eq 'none') {
            Write-Log '玻璃效果: 已关闭(none)'
        } elseif ($cfg.glass -eq 'capture') {
            Write-Log '玻璃效果: 抓屏高斯模糊(capture), 由 Apply-Position 注入'
        } else {
            $ok = [Native]::ApplyGlass($Script:Hwnd, $tintAbgr, ($cfg.glass -eq 'acrylic'))
            if (-not $ok) {
                Write-Log '亚克力失败, 退回 BLURBEHIND'
                $ok = [Native]::ApplyBlurOnly($Script:Hwnd, $tintAbgr)
            }
            Write-Log ("玻璃效果: {0} (tint {1} -> 0x{2:X8})" -f $(if ($ok) { $cfg.glass } else { '失败' }), $tintArgb, $tintAbgr)
        }
    } catch { Write-Log ("初始化异常: {0}" -f $_.Exception.ToString()) }
})

$win.add_Loaded({
    try {
        Rebuild-Apps
        Apply-Position
        $mod = [Native]::GetModuleHandle($null)
        $Script:Hook = [Native]::SetWindowsHookEx([Native]::WH_KEYBOARD_LL, $Script:HotkeyProc, $mod, 0)
        Write-Log ("快捷键钩子 0x{0:X} (Ctrl+Alt+D)" -f [int64]$Script:Hook)
        $poll.Start()
        Write-Log '初始化完成'

        # 自查渲染: 把面板自身的视觉树渲染成 PNG, 确认内容到底有没有画出来。
        # 比截屏可靠 —— 不经 DWM 合成, 能区分「内容没画」与「画了但被玻璃盖住」。
        if ($cfg.selfcheck) {
            $Script:SelfCheckTimer = New-Object System.Windows.Threading.DispatcherTimer
            $Script:SelfCheckTimer.Interval = [TimeSpan]::FromSeconds(3)
            $Script:SelfCheckTimer.add_Tick({
                $Script:SelfCheckTimer.Stop()
                try {
                    $w = [int]$win.ActualWidth; $h = [int]$win.ActualHeight
                    $rtb = New-Object System.Windows.Media.Imaging.RenderTargetBitmap($w, $h, 96, 96, [System.Windows.Media.PixelFormats]::Pbgra32)
                    $rtb.Render($win)
                    $enc = New-Object System.Windows.Media.Imaging.PngBitmapEncoder
                    $enc.Frames.Add([System.Windows.Media.Imaging.BitmapFrame]::Create($rtb))
                    $outFile = Join-Path $Script:BasePath 'selfcheck-internal.png'
                    $fs = [System.IO.File]::Create($outFile)
                    $enc.Save($fs); $fs.Close()
                    $stride = $w * 4
                    $px = New-Object byte[] ($stride * $h)
                    $rtb.CopyPixels($px, $stride, 0)
                    $bright = 0
                    for ($i = 0; $i -lt $px.Length; $i += 4) {
                        if ($px[$i] -gt 90 -or $px[$i + 1] -gt 90 -or $px[$i + 2] -gt 90) { $bright++ }
                    }
                    Write-Log ("自查渲染: {0}x{1} 较亮像素 {2}/{3} ({4:N1}%)" -f $w, $h, $bright, ($w * $h), (100.0 * $bright / ($w * $h)))
                } catch { Write-Log ("自查渲染失败: {0}" -f $_.Exception.Message) }
            })
            $Script:SelfCheckTimer.Start()
        }
    } catch { Write-Log ("Loaded 异常: {0}" -f $_.Exception.ToString()) }
})

$win.add_Closed({
    try { if ($Script:Hook -ne [IntPtr]::Zero) { [void][Native]::UnhookWindowsHookEx($Script:Hook) } } catch {}
    Write-Log '=== DesktopDock 已退出 ==='
})

Write-Log '进入消息循环'
[void]$win.ShowDialog()
#endregion