<#
    DesktopDock - 桌面应用收纳容器
    ------------------------------------------------------------
    紧凑的玻璃面板：4 列 × 4 行应用图标 + 底部搜索栏。
    纯用户态工具：不装服务、不加驱动、不动系统设置。删掉文件夹即完全卸载。

    窗口层级由配置 dockMode 决定:
      normal   顶层窗口 + 不置顶。会被其他应用盖住, 点一下或用快捷键可唤到最前。
               行为可预期, 在所有系统上都能可靠渲染。
      desktop  嵌入桌面图标层。真正的"只在桌面", 其他窗口不会盖住它。
               注意: 部分机器的桌面层级结构特殊(Progman 为 0、WorkerW 里没有
               SHELLDLL_DefView), 此模式可能不渲染 —— 先用 -Action probe 自查。
#>
param(
    [ValidateSet('run','probe','status')]
    [string]$Action = 'run'
)

$ErrorActionPreference = 'Stop'

#region ============ 路径与配置 ============
$Script:AppDir   = Split-Path -Parent $MyInvocation.MyCommand.Path
$Script:BasePath = $Script:AppDir
$Script:CfgPath  = Join-Path $Script:BasePath 'config.json'
$Script:LogPath  = Join-Path $Script:BasePath 'desktopdock.log'
$Script:CsPath   = Join-Path $Script:BasePath 'native.cs'

function Write-Log([string]$msg, [switch]$Echo) {
    try {
        if (Test-Path $Script:LogPath) {
            if ((Get-Item $Script:LogPath).Length -gt 512KB) { Move-Item $Script:LogPath "$($Script:LogPath).old" -Force }
        }
        $line = "[{0}] {1}" -f (Get-Date -Format 'HH:mm:ss'), $msg
        Add-Content -Path $Script:LogPath -Value $line -Encoding UTF8
        if ($Echo) { Write-Output $line }
    } catch {}
}

$Script:Defaults = [ordered]@{
    x          = -9999
    y          = -9999
    width      = 216
    height     = 242
    cols       = 4
    rows       = 4
    itemW      = 53
    itemH      = 40
    pinned     = @()
    glass      = 'capture'
    dockMode   = 'normal'
    theme      = 'auto'
    blurRadius = 22
    topmost    = $false
    selfcheck  = $false
}

# 深浅两套配色。面板透明度(alpha)决定玻璃浓淡, 文字色随主题反转。
$Script:Palette = @{
    dark = [ordered]@{
        panel = '#73101418'; tint = '#00000000'; divider = '#26FFFFFF'
        field = '#33000000'; hover = '#2EFFFFFF'; text = '#FFF8FAFF'; dim = '#C8DCE2F0'
    }
    light = [ordered]@{
        panel = '#73FFFFFF'; tint = '#00000000'; divider = '#30000000'
        field = '#1F000000'; hover = '#26000000'; text = '#FF14161A'; dim = '#C8505460'
    }
}

