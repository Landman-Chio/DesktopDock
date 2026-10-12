param(
    [ValidateSet('install','remove','status')]
    [string]$Action = 'install',
    [string]$Dir = ''
)
$ErrorActionPreference = 'Stop'
if (-not $Dir) { $Dir = Split-Path -Parent $MyInvocation.MyCommand.Path }

$vbs     = Join-Path $Dir 'launcher.vbs'
$startup = [Environment]::GetFolderPath('Startup')
$lnkPath = Join-Path $startup 'DesktopDock.lnk'

switch ($Action) {
    'install' {
        if (-not (Test-Path $vbs)) { throw "缺少启动器: $vbs" }
        $wscript = Join-Path $env:SystemRoot 'System32\wscript.exe'
        $sh = New-Object -ComObject WScript.Shell
        $l = $sh.CreateShortcut($lnkPath)
        $l.TargetPath       = $wscript
        $l.Arguments        = '"' + $vbs + '"'
        $l.WorkingDirectory = $Dir
        $l.Description      = 'DesktopDock 桌面应用容器'
        $l.WindowStyle      = 7
        $l.Save()
        [void][Runtime.InteropServices.Marshal]::ReleaseComObject($sh)
        Write-Output "已启用开机自启"
        Write-Output "  快捷方式: $lnkPath"
        Write-Output "  指向: $wscript `"$vbs`""
    }
    'remove' {
        if (Test-Path $lnkPath) { Remove-Item $lnkPath -Force; Write-Output "已关闭开机自启 ($lnkPath)" }
        else { Write-Output "开机自启本来就未启用" }
    }
    'status' {
        if (Test-Path $lnkPath) { Write-Output "开机自启: 已启用 ($lnkPath)" }
        else { Write-Output "开机自启: 未启用" }
    }
}
