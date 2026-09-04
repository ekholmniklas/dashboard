<#
Installerar Fyndkoll lokalt och sätter upp autostart.

Varför: den här mappen ligger under OneDrive, och OneDrive lägger filerna som
"Files On-Demand"-platshållare (attributet ReparsePoint). Vid inloggning har
OneDrive inte hunnit starta, så en autostart-genväg som pekar hit får en fil utan
innehåll och misslyckas tyst. Därför kopieras appen till %LOCALAPPDATA%, som
alltid finns lokalt, och genvägen pekar dit.

Kör om det här skriptet när du ändrat något i mappen.
#>
[CmdletBinding()]
param(
    # Hoppa över autostart-genvägen.
    [switch]$NoAutoStart,
    # Ta bort installationen och autostarten igen.
    [switch]$Uninstall
)

$ErrorActionPreference = 'Stop'

$source = $PSScriptRoot
$target = Join-Path $env:LOCALAPPDATA 'Fyndkoll\app'
$startupLink = Join-Path ([Environment]::GetFolderPath('Startup')) 'Fyndkoll.lnk'

$files = @(
    'Fyndkoll-Tray.ps1',
    'FyndParse.ps1',
    'Start-Fyndkoll.vbs',
    'fyndkoll.ico',
    'fyndkoll-alert.ico',
    'mascot.png',
    'mascot-alert.png'
)

function Stop-Fyndkoll {
    $mine = $PID
    $running = @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" |
        Where-Object { $_.ProcessId -ne $mine -and $_.CommandLine -like '*Fyndkoll-Tray.ps1*' })
    foreach ($p in $running) {
        Write-Host "  stoppar korande instans (PID $($p.ProcessId))"
        Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue
    }
    if ($running.Count) { Start-Sleep -Seconds 2 }
}

if ($Uninstall) {
    Stop-Fyndkoll
    if (Test-Path $startupLink) {
        Remove-Item $startupLink -Force
        Write-Host "Autostart borttagen."
    }
    if (Test-Path $target) {
        Remove-Item $target -Recurse -Force
        Write-Host "Appfiler borttagna fran $target"
    }
    Write-Host "Klart. Installningar och logg ligger kvar i $env:LOCALAPPDATA\Fyndkoll"
    return
}

Write-Host "Installerar Fyndkoll"
Write-Host "  fran : $source"
Write-Host "  till : $target"
Write-Host ""

Stop-Fyndkoll

if (-not (Test-Path $target)) { New-Item -ItemType Directory -Path $target -Force | Out-Null }

$missing = @()
foreach ($name in $files) {
    $from = Join-Path $source $name
    if (-not (Test-Path $from)) { $missing += $name; continue }
    # Copy-Item hydrerar OneDrive-platshallaren, sa kopian blir en riktig fil.
    Copy-Item -Path $from -Destination (Join-Path $target $name) -Force
}
if ($missing.Count) {
    throw "Saknade filer i $source : $($missing -join ', ')"
}

Write-Host "Kopierade $($files.Count) filer. Kontrollerar att de ar lokala:"
$bad = @()
foreach ($name in $files) {
    $item = Get-Item (Join-Path $target $name) -Force
    $isPlaceholder = $item.Attributes.ToString() -match 'ReparsePoint'
    if ($isPlaceholder) { $bad += $name }
    Write-Host ("  {0,-22} {1,8:N0} B   {2}" -f $item.Name, $item.Length, $item.Attributes)
}
if ($bad.Count) { throw "Fortfarande platshallare: $($bad -join ', ')" }

if (-not $NoAutoStart) {
    $shell = New-Object -ComObject WScript.Shell
    $sc = $shell.CreateShortcut($startupLink)
    $sc.TargetPath = 'wscript.exe'
    $sc.Arguments = """$(Join-Path $target 'Start-Fyndkoll.vbs')"""
    $sc.WorkingDirectory = $target
    $sc.IconLocation = "$(Join-Path $target 'fyndkoll.ico'),0"
    $sc.Description = 'Fyndkoll - bevakar SweClockers fyndtradar'
    $sc.Save()
    Write-Host ""
    Write-Host "Autostart pekar nu pa den lokala kopian:"
    Write-Host "  $startupLink"
}

Write-Host ""
Write-Host "Startar appen..."
Start-Process wscript.exe -ArgumentList """$(Join-Path $target 'Start-Fyndkoll.vbs')""" -WindowStyle Hidden
Start-Sleep -Seconds 4

$mine = $PID
$now = @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" |
    Where-Object { $_.ProcessId -ne $mine -and $_.CommandLine -like '*Fyndkoll-Tray.ps1*' })
if ($now.Count) {
    Write-Host "Klart - Fyndkoll kor (PID $($now[0].ProcessId))."
}
else {
    Write-Warning "Appen verkar inte ha startat. Kolla $env:LOCALAPPDATA\Fyndkoll\fyndkoll.log"
}