function Ensure-Config {
    if (Test-Path $Script:CfgPath) { return }
    try {
        ($Script:Defaults | ConvertTo-Json) | Set-Content -Path $Script:CfgPath -Encoding UTF8
        Write-Log "已生成默认配置: $($Script:CfgPath)"
    } catch { Write-Log ("生成默认配置失败: {0}" -f $_.Exception.Message) }
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
function Save-Config($cfg) {
    try {
        ($cfg | ConvertTo-Json -Depth 6) | Set-Content -Path $Script:CfgPath -Encoding UTF8
        Write-Log '配置已保存'
    } catch { Write-Log "配置保存失败: $($_.Exception.Message)" }
}
function ConvertTo-Color([string]$hex) {
    # 同时支持 #RRGGBB 与 #AARRGGBB。之前只认 8 位, 传 6 位会静默变成黑色。
    if ($hex -match '^#([0-9A-Fa-f]{6})$') {
        return [System.Windows.Media.Color]::FromArgb(255,
            [Convert]::ToInt32($hex.Substring(1, 2), 16),
            [Convert]::ToInt32($hex.Substring(3, 2), 16),
            [Convert]::ToInt32($hex.Substring(5, 2), 16))
    }
    if ($hex -match '^#([0-9A-Fa-f]{8})$') {
        return [System.Windows.Media.Color]::FromArgb(
            [Convert]::ToInt32($hex.Substring(1, 2), 16),
            [Convert]::ToInt32($hex.Substring(3, 2), 16),
            [Convert]::ToInt32($hex.Substring(5, 2), 16),
            [Convert]::ToInt32($hex.Substring(7, 2), 16))
    }
    Write-Log ("颜色格式无法识别: '{0}' 已回退为黑色" -f $hex)
    return [System.Windows.Media.Color]::FromArgb(255, 0, 0, 0)
}
function New-Brush([string]$hex) {
    $c = ConvertTo-Color $hex
    return (New-Object System.Windows.Media.SolidColorBrush $c)
}
#endregion

#region ============ 原生互操作 ============
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Xaml, System.Drawing, System.Windows.Forms | Out-Null
if (-not (Test-Path $Script:CsPath)) { throw "缺少 native.cs: $($Script:CsPath)" }
Add-Type -TypeDefinition (Get-Content -Raw -Encoding UTF8 $Script:CsPath) -Language CSharp | Out-Null
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
    $map = @{}; $i = 0
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
                id = 'app{0:d3}' -f $i; name = $name; path = $f.FullName
                target = $info.Target; iconPath = (Get-AppIconPath $info.Icon $info.Target)
                search = ($name + ' ' + [IO.Path]::GetFileNameWithoutExtension($info.Target)).ToLower()
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
            if ([IO.Path]::GetExtension($path).ToLower() -eq '.ico') { $ico = New-Object System.Drawing.Icon($path, $size, $size) }
            else { $ico = [System.Drawing.Icon]::ExtractAssociatedIcon($path) }
            if ($ico) {
                $src = [System.Windows.Interop.Imaging]::CreateBitmapSourceFromHIcon(
                    $ico.Handle, [System.Windows.Int32Rect]::Empty,
                    [System.Windows.Media.Imaging.BitmapSizeOptions]::FromEmptyOptions())
                $ico.Dispose(); $src.Freeze()
            }
        }
    } catch { $src = $null }
    $Script:IconCache[$key] = $src
    return $src
}
function Start-App($app) {
    try { Start-Process -FilePath $app.path -ErrorAction Stop; Write-Log ("已启动: {0}" -f $app.name) }
    catch {
        try {
            if ($app.target -and (Test-Path $app.target)) { Start-Process -FilePath $app.target -ErrorAction Stop; Write-Log ("已启动(直接目标): {0}" -f $app.name) }
            else { Write-Log ("启动失败: {0}" -f $_.Exception.Message) }
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
        'minus'  { 'M3,8.5 L14,8.5' }
        'up'     { 'M8.5,2 L14.5,9 L2.5,9 Z' }
        'down'   { 'M8.5,15 L2.5,8 L14.5,8 Z' }
        default  { 'M2,2 L15,2 L15,15 L2,15 Z' }
    }
    $cv = New-Object System.Windows.Controls.Canvas
    $cv.Width = $size; $cv.Height = $size
    $p = New-Object System.Windows.Shapes.Path
    $p.Data = [System.Windows.Media.Geometry]::Parse($geo)
    if ($kind -in @('eyeoff','power','search','close','minus')) {
        $p.Stroke = $brush; $p.StrokeThickness = 1.9
        $p.StrokeStartLineCap = 'Round'; $p.StrokeEndLineCap = 'Round'; $p.StrokeLineJoin = 'Round'
    } else { $p.Fill = $brush }
    $sx = $size / 17.0
    $p.RenderTransform = New-Object System.Windows.Media.ScaleTransform($sx, $sx)
    $cv.Children.Add($p) | Out-Null
    return $cv
}

# macOS 风格交通灯按钮: 静止是小圆点, 悬停放大并显示符号
function New-TrafficLight([string]$kind, [string]$tip, $accent, $action) {
    $hostGrid = New-Object System.Windows.Controls.Grid
    $hostGrid.Width = 15; $hostGrid.Height = 15
    $hostGrid.ToolTip = $tip
    $hostGrid.Cursor = 'Hand'

    $dot = New-Object System.Windows.Shapes.Ellipse
    $dot.Width = 11; $dot.Height = 11
    $dot.Fill = $accent
    $dot.HorizontalAlignment = 'Center'; $dot.VerticalAlignment = 'Center'
    $dot.RenderTransformOrigin = New-Object System.Windows.Point 0.5, 0.5
    $dotScale = New-Object System.Windows.Media.ScaleTransform(1, 1)
    $dot.RenderTransform = $dotScale
    $hostGrid.Children.Add($dot) | Out-Null

    $glyph = New-Icon $kind 7 (New-Brush '#99000000')
    $glyph.HorizontalAlignment = 'Center'; $glyph.VerticalAlignment = 'Center'
    $glyph.Opacity = 0
    $glyph.IsHitTestVisible = $false
    $hostGrid.Children.Add($glyph) | Out-Null

    $hostGrid.add_MouseEnter({ $dotScale.ScaleX = 1.18; $dotScale.ScaleY = 1.18; $glyph.Opacity = 1 })
    $hostGrid.add_MouseLeave({ $dotScale.ScaleX = 1; $dotScale.ScaleY = 1; $glyph.Opacity = 0 })
    $hostGrid.add_MouseLeftButtonDown({ & $Script:QueueClick $action $kind })
    return $hostGrid
}

# 主题: 跟随 Windows「应用界面」深浅设置(与 ThemeAutoSwitch 写的是同一处注册表)
function Get-SystemTheme {
    $v = (Get-ItemProperty 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Themes\Personalize' `
          -Name 'AppsUseLightTheme' -EA SilentlyContinue).AppsUseLightTheme
    if ($null -eq $v) { return 'dark' }
    if ($v -eq 1) { return 'light' } else { return 'dark' }
}
function Resolve-Theme($cfg) {
    if ($cfg.theme -eq 'auto') { return (Get-SystemTheme) }
    return $cfg.theme
}
#endregion

#region ============ 点击队列 ============
# 抬起事件在分层窗口上收不到, 所以按下瞬间入队, 180ms 后校验位移; 拖动超过 4 像素则撤销。
$Script:QueueClick = {
    param($action, $tag)
    if ($Script:DragMoved) { return }
    $c = [System.Windows.Forms.Cursor]::Position
    $Script:ClickPending = [pscustomobject]@{ Action = $action; Tag = $tag; X = $c.X; Y = $c.Y }
    $Script:ClickTimer.Stop()
    $Script:ClickTimer.Start()
}
#endregion

#region ============ 界面 ============
Ensure-Config
$cfg = Get-Config
Invoke-ScanApps
$Script:CurrentTheme = Resolve-Theme $cfg
$Script:ThemedBrushes = @{}
function Get-ThemedBrush([string]$slot) {
    $key = "$($Script:CurrentTheme)|$slot"
    if (-not $Script:ThemedBrushes.ContainsKey($key)) { $Script:ThemedBrushes[$key] = New-Brush $Script:Palette[$Script:CurrentTheme][$slot] }
    return $Script:ThemedBrushes[$key]
}

$win = New-Object System.Windows.Window
$win.WindowStyle = 'None'
$win.ResizeMode = 'NoResize'
$win.ShowInTaskbar = $false
$win.AllowsTransparency = $false
$win.WindowStartupLocation = 'Manual'
$win.Width = $cfg.width
$win.Height = $cfg.height
$win.FontFamily = 'Microsoft YaHei UI'
$win.Topmost = [bool]$cfg.topmost
$win.Cursor = 'Arrow'

$rootBorder = New-Object System.Windows.Controls.Border
$rootBorder.BorderThickness = New-Object System.Windows.Thickness 1
$win.Content = $rootBorder

# 背景层: 模糊后的桌面截图 -> 半透明染色 -> 内容
$bgHost = New-Object System.Windows.Controls.Grid
$rootBorder.Child = $bgHost
$bgImage = New-Object System.Windows.Controls.Image
$bgImage.Stretch = 'Fill'
$bgHost.Children.Add($bgImage) | Out-Null
$bgTint = New-Object System.Windows.Controls.Border
$bgHost.Children.Add($bgTint) | Out-Null
$root = New-Object System.Windows.Controls.Grid
$root.Background = [System.Windows.Media.Brushes]::Transparent
$bgHost.Children.Add($root) | Out-Null

function New-RowDef([string]$mode, [double]$v = 0) {
    $rd = New-Object System.Windows.Controls.RowDefinition
    if ($mode -eq 'auto') { $rd.Height = New-Object System.Windows.GridLength(1, [System.Windows.GridUnitType]::Auto) }
    elseif ($mode -eq 'star') { $rd.Height = New-Object System.Windows.GridLength(1, [System.Windows.GridUnitType]::Star) }
    else { $rd.Height = New-Object System.Windows.GridLength($v, [System.Windows.GridUnitType]::Pixel) }
    return $rd
}
# 26(按钮) + 160(图标区) + 34(搜索) + 22(提示) = 242 = 窗口高
$root.RowDefinitions.Add((New-RowDef 'pixel' 26)) | Out-Null
$root.RowDefinitions.Add((New-RowDef 'pixel' ($cfg.itemH * $cfg.rows))) | Out-Null
$root.RowDefinitions.Add((New-RowDef 'pixel' 34)) | Out-Null
$root.RowDefinitions.Add((New-RowDef 'pixel' 22)) | Out-Null

# 顶部: 无标题, 只有三个 macOS 交通灯按钮; 左侧空白用作拖动区
$top = New-Object System.Windows.Controls.Border
$top.Padding = New-Object System.Windows.Thickness 8, 7, 8, 0
[System.Windows.Controls.Grid]::SetRow($top, 0)
$root.Children.Add($top) | Out-Null
$topGrid = New-Object System.Windows.Controls.Grid
$top.Child = $topGrid
$tc0 = New-Object System.Windows.Controls.ColumnDefinition
$tc1 = New-Object System.Windows.Controls.ColumnDefinition
$tc1.Width = New-Object System.Windows.GridLength(1, [System.Windows.GridUnitType]::Auto)
$topGrid.ColumnDefinitions.Add($tc0) | Out-Null
$topGrid.ColumnDefinitions.Add($tc1) | Out-Null

$dragArea = New-Object System.Windows.Controls.Border
$dragArea.Background = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.Color]::FromArgb(1, 0, 0, 0))
$dragArea.Cursor = 'SizeAll'
[System.Windows.Controls.Grid]::SetColumn($dragArea, 0)
$topGrid.Children.Add($dragArea) | Out-Null

