' Launch Environment Manager GUI without a console window.
' Usage: wscript launch.vbs [extra args passed to envman.ps1]
Option Explicit

Dim shell, fso, here, scriptPath, extra, cmdLine, i, args
Set shell = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")

here = fso.GetParentFolderName(WScript.ScriptFullName)
scriptPath = fso.BuildPath(here, "src\envman.ps1")

If Not fso.FileExists(scriptPath) Then
    MsgBox "Main script not found:" & vbCrLf & scriptPath, vbCritical, "Environment Manager"
    WScript.Quit 1
End If

extra = ""
For i = 0 To WScript.Arguments.Count - 1
    extra = extra & " " & WScript.Arguments(i)
Next

cmdLine = "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File """ & scriptPath & """" & extra
shell.Run cmdLine, 0, False
