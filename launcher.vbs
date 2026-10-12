' DesktopDock silent launcher
' Double-click this file to start the dock without a console window.
' (中文用户可以直接双击本文件，效果相同。)
Option Explicit
Dim sh, fso, base, target
Set sh  = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")
base   = fso.GetParentFolderName(WScript.ScriptFullName)
target = base & "\DesktopDock.ps1"
If Not fso.FileExists(target) Then
    MsgBox "DesktopDock.ps1 not found in the same folder:" & vbCrLf & target, 16, "DesktopDock"
    WScript.Quit 1
End If
' 0 = hidden window, False = don't wait
sh.Run "powershell.exe -NoProfile -ExecutionPolicy Bypass -File """ & target & """", 0, False