$lights = New-Object System.Windows.Controls.StackPanel
$lights.Orientation = 'Horizontal'
$lights.VerticalAlignment = 'Center'
[System.Windows.Controls.Grid]::SetColumn($lights, 1)
$topGrid.Children.Add($lights) | Out-Null

# 应用区
$scroll = New-Object System.Windows.Controls.ScrollViewer
$scroll.VerticalScrollBarVisibility = 'Auto'
$scroll.HorizontalScrollBarVisibility = 'Disabled'
$scroll.CanContentScroll = $false
$scroll.Padding = New-Object System.Windows.Thickness 2, 2, 2, 0
$scroll.Background = [System.Windows.Media.Brushes]::Transparent
[System.Windows.Controls.Grid]::SetRow($scroll, 1)
$root.Children.Add($scroll) | Out-Null
$grid = New-Object System.Windows.Controls.Primitives.UniformGrid
$grid.Columns = $cfg.cols
$grid.VerticalAlignment = 'Top'
$grid.Background = [System.Windows.Media.Brushes]::Transparent
$scroll.Content = $grid

# 搜索栏
$searchWrap = New-Object System.Windows.Controls.Border
$searchWrap.Margin = New-Object System.Windows.Thickness 10, 3, 10, 0
$searchWrap.CornerRadius = New-Object System.Windows.CornerRadius 8
$searchWrap.BorderThickness = New-Object System.Windows.Thickness 0.8
[System.Windows.Controls.Grid]::SetRow($searchWrap, 2)
$root.Children.Add($searchWrap) | Out-Null
$sGrid = New-Object System.Windows.Controls.Grid
$searchWrap.Child = $sGrid
$sc0 = New-Object System.Windows.Controls.ColumnDefinition
$sc0.Width = New-Object System.Windows.GridLength(1, [System.Windows.GridUnitType]::Auto)
$sc1 = New-Object System.Windows.Controls.ColumnDefinition
$sc2 = New-Object System.Windows.Controls.ColumnDefinition
$sc2.Width = New-Object System.Windows.GridLength(1, [System.Windows.GridUnitType]::Auto)
$sGrid.ColumnDefinitions.Add($sc0) | Out-Null
$sGrid.ColumnDefinitions.Add($sc1) | Out-Null
$sGrid.ColumnDefinitions.Add($sc2) | Out-Null

$searchIcon = New-Icon 'search' 10 (Get-ThemedBrush 'dim')
$searchIcon.VerticalAlignment = 'Center'
$searchIcon.Margin = New-Object System.Windows.Thickness 7, 0, 4, 0
[System.Windows.Controls.Grid]::SetColumn($searchIcon, 0)
$sGrid.Children.Add($searchIcon) | Out-Null

$searchBox = New-Object System.Windows.Controls.TextBox
$searchBox.Background = [System.Windows.Media.Brushes]::Transparent
$searchBox.BorderThickness = New-Object System.Windows.Thickness 0
$searchBox.FontSize = 10
$searchBox.VerticalContentAlignment = 'Center'
$searchBox.Padding = New-Object System.Windows.Thickness 0
$searchBox.ToolTip = '输入名称筛选应用'
[System.Windows.Controls.Grid]::SetColumn($searchBox, 1)
$sGrid.Children.Add($searchBox) | Out-Null

$clearBtn = New-TrafficLight 'close' '清空搜索' (Get-ThemedBrush 'dim') { $searchBox.Text = '' }
$clearBtn.Width = 12; $clearBtn.Height = 12
$clearBtn.Visibility = 'Collapsed'
$clearBtn.Margin = New-Object System.Windows.Thickness 0, 0, 4, 0
[System.Windows.Controls.Grid]::SetColumn($clearBtn, 2)
$sGrid.Children.Add($clearBtn) | Out-Null

# 底部提示
$hint = New-Object System.Windows.Controls.TextBlock
$hint.Text = '滚轮浏览 · 点击启动 · 拖动移动'
$hint.FontSize = 8
$hint.Opacity = 0.7
$hint.HorizontalAlignment = 'Center'
$hint.VerticalAlignment = 'Center'
[System.Windows.Controls.Grid]::SetRow($hint, 3)
$root.Children.Add($hint) | Out-Null
#endregion

