' Run Qoder-AutoClaim.ps1 with a fully hidden window.
' The installer passes the absolute script path as the first argument.
If WScript.Arguments.Count = 0 Then WScript.Quit 1
scriptPath = WScript.Arguments(0)
CreateObject("Wscript.Shell").Run "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File """ & scriptPath & """", 0, False
