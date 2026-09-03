' Starts the Fyndkoll tray watcher with no console window.
' Double-click this, or let the "Starta med Windows" menu item point at it.
Set shell = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")
here = fso.GetParentFolderName(WScript.ScriptFullName)
script = here & "\Fyndkoll-Tray.ps1"
shell.CurrentDirectory = here
shell.Run "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -STA -File """ & script & """", 0, False