#region ============ 内容构建 ============
function Get-PinnedApps([string]$filter = '') {
    # 有搜索词时搜全部应用(否则没被勾进容器的就搜不到);
    # 无搜索词时只显示勾选那批, 没勾选过就默认取前 N 个。
    # 注意: 两个分支都要用逗号返回 ,$x, 否则单元素数组会被 PowerShell 拆成标量。
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
    $bd.Width = $cfg.itemW - 3
    $bd.Height = $cfg.itemH - 3
    $bd.CornerRadius = New-Object System.Windows.CornerRadius 6
    # 近透明实心画刷: 纯 Brushes.Transparent 在空白处不参与命中测试, 点不到
    $bd.Background = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.Color]::FromArgb(1, 128, 128, 128))
    $bd.Tag = $app
    $bd.ToolTip = $app.name
    $bd.Cursor = 'Hand'

    $sp = New-Object System.Windows.Controls.StackPanel
    $sp.VerticalAlignment = 'Center'
    $bd.Child = $sp

    $img = New-Object System.Windows.Controls.Image
    $s = Get-Icon $app.iconPath 20
    if ($s) { $img.Source = $s }
    $img.Width = 20; $img.Height = 20
    $img.Stretch = 'Uniform'
    $sp.Children.Add($img) | Out-Null

    $t = New-Object System.Windows.Controls.TextBlock
    $t.Text = if ($app.name.Length -gt 6) { $app.name.Substring(0, 5) + '…' } else { $app.name }
    $t.Foreground = Get-ThemedBrush 'text'
    $t.FontSize = 7.5
    $t.TextAlignment = 'Center'
    $t.TextWrapping = 'NoWrap'
    $t.TextTrimming = 'CharacterEllipsis'
    $t.Margin = New-Object System.Windows.Thickness 0, 2, 0, 0
    $sp.Children.Add($t) | Out-Null

    $bd.add_MouseEnter({ $this.Background = (Get-ThemedBrush 'hover') })
    $bd.add_MouseLeave({
        $this.Background = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.Color]::FromArgb(1, 128, 128, 128))
    })
    $bd.add_MouseLeftButtonDown({
        # 必须重置拖动标志: 窗口级按下处理器遇到 TextBox 会提前 return,
        # 那样 DragMoved 会一直停在 true, 之后所有点击都被误判成拖动而失效。
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
    $clearBtn.Visibility = if ($q) { 'Visible' } else { 'Collapsed' }
    $scroll.ScrollToVerticalOffset(0)
    Write-Log ("面板内容: {0} 项, 筛选='{1}'" -f $list.Count, $q)
}
#endregion


#region ============ 拖动与定位 ============
function Get-Scale {
    if ($Script:Hwnd -eq [IntPtr]::Zero -or $win.ActualWidth -le 0) { return 1.0 }
    $r = New-Object Native+RECT
    [void][Native]::GetWindowRect($Script:Hwnd, [ref]$r)
    return (($r.Right - $r.Left) / $win.ActualWidth)
}

# 把窗口放到目标物理位置。desktop 模式下窗口是桌面的子窗口, 必须用 SetWindowPos 定位。
function Place-Window([int]$px, [int]$py, [int]$pw, [int]$ph) {
    try {
        if ($Script:Hwnd -eq [IntPtr]::Zero) { return }
        if ($cfg.dockMode -eq 'desktop' -and $Script:DesktopHost -ne [IntPtr]::Zero) {
            [Native]::MoveKeepTop($Script:Hwnd, $px, $py, $pw, $ph)
        } else {
            $scale = Get-Scale
            if ($scale -le 0) { $scale = 1 }
            $win.Left = [double]$px / $scale
            $win.Top  = [double]$py / $scale
        }
    } catch { Write-Log ("Place-Window 异常: {0}" -f $_.Exception.Message) }
}

# 高斯玻璃背景: 抓取面板背后的桌面 -> WPF 高斯模糊 -> 贴回面板底层。
# 不用 DWM 的 SetWindowCompositionAttribute —— 实测在目标机器上返回成功但不渲染。
function Update-GlassBackdrop([int]$px, [int]$py, [int]$pw, [int]$ph) {
    if ($cfg.glass -eq 'none') { return }
    if ($pw -le 0 -or $ph -le 0) { return }
    try {
        $wa = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
        $pad = [int]($cfg.blurRadius * 2)     # 采样范围外扩, 避免模糊后边缘发暗
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

        $dv = New-Object System.Windows.Media.DrawingVisual
        $dc = $dv.RenderOpen()
        $dc.DrawImage($src, (New-Object System.Windows.Rect (-($px - $sx)), (-($py - $sy)), $sw, $sh))
        $dc.Close()
        $rtb = New-Object System.Windows.Media.Imaging.RenderTargetBitmap($pw, $ph, 96, 96, [System.Windows.Media.PixelFormats]::Pbgra32)
        $rtb.Render($dv)
        $crop = New-Object System.Windows.Media.Imaging.CroppedBitmap($rtb, (New-Object System.Windows.Int32Rect 0, 0, $pw, $ph))
        $crop.Freeze()

        $eff = New-Object System.Windows.Media.Effects.BlurEffect
        $eff.Radius = $cfg.blurRadius
        $eff.KernelType = 'Gaussian'
        $eff.RenderingBias = 'Quality'
        $bgImage.Effect = $eff
        $bgImage.Source = $crop
        $Script:GlassUpdates++
        if ($Script:GlassUpdates % 20 -eq 1) {
            Write-Log ("玻璃背景更新 #{0}: 采样 {1}x{2} @({3},{4}) 模糊半径 {5}" -f $Script:GlassUpdates, $sw, $sh, $sx, $sy, $cfg.blurRadius)
        }
    } catch { Write-Log ("Update-GlassBackdrop 异常: {0}" -f $_.Exception.Message) }
}

function Apply-Position {
    try {
        if ($Script:Hwnd -eq [IntPtr]::Zero) { return }
        $wa = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
        $scale = Get-Scale
        $pw = [int]($win.Width * $scale)
        $ph = [int]($win.Height * $scale)
        # 桌面层模式贴屏幕右下(并让开任务栏); normal 模式用工作区
        $area = if ($cfg.dockMode -eq 'desktop') { [System.Windows.Forms.Screen]::PrimaryScreen.Bounds } else { $wa }
        $barH = [Math]::Max(0, $area.Bottom - $wa.Bottom)
        if ($cfg.x -le -9000 -or $cfg.y -le -9000) {
            $px = $area.Right - $pw - [int](20 * $scale)
            $py = $area.Bottom - $ph - $barH - [int](12 * $scale)
        } else {
            $px = [int]($cfg.x * $scale)
            $py = [int]($cfg.y * $scale)
        }
        $px = [Math]::Max($area.Left, [Math]::Min($px, [Math]::Max($area.Left, $area.Right - $pw)))
        $py = [Math]::Max($area.Top, [Math]::Min($py, [Math]::Max($area.Top, $area.Bottom - $ph)))
        # 桌面层(Progman 子窗口)实测: SetWindowPos 用的就是屏幕物理坐标, 1:1 无缩放
        # (标定结果 kx=1.0000 ky=1.0000), 因此不做任何换算, 直接传物理值。
        Place-Window $px $py $pw $ph
        Update-GlassBackdrop $px $py $pw $ph
        $rr = New-Object Native+RECT
        [void][Native]::GetWindowRect($Script:Hwnd, [ref]$rr)
        Write-Log ("定位: 目标({0},{1}) {2}x{3} ({4} 模式) 实际物理=({5},{6})-({7},{8})" -f $px, $py, $pw, $ph, $cfg.dockMode, $rr.Left, $rr.Top, $rr.Right, $rr.Bottom)
    } catch { Write-Log ("Apply-Position 异常: {0}" -f $_.Exception.Message) }
}

$Script:DragStartCursor = $null
$Script:DragStartRect = $null
$Script:MoveLogged = 0

$root.add_PreviewMouseLeftButtonDown({
    if ($_.OriginalSource -is [System.Windows.Controls.TextBox]) { return }
    $c = [System.Windows.Forms.Cursor]::Position
    $r = New-Object Native+RECT
    [void][Native]::GetWindowRect($Script:Hwnd, [ref]$r)
    $Script:DragStartCursor = @($c.X, $c.Y)
    $Script:DragStartRect = @($r.Left, $r.Top)
    $Script:IsDragging = $true
    $Script:DragMoved = $false
})

$root.add_PreviewMouseMove({
    if (-not $Script:IsDragging) { return }
    $c = [System.Windows.Forms.Cursor]::Position
    $dx = $c.X - $Script:DragStartCursor[0]
    $dy = $c.Y - $Script:DragStartCursor[1]
    if (-not $Script:DragMoved) {
        if ([Math]::Abs($dx) -lt 4 -and [Math]::Abs($dy) -lt 4) { return }
        $Script:DragMoved = $true
    }
    $nx = $Script:DragStartRect[0] + $dx
    $ny = $Script:DragStartRect[1] + $dy
    $scale = Get-Scale
    if ($scale -le 0) { $scale = 1 }
    Place-Window $nx $ny ([int]($win.Width * $scale)) ([int]($win.Height * $scale))
    Update-GlassBackdrop $nx $ny ([int]($win.Width * $scale)) ([int]($win.Height * $scale))
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
        Write-Log ("拖动结束 物理=({0},{1})" -f $r.Left, $r.Top)
    }
    $Script:IsDragging = $false
})
#endregion

#region ============ 搜索与滚轮 ============
$searchBox.add_TextChanged({ Rebuild-Apps })

# 滚轮: 每次约 0.9 行
$win.add_MouseWheel({
    $target = $scroll.VerticalOffset - ($_.Delta / 120 * ($cfg.itemH * 0.9))
    $target = [Math]::Max(0, [Math]::Min($target, $scroll.ScrollableHeight))
    $scroll.ScrollToVerticalOffset($target)
    $_.Handled = $true
})

# 搜索框: 点击时抢键盘焦点(WS_EX_NOACTIVATE 下收不到键盘消息, 所以这里不设该样式)
$searchWrap.add_MouseLeftButtonDown({
    try {
        [void][Native]::SetForegroundWindow($Script:Hwnd)
        [void][Native]::SetFocus($Script:Hwnd)
    } catch {}
    [void]$searchBox.Focus()
})
$searchBox.add_GotFocus({ [void][Native]::SetForegroundWindow($Script:Hwnd) })
$searchBox.add_KeyDown({
    if ($_.Key -eq 'Escape') { $searchBox.Text = ''; $_.Handled = $true }
    elseif ($_.Key -eq 'Enter') {
        $first = $grid.Children | Select-Object -First 1
        if ($first -and $first.Tag) { Start-App $first.Tag; $searchBox.Text = '' }
        $_.Handled = $true
    }
})
#endregion

#region ============ 隐藏 / 唤出 ============
# 不用 Window.Hide()/Show(): 实测在分层窗口上 Hide() 会让进程异常退出。
# 改成"取消置顶 + 移到屏幕外", 视觉上等同隐藏且完全可逆。
$Script:HideDock = {
    try {
        $win.Topmost = $false
        Place-Window -4000 -4000 ([int]$win.Width) ([int]$win.Height)
        $Script:Hidden = $true
        Write-Log '容器已隐藏'
    } catch { Write-Log ("隐藏失败: {0}" -f $_.Exception.Message) }
}
$Script:ShowDock = {
    try {
        $win.Topmost = [bool]$cfg.topmost
        Apply-Position
        $Script:Hidden = $false
        Write-Log '容器已唤出'
    } catch { Write-Log ("唤出失败: {0}" -f $_.Exception.Message) }
}
#endregion

#region ============ 编辑器 ============
$Script:EditOrder = $null
$Script:EditorOpen = $false

function New-DlgButton([string]$text) {
    $b = New-Object System.Windows.Controls.Button
    $b.Content = $text
    $b.Padding = New-Object System.Windows.Thickness 16, 7, 16, 7
    $b.Margin = New-Object System.Windows.Thickness 8, 0, 0, 0
    $b.FontSize = 12.5
    return $b
}
function New-SmallIconButton([string]$kind, [string]$tip, $action) {
    $bd = New-Object System.Windows.Controls.Border
    $bd.Width = 22; $bd.Height = 22
    $bd.CornerRadius = New-Object System.Windows.CornerRadius 5
    $bd.Background = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.Color]::FromArgb(1, 128, 128, 128))
    $bd.ToolTip = $tip
    $bd.Cursor = 'Hand'
    $bd.Margin = New-Object System.Windows.Thickness 1, 0, 1, 0
    $bd.Child = (New-Icon $kind 12 (New-Brush '#FFF0F0F0'))
    $bd.add_MouseEnter({ $this.Background = (New-Brush '#40FFFFFF') })
    $bd.add_MouseLeave({ $this.Background = (New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.Color]::FromArgb(1, 128, 128, 128))) })
    $bd.add_MouseLeftButtonDown({ & $Script:QueueClick $action $kind })
    return $bd
}

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

    $topPanel = New-Object System.Windows.Controls.StackPanel
    $topPanel.Margin = New-Object System.Windows.Thickness 14, 14, 14, 6
    $lb = New-Object System.Windows.Controls.TextBlock
    $lb.Text = "共扫描到 $($Script:Apps.Count) 个应用。右侧勾选加入，左侧用 ▲▼ 调整顺序。"
    $lb.Foreground = New-Brush '#C8DCE2F0'
    $lb.FontSize = 12
    $lb.TextWrapping = 'Wrap'
    $topPanel.Children.Add($lb) | Out-Null
    $sbox = New-Object System.Windows.Controls.TextBox
    $sbox.Margin = New-Object System.Windows.Thickness 0, 8, 0, 0
    $sbox.Padding = New-Object System.Windows.Thickness 8, 6, 8, 6
    $sbox.FontSize = 13
    $sbox.ToolTip = '输入名称过滤'
    $topPanel.Children.Add($sbox) | Out-Null
    [System.Windows.Controls.Grid]::SetRow($topPanel, 0)
    $g.Children.Add($topPanel) | Out-Null

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
    $lTitle.Foreground = New-Brush '#FFF8FAFF'; $lTitle.FontSize = 12
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
    $rTitle.Foreground = New-Brush '#FFF8FAFF'; $rTitle.FontSize = 12
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
            $empty.Foreground = New-Brush '#C8DCE2F0'; $empty.FontSize = 12
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
            $no.Text = "$($i + 1)"; $no.Foreground = New-Brush '#C8DCE2F0'; $no.FontSize = 11
            $no.VerticalAlignment = 'Center'
            [System.Windows.Controls.Grid]::SetColumn($no, 0); $rg.Children.Add($no) | Out-Null

            $nm = New-Object System.Windows.Controls.TextBlock
            $nm.Text = $name; $nm.Foreground = New-Brush '#FFF8FAFF'; $nm.FontSize = 12
            $nm.VerticalAlignment = 'Center'; $nm.TextTrimming = 'CharacterEllipsis'
            [System.Windows.Controls.Grid]::SetColumn($nm, 1); $rg.Children.Add($nm) | Out-Null

            $btns = New-Object System.Windows.Controls.StackPanel
            $btns.Orientation = 'Horizontal'; $btns.VerticalAlignment = 'Center'
            [System.Windows.Controls.Grid]::SetColumn($btns, 2); $rg.Children.Add($btns) | Out-Null

            $idx = $i
            $bUp = New-SmallIconButton 'up' '上移' { & $Script:MoveOrder $idx -1 ${function:Update-OrderPanel} }
            $bDn = New-SmallIconButton 'down' '下移' { & $Script:MoveOrder $idx 1 ${function:Update-OrderPanel} }
            $bRm = New-SmallIconButton 'close' '移出容器' { & $Script:RemoveOrder $idx ${function:Update-OrderPanel} }
            foreach ($bb in @($bUp, $bDn, $bRm)) { $btns.Children.Add($bb) | Out-Null }
            $orderPanel.Children.Add($row) | Out-Null
        }
    }

    foreach ($a in $Script:Apps) {
        $cb = New-Object System.Windows.Controls.CheckBox
        $cb.Content = $a.name
        $cb.Foreground = New-Brush '#FFF8FAFF'
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
            if ($this.IsChecked) { if (-not $Script:EditOrder.Contains($nm)) { [void]$Script:EditOrder.Add($nm) } }
            else { $Script:EditOrder.Remove($nm) }
            Update-OrderPanel
        })
    }
    $sbox.add_TextChanged({
        $q = $sbox.Text.Trim().ToLower()
        foreach ($kv in $boxes.GetEnumerator()) {
            $kv.Value.Visibility = if (-not $q -or $kv.Key.ToLower().Contains($q)) { 'Visible' } else { 'Collapsed' }
        }
    })

    $btnsRow = New-Object System.Windows.Controls.StackPanel
    $btnsRow.Orientation = 'Horizontal'
    $btnsRow.HorizontalAlignment = 'Right'
    $btnsRow.Margin = New-Object System.Windows.Thickness 14, 6, 14, 14
    [System.Windows.Controls.Grid]::SetRow($btnsRow, 2)
    $g.Children.Add($btnsRow) | Out-Null
    $bAll = New-DlgButton '全选'; $bNone = New-DlgButton '全不选'
    $bCancel = New-DlgButton '取消'; $bOk = New-DlgButton '保存'
    $btnsRow.Children.Add($bAll) | Out-Null
    $btnsRow.Children.Add($bNone) | Out-Null
    $btnsRow.Children.Add($bCancel) | Out-Null
    $btnsRow.Children.Add($bOk) | Out-Null
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
    $bCancel.add_Click({ $ed.Close() })
    $bOk.add_Click({
        try {
            $cfg.pinned = @($Script:EditOrder)
            Save-Config $cfg
            Write-Log ("编辑器保存: {0} 项" -f $cfg.pinned.Count)
            Rebuild-Apps
            $ed.Close()
        } catch { Write-Log ("编辑器保存失败: {0}" -f $_.Exception.Message) }
    })
    $ed.add_Closed({
        $win.Topmost = [bool]$cfg.topmost
        $Script:EditorOpen = $false
        Write-Log '编辑器已关闭'
    })

    Update-OrderPanel
    # 非模态: ShowDialog 会在容器线程上跑嵌套消息循环, 导致容器失去响应
    $Script:EditorOpen = $true
    $win.Topmost = $false
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
#endregion

#region ============ 交通灯按钮(编辑 / 隐藏 / 退出) ============
$lights.Children.Add((New-TrafficLight 'close' '退出 DesktopDock' (New-Brush '#FF5F57') { $win.Close() })) | Out-Null
$lights.Children.Add((New-TrafficLight 'minus' '隐藏容器（Ctrl+Alt+D 唤出）' (New-Brush '#FEBC2E') { & $Script:HideDock })) | Out-Null
$lights.Children.Add((New-TrafficLight 'pencil' '编辑：选择应用并调整顺序' (New-Brush '#28C840') { & $Script:OnEdit })) | Out-Null

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

#region ============ 主题切换: 随系统深浅模式实时换肤 ============
function Apply-Theme([string]$newTheme) {
    if ($Script:CurrentTheme -eq $newTheme) { return }
    $Script:CurrentTheme = $newTheme
    $p = $Script:Palette[$newTheme]
    $win.Background = New-Brush $p.panel
    $rootBorder.Background = New-Brush $p.panel
    $rootBorder.BorderBrush = New-Brush $p.divider
    $bgTint.Background = New-Brush $p.panel
    $searchWrap.Background = New-Brush $p.field
    $searchWrap.BorderBrush = New-Brush $p.divider
    $searchBox.Foreground = New-Brush $p.text
    $searchBox.CaretBrush = New-Brush $p.text
    $hint.Foreground = New-Brush $p.dim
    $searchIcon.Children[0].Stroke = New-Brush $p.dim
    # 图标文字颜色随主题
    Rebuild-Apps
    Write-Log ("主题已切换为: {0}" -f $(if ($newTheme -eq 'light') { '浅色' } else { '深色' }))
}

# 主题轮询: 比对当前实际主题, 变化就换肤(这样 ThemeAutoSwitch 切换后能自动跟上)
$Script:ThemePoll = New-Object System.Windows.Threading.DispatcherTimer
$Script:ThemePoll.Interval = [TimeSpan]::FromSeconds(3)
$Script:ThemePoll.add_Tick({
    try {
        $want = Resolve-Theme $cfg
        if ($want -ne $Script:CurrentTheme) { Apply-Theme $want }
    } catch {}
})
#endregion

#region ============ 桌面层嵌入 ============
# 把窗口挂到桌面图标层(SHELLDLL_DefView)或 Progman, 使其"只在桌面"、不被其他窗口覆盖。
#
# 关键点(踩过的坑):
#   1. SetParent 之前必须先清除 WS_POPUP 并设置 WS_CHILD, 否则跨进程挂载会被拒绝(错误 5)。
#   2. SetParent 的返回值是"原父窗口", 返回 0 不代表失败; 要用 GetParent 复核是否真的挂上了。
#   3. 挂载后位置由父窗口坐标系决定, 必须用 SetWindowPos 重新定位(不能再用 WPF 的 Left/Top)。
#
# 注意: 此模式下的窗口属于 DWM 桌面合成层, 普通截屏(CopyFromScreen)抓不到它,
#       所以只能靠肉眼确认, 无法自动验证。
function Mount-DesktopLayer {
    try {
        if ($Script:Hwnd -eq [IntPtr]::Zero) { return $false }
        $host_ = [Native]::FindDesktopHost()
        if ($host_ -eq [IntPtr]::Zero) {
            Write-Log '未找到桌面宿主窗口, 退回 normal 模式'
            return $false
        }
        # 1) 清 WS_POPUP, 设 WS_CHILD
        $st = [Native]::GetWindowLong($Script:Hwnd, [Native]::GWL_STYLE)
        $st = ($st -band (-bnot [Native]::WS_POPUP)) -bor [Native]::WS_CHILD
        [void][Native]::SetWindowLong($Script:Hwnd, [Native]::GWL_STYLE, $st)
        Write-Log ("桌面层: style 已改为 0x{0:X8}" -f $st)
        # 2) SetParent
        $prev = [Native]::SetParent($Script:Hwnd, $host_)
        $err = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
        Write-Log ("桌面层: SetParent 原父=0x{0:X} 错误={1}" -f [int64]$prev, $err)
        # 3) 复核是否真的挂上了(SetParent 返回 0 或错误非 0 都不代表失败, 必须查 GetParent)
        $actual = [Native]::GetParent($Script:Hwnd)
        if ($actual -eq $host_) {
            $Script:DesktopHost = $host_
            Write-Log ("桌面层: 挂载成功, 宿主=0x{0:X}" -f [int64]$host_)
            return $true
        }
        Write-Log ("桌面层: 挂载未生效(实际父=0x{0:X} 期望=0x{1:X}), 退回 normal" -f [int64]$actual, [int64]$host_)
        # 还原样式, 避免窗口变成不可见的子窗口
        $st2 = ([Native]::GetWindowLong($Script:Hwnd, [Native]::GWL_STYLE) -band (-bnot [Native]::WS_CHILD)) -bor [Native]::WS_POPUP
        [void][Native]::SetWindowLong($Script:Hwnd, [Native]::GWL_STYLE, $st2)
        [void][Native]::SetParent($Script:Hwnd, [IntPtr]::Zero)
        return $false
    } catch {
        Write-Log ("嵌入桌面层失败: {0}" -f $_.Exception.Message)
        return $false
    }
}

function Invoke-Probe {
    # 自查桌面层可用性。判断依据是"SetParent 后 GetParent 是否真的变成宿主",
    # 而不是判断 Progman 是否存在 —— 之前用 FindWindow("Progman") 得到 0 就下结论, 是错的。
    Write-Log '=== 桌面层探针开始 ===' -Echo
    $progman = [Native]::GetShellWindow()
    $defview = [IntPtr]::Zero
    if ($progman -ne [IntPtr]::Zero) { $defview = [Native]::FindWindowEx($progman, [IntPtr]::Zero, 'SHELLDLL_DefView', $null) }
    Write-Log ("Progman = 0x{0:X}" -f [int64]$progman) -Echo
    Write-Log ("SHELLDLL_DefView = 0x{0:X}" -f [int64]$defview) -Echo

    $host_ = [Native]::FindDesktopHost()
    Write-Log ("FindDesktopHost = 0x{0:X}" -f [int64]$host_) -Echo

    # 实测挂载: 真挂一次, 看 GetParent 是否变成宿主, 再还原
    $ok = $false
    if ($Script:Hwnd -ne [IntPtr]::Zero -and $host_ -ne [IntPtr]::Zero) {
        $st = [Native]::GetWindowLong($Script:Hwnd, [Native]::GWL_STYLE)
        $st2 = ($st -band (-bnot [Native]::WS_POPUP)) -bor [Native]::WS_CHILD
        [void][Native]::SetWindowLong($Script:Hwnd, [Native]::GWL_STYLE, $st2)
        $prev = [Native]::SetParent($Script:Hwnd, $host_)
        $err = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
        $actual = [Native]::GetParent($Script:Hwnd)
        $ok = ($actual -eq $host_)
        Write-Log ("实测挂载: SetParent 原父=0x{0:X} 错误={1} 之后 GetParent=0x{2:X} => {3}" -f `
            [int64]$prev, $err, [int64]$actual, $(if ($ok) { '成功' } else { '未生效' })) -Echo
        # 还原为普通顶层窗口
        [void][Native]::SetParent($Script:Hwnd, [IntPtr]::Zero)
        $st3 = ([Native]::GetWindowLong($Script:Hwnd, [Native]::GWL_STYLE) -band (-bnot [Native]::WS_CHILD)) -bor [Native]::WS_POPUP
        [void][Native]::SetWindowLong($Script:Hwnd, [Native]::GWL_STYLE, $st3)
    }

    if ($ok) { Write-Log '结论: desktop 模式可用 —— 实测已成功挂到桌面层' -Echo }
    elseif ($defview -ne [IntPtr]::Zero) { Write-Log '结论: 找到桌面图标层但挂载未生效, 建议用 normal 模式' -Echo }
    else { Write-Log '结论: 桌面层级结构特殊, 建议用 normal 模式' -Echo }
    Write-Log '=== 桌面层探针结束 ==='
}
#endregion

#region ============ 快捷键 ============
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
$Script:Poll = New-Object System.Windows.Threading.DispatcherTimer
$Script:Poll.Interval = [TimeSpan]::FromMilliseconds(120)
$Script:Poll.add_Tick({
    if (-not $Script:PendingToggle) { return }
    $Script:PendingToggle = $false
    if ($Script:Hidden) { & $Script:ShowDock } else { & $Script:HideDock }
})
#endregion

#region ============ 启动 ============
$Script:DesktopHost = [IntPtr]::Zero
$Script:GlassUpdates = 0
$script:initDone = $false

$win.add_SourceInitialized({
    if ($script:initDone) { return }
    $script:initDone = $true
    try {
        $Script:Hwnd = (New-Object System.Windows.Interop.WindowInteropHelper $win).Handle
        $Script:CurrentTheme = Resolve-Theme $cfg
        $p = $Script:Palette[$Script:CurrentTheme]
        $win.Background = New-Brush $p.panel
        $rootBorder.Background = New-Brush $p.panel
        $rootBorder.BorderBrush = New-Brush $p.divider
        $bgTint.Background = New-Brush $p.panel
        $searchWrap.Background = New-Brush $p.field
        $searchWrap.BorderBrush = New-Brush $p.divider
        $searchBox.Foreground = New-Brush $p.text
        $searchBox.CaretBrush = New-Brush $p.text
        $hint.Foreground = New-Brush $p.dim

        # 去掉 NOACTIVATE(否则收不到键盘输入), 只保留 TOOLWINDOW 不进任务栏
        [Native]::MakeToolWindow($Script:Hwnd)
        $ex = [Native]::GetWindowLong($Script:Hwnd, [Native]::GWL_EXSTYLE)
        Write-Log ("窗口句柄 0x{0:X} ExStyle=0x{1:X8} dockMode={2} theme={3}" -f [int64]$Script:Hwnd, $ex, $cfg.dockMode, $Script:CurrentTheme)

        if ($cfg.glass -eq 'none') { Write-Log '玻璃效果: 已关闭' }
        else { Write-Log ("玻璃效果: 抓屏高斯模糊, 半径 {0}" -f $cfg.blurRadius) }

        if ($cfg.dockMode -eq 'desktop') { [void](Mount-DesktopLayer) }
    } catch { Write-Log ("初始化异常: {0}" -f $_.Exception.ToString()) }
})

$win.add_Loaded({
    try {
        Rebuild-Apps
        Apply-Position
        $mod = [Native]::GetModuleHandle($null)
        $Script:Hook = [Native]::SetWindowsHookEx([Native]::WH_KEYBOARD_LL, $Script:HotkeyProc, $mod, 0)
        Write-Log ("快捷键钩子 0x{0:X} (Ctrl+Alt+D)" -f [int64]$Script:Hook)
        $Script:Poll.Start()
        $Script:ThemePoll.Start()
        Write-Log '初始化完成'

        if ($cfg.selfcheck) {
            $sc = New-Object System.Windows.Threading.DispatcherTimer
            $sc.Interval = [TimeSpan]::FromSeconds(3)
            $Script:SelfCheckTimer = $sc
            $sc.add_Tick({
                $Script:SelfCheckTimer.Stop()
                try {
                    $w = [int]$win.ActualWidth; $h = [int]$win.ActualHeight
                    $rtb = New-Object System.Windows.Media.Imaging.RenderTargetBitmap($w, $h, 96, 96, [System.Windows.Media.PixelFormats]::Pbgra32)
                    $rtb.Render($win)
                    $enc = New-Object System.Windows.Media.Imaging.PngBitmapEncoder
                    $enc.Frames.Add([System.Windows.Media.Imaging.BitmapFrame]::Create($rtb))
                    $outFile = Join-Path $Script:BasePath 'selfcheck-internal.png'
                    $fs = [System.IO.File]::Create($outFile); $enc.Save($fs); $fs.Close()
                    $stride = $w * 4
                    $px = New-Object byte[] ($stride * $h)
                    $rtb.CopyPixels($px, $stride, 0)
                    $bright = 0
                    for ($i = 0; $i -lt $px.Length; $i += 4) { if ($px[$i] -gt 90 -or $px[$i+1] -gt 90 -or $px[$i+2] -gt 90) { $bright++ } }
                    Write-Log ("自查渲染: {0}x{1} 较亮像素 {2:N1}%" -f $w, $h, (100.0 * $bright / ($w * $h)))
                } catch { Write-Log ("自查渲染失败: {0}" -f $_.Exception.Message) }
            })
            $sc.Start()
        }
    } catch { Write-Log ("Loaded 异常: {0}" -f $_.Exception.ToString()) }
})

$win.add_Closed({
    try { if ($Script:Hook -ne [IntPtr]::Zero) { [void][Native]::UnhookWindowsHookEx($Script:Hook) } } catch {}
    Write-Log '=== DesktopDock 已退出 ==='
})

if ($Action -eq 'probe') {
    # 探针需要窗口句柄, 所以要先显示窗口; 探完自动关闭
    $probeTimer = New-Object System.Windows.Threading.DispatcherTimer
    $probeTimer.Interval = [TimeSpan]::FromSeconds(2)
    $Script:ProbeTimer = $probeTimer
    $probeTimer.add_Tick({
        $Script:ProbeTimer.Stop()
        Invoke-Probe
        $win.Close()
    })
    $probeTimer.Start()
    [void]$win.ShowDialog()
} else {
    Write-Log ("进入消息循环 (action={0})" -f $Action)
    [void]$win.ShowDialog()
}
#endregion
