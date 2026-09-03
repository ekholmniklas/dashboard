# Fyndkoll - tray watcher for the SweClockers fynd threads.
#
# Sits in the notification area. Every few minutes it checks both threads; when
# something new turns up it shows a notification and blinks the tray icon until
# you look at it. Left-click lists the unread finds, click one to open it.
#
# Nothing to install: Windows PowerShell, .NET WinForms and curl.exe are all
# already on the machine. Start it with Start-Fyndkoll.vbs (no console window).

[CmdletBinding()]
param(
    # Minutes between checks. Persisted, so you only need to pass it once.
    [int]$IntervalMinutes = 0
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

. (Join-Path $PSScriptRoot 'FyndParse.ps1')

# ---------------------------------------------------------------- state -------

$script:DataDir = Join-Path $env:LOCALAPPDATA 'Fyndkoll'
$script:StatePath = Join-Path $script:DataDir 'state.json'
$script:LogPath = Join-Path $script:DataDir 'fyndkoll.log'
$script:ModulePath = Join-Path $PSScriptRoot 'FyndParse.ps1'

if (-not (Test-Path $script:DataDir)) { New-Item -ItemType Directory -Path $script:DataDir -Force | Out-Null }

function Write-FyndLog {
    param([string]$Message)
    $line = "{0}  {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message
    try { Add-Content -Path $script:LogPath -Value $line -Encoding UTF8 } catch {}
}

function Get-FyndState {
    if (Test-Path $script:StatePath) {
        try {
            $raw = Get-Content $script:StatePath -Raw -Encoding UTF8
            $obj = $raw | ConvertFrom-Json
            if ($obj) { return $obj }
        }
        catch { Write-FyndLog "state unreadable, starting fresh: $($_.Exception.Message)" }
    }
    [pscustomobject]@{
        lastSeen        = [pscustomobject]@{}
        intervalMinutes = 15
        unread          = @()
        seeded          = $false
    }
}

function Save-FyndState {
    param($State)
    try {
        $State | ConvertTo-Json -Depth 6 | Set-Content -Path $script:StatePath -Encoding UTF8
    }
    catch { Write-FyndLog "could not save state: $($_.Exception.Message)" }
}

function Get-LastSeenFor {
    param($State, [int64]$ThreadId)
    $prop = $State.lastSeen.PSObject.Properties[[string]$ThreadId]
    if ($prop) { return [int64]$prop.Value }
    return [int64]0
}

function Set-LastSeenFor {
    param($State, [int64]$ThreadId, [int64]$PostId)
    $key = [string]$ThreadId
    if ($State.lastSeen.PSObject.Properties[$key]) { $State.lastSeen.$key = $PostId }
    else { $State.lastSeen | Add-Member -NotePropertyName $key -NotePropertyValue $PostId }
}

$script:State = Get-FyndState
if ($IntervalMinutes -gt 0) { $script:State.intervalMinutes = $IntervalMinutes }
if (-not $script:State.intervalMinutes -or $script:State.intervalMinutes -lt 1) { $script:State.intervalMinutes = 15 }

# ---------------------------------------------------------------- icons -------

$script:ColorIdle = [System.Drawing.ColorTranslator]::FromHtml('#5D5958')
$script:ColorAlert = [System.Drawing.ColorTranslator]::FromHtml('#F3994E')

function New-FyndIcon {
    param([System.Drawing.Color]$Background, [System.Drawing.Color]$Foreground)

    $bmp = New-Object System.Drawing.Bitmap 32, 32
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $g.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::AntiAlias
    $g.Clear([System.Drawing.Color]::Transparent)

    $bg = New-Object System.Drawing.SolidBrush $Background
    $g.FillEllipse($bg, 0, 0, 31, 31)

    $font = New-Object System.Drawing.Font 'Segoe UI', 14, ([System.Drawing.FontStyle]::Bold), ([System.Drawing.GraphicsUnit]::Pixel)
    $fg = New-Object System.Drawing.SolidBrush $Foreground
    $fmt = New-Object System.Drawing.StringFormat
    $fmt.Alignment = [System.Drawing.StringAlignment]::Center
    $fmt.LineAlignment = [System.Drawing.StringAlignment]::Center
    $rect = New-Object System.Drawing.RectangleF 0, 1, 32, 32
    $g.DrawString('kr', $font, $fg, $rect, $fmt)

    $bg.Dispose(); $fg.Dispose(); $font.Dispose(); $fmt.Dispose(); $g.Dispose()
    $icon = [System.Drawing.Icon]::FromHandle($bmp.GetHicon())
    $bmp.Dispose()
    $icon
}

$script:IconIdle = New-FyndIcon -Background $script:ColorIdle -Foreground ([System.Drawing.Color]::White)
$script:IconAlert = New-FyndIcon -Background $script:ColorAlert -Foreground ([System.Drawing.Color]::FromArgb(40, 25, 10))

# ------------------------------------------------------------------ tray ------

$script:Notify = New-Object System.Windows.Forms.NotifyIcon
$script:Notify.Icon = $script:IconIdle
$script:Notify.Text = 'Fyndkoll'
$script:Notify.Visible = $true

$script:Menu = New-Object System.Windows.Forms.ContextMenuStrip
$script:Notify.ContextMenuStrip = $script:Menu

$script:AppContext = New-Object System.Windows.Forms.ApplicationContext
$script:Blinking = $false
$script:BlinkOn = $false
$script:Checking = $false
$script:Pending = $null
$script:LastError = $null
$script:LastCheck = $null

function Set-TrayTooltip {
    $unread = @($script:State.unread).Count
    $parts = @('Fyndkoll')
    if ($unread -gt 0) { $parts += "$unread nya fynd" }
    if ($script:LastCheck) { $parts += "kollat $($script:LastCheck.ToString('HH:mm'))" }
    else { $parts += 'inte kollat än' }
    if ($script:LastError) { $parts += "fel: $($script:LastError)" }
    $text = $parts -join ' - '
    # NotifyIcon.Text throws above 63 characters.
    if ($text.Length -gt 63) { $text = $text.Substring(0, 60) + '...' }
    $script:Notify.Text = $text
}

function Start-Blink {
    if ($script:Blinking) { return }
    $script:Blinking = $true
    $script:BlinkTimer.Start()
}

function Stop-Blink {
    $script:Blinking = $false
    $script:BlinkTimer.Stop()
    $script:Notify.Icon = $script:IconIdle
}

function Open-Url {
    param([string]$Url)
    if ([string]::IsNullOrWhiteSpace($Url)) { return }
    try { Start-Process $Url } catch { Write-FyndLog "could not open $Url : $($_.Exception.Message)" }
}

function Clear-Unread {
    $script:State.unread = @()
    Save-FyndState -State $script:State
    Stop-Blink
    Set-TrayTooltip
}

# --------------------------------------------------------------- checking -----

<#
The fetch runs in its own runspace so the tray stays responsive. A watchdog
timer picks up the result; the runspace returns JSON to keep marshalling simple.
#>
function Start-FyndCheck {
    if ($script:Checking) { return }
    $script:Checking = $true
    Set-TrayTooltip

    $seen = @{}
    foreach ($t in $script:FyndThreads) { $seen[[string]$t.Id] = Get-LastSeenFor -State $script:State -ThreadId $t.Id }

    $runspace = [runspacefactory]::CreateRunspace()
    $runspace.ApartmentState = 'MTA'
    $runspace.Open()
    $shell = [powershell]::Create()
    $shell.Runspace = $runspace
    [void]$shell.AddScript({
            param($ModulePath, $Seen)
            . $ModulePath
            $out = @{ posts = @(); errors = @() }
            foreach ($t in $script:FyndThreads) {
                try {
                    $last = [int64]$Seen[[string]$t.Id]
                    $posts = @(Get-FyndThreadPosts -Thread $t -LastSeen $last)
                    $out.posts += $posts
                }
                catch {
                    $out.errors += "$($t.Label): $($_.Exception.Message)"
                }
            }
            $out | ConvertTo-Json -Depth 6 -Compress
        }).AddArgument($script:ModulePath).AddArgument($seen)

    $script:Pending = [pscustomobject]@{
        Shell    = $shell
        Runspace = $runspace
        Handle   = $shell.BeginInvoke()
    }
    $script:WatchTimer.Start()
}

function Complete-FyndCheck {
    $pending = $script:Pending
    if (-not $pending) { return }

    $script:WatchTimer.Stop()
    $script:Pending = $null
    $script:Checking = $false

    $json = $null
    try {
        $result = $pending.Shell.EndInvoke($pending.Handle)
        $json = ($result | Where-Object { $_ } | Select-Object -First 1)
    }
    catch {
        $script:LastError = $_.Exception.Message
        Write-FyndLog "check failed: $($_.Exception.Message)"
    }
    finally {
        try { $pending.Shell.Dispose() } catch {}
        try { $pending.Runspace.Dispose() } catch {}
    }

    if (-not $json) { Set-TrayTooltip; return }

    $payload = $null
    try { $payload = $json | ConvertFrom-Json } catch {
        $script:LastError = 'kunde inte tolka svaret'
        Set-TrayTooltip
        return
    }

    $errors = @($payload.errors)
    $posts = @($payload.posts)

    if ($posts.Count -eq 0 -and $errors.Count -gt 0) {
        $script:LastError = ($errors -join '; ')
        Write-FyndLog "all threads failed: $($script:LastError)"
        Set-TrayTooltip
        return
    }

    $script:LastError = if ($errors.Count -gt 0) { $errors -join '; ' } else { $null }
    $script:LastCheck = Get-Date

    $isFirstRun = -not $script:State.seeded
    $fresh = @()

    foreach ($t in $script:FyndThreads) {
        $mine = @($posts | Where-Object { $_.ThreadId -eq $t.Id })
        if ($mine.Count -eq 0) { continue }
        $last = Get-LastSeenFor -State $script:State -ThreadId $t.Id
        if ($last -gt 0) { $fresh += @($mine | Where-Object { $_.PostId -gt $last }) }
        $highest = ($mine | Measure-Object -Property PostId -Maximum).Maximum
        if ($highest -gt $last) { Set-LastSeenFor -State $script:State -ThreadId $t.Id -PostId $highest }
    }

    $script:State.seeded = $true

    if ($isFirstRun) {
        # Do not fire 35 notifications for posts that were already there.
        Write-FyndLog "seeded with $($posts.Count) existing posts"
        Save-FyndState -State $script:State
        $script:Notify.ShowBalloonTip(6000, 'Fyndkoll bevakar nu', "Läste in $($posts.Count) befintliga inlägg. Du får en notis när något nytt postas.", [System.Windows.Forms.ToolTipIcon]::Info)
        Set-TrayTooltip
        return
    }

    if ($fresh.Count -eq 0) {
        Write-FyndLog 'no new posts'
        Save-FyndState -State $script:State
        Set-TrayTooltip
        return
    }

    $fresh = @($fresh | Sort-Object PostId -Descending)
    Write-FyndLog "$($fresh.Count) new post(s): $(($fresh | ForEach-Object { $_.Title }) -join ' | ')"

    $script:State.unread = @(@($fresh) + @($script:State.unread) | Sort-Object PostId -Descending -Unique | Select-Object -First 40)
    Save-FyndState -State $script:State

    $newest = $fresh[0]
    if ($fresh.Count -eq 1) {
        $body = @($newest.Price, $newest.Category, $newest.Store) | Where-Object { $_ }
        $text = ($body -join ' - ')
        if ($newest.Note) { $text = $text + "`n" + $newest.Note }
        if ($text.Length -gt 250) { $text = $text.Substring(0, 250) + '...' }
        $script:Notify.ShowBalloonTip(15000, "FYND - $($newest.Title)", $text, [System.Windows.Forms.ToolTipIcon]::Info)
    }
    else {
        $lines = @($fresh | Select-Object -First 5 | ForEach-Object {
                if ($_.Price) { "$($_.Price) - $($_.Title)" } else { $_.Title }
            })
        $script:Notify.ShowBalloonTip(15000, "$($fresh.Count) nya fynd", ($lines -join "`n"), [System.Windows.Forms.ToolTipIcon]::Info)
    }

    Start-Blink
    Set-TrayTooltip
}

# ------------------------------------------------------------------ menu ------

function Build-Menu {
    $script:Menu.Items.Clear()

    $unread = @($script:State.unread)
    if ($unread.Count -gt 0) {
        $header = New-Object System.Windows.Forms.ToolStripMenuItem "$($unread.Count) nya fynd"
        $header.Enabled = $false
        [void]$script:Menu.Items.Add($header)

        foreach ($find in @($unread | Select-Object -First 12)) {
            $label = $find.Title
            if ($find.Price) { $label = "$($find.Price)  -  $($find.Title)" }
            if ($label.Length -gt 70) { $label = $label.Substring(0, 70) + '...' }
            $item = New-Object System.Windows.Forms.ToolStripMenuItem $label
            $tooltipParts = @($find.ThreadLabel, $find.Store, $find.Note) | Where-Object { $_ }
            $item.ToolTipText = ($tooltipParts -join "`n")
            # Prefer the shop; fall back to the forum post.
            $target = $find.DealLink
            if (-not $target) { $target = $find.Permalink }
            $post = $find.Permalink
            $item.Add_Click({
                    Open-Url -Url $this.Tag
                    Clear-Unread
                }.GetNewClosure())
            $item.Tag = $target
            $sub = New-Object System.Windows.Forms.ToolStripMenuItem 'Visa inlägget'
            $sub.Tag = $post
            $sub.Add_Click({ Open-Url -Url $this.Tag }.GetNewClosure())
            [void]$item.DropDownItems.Add($sub)
            [void]$script:Menu.Items.Add($item)
        }

        $markRead = New-Object System.Windows.Forms.ToolStripMenuItem 'Markera alla som lästa'
        $markRead.Add_Click({ Clear-Unread })
        [void]$script:Menu.Items.Add($markRead)
        [void]$script:Menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))
    }
    else {
        $idle = New-Object System.Windows.Forms.ToolStripMenuItem 'Inga nya fynd'
        $idle.Enabled = $false
        [void]$script:Menu.Items.Add($idle)
        [void]$script:Menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))
    }

    $check = New-Object System.Windows.Forms.ToolStripMenuItem 'Kolla nu'
    $check.Enabled = -not $script:Checking
    $check.Add_Click({ Start-FyndCheck })
    [void]$script:Menu.Items.Add($check)

    $threads = New-Object System.Windows.Forms.ToolStripMenuItem 'Öppna tråd'
    foreach ($t in $script:FyndThreads) {
        $ti = New-Object System.Windows.Forms.ToolStripMenuItem $t.Label
        $ti.Tag = (Get-FyndLastPageUrl $t)
        $ti.Add_Click({ Open-Url -Url $this.Tag }.GetNewClosure())
        [void]$threads.DropDownItems.Add($ti)
    }
    [void]$script:Menu.Items.Add($threads)

    $interval = New-Object System.Windows.Forms.ToolStripMenuItem "Intervall ($($script:State.intervalMinutes) min)"
    foreach ($m in @(5, 10, 15, 30, 60)) {
        $mi = New-Object System.Windows.Forms.ToolStripMenuItem "$m min"
        $mi.Checked = ($m -eq $script:State.intervalMinutes)
        $mi.Tag = $m
        $mi.Add_Click({
                $script:State.intervalMinutes = [int]$this.Tag
                $script:PollTimer.Interval = [int]$this.Tag * 60000
                $script:PollTimer.Stop(); $script:PollTimer.Start()
                Save-FyndState -State $script:State
                Set-TrayTooltip
            }.GetNewClosure())
        [void]$interval.DropDownItems.Add($mi)
    }
    [void]$script:Menu.Items.Add($interval)

    $startup = New-Object System.Windows.Forms.ToolStripMenuItem 'Starta med Windows'
    $startup.Checked = (Test-Path $script:StartupLink)
    $startup.Add_Click({
            if (Test-Path $script:StartupLink) { Remove-Item $script:StartupLink -Force }
            else { New-StartupShortcut }
        })
    [void]$script:Menu.Items.Add($startup)

    $log = New-Object System.Windows.Forms.ToolStripMenuItem 'Visa logg'
    $log.Add_Click({ if (Test-Path $script:LogPath) { Start-Process notepad.exe $script:LogPath } })
    [void]$script:Menu.Items.Add($log)

    [void]$script:Menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))

    $quit = New-Object System.Windows.Forms.ToolStripMenuItem 'Avsluta'
    $quit.Add_Click({
            $script:Notify.Visible = $false
            $script:AppContext.ExitThread()
        })
    [void]$script:Menu.Items.Add($quit)
}

# --------------------------------------------------------------- startup ------

$script:StartupLink = Join-Path ([Environment]::GetFolderPath('Startup')) 'Fyndkoll.lnk'

function New-StartupShortcut {
    try {
        $vbs = Join-Path $PSScriptRoot 'Start-Fyndkoll.vbs'
        $shell = New-Object -ComObject WScript.Shell
        $sc = $shell.CreateShortcut($script:StartupLink)
        $sc.TargetPath = 'wscript.exe'
        $sc.Arguments = """$vbs"""
        $sc.WorkingDirectory = $PSScriptRoot
        $sc.Description = 'Fyndkoll - bevakar SweClockers fyndtrådar'
        $sc.Save()
        Write-FyndLog "startup shortcut created at $script:StartupLink"
    }
    catch { Write-FyndLog "could not create startup shortcut: $($_.Exception.Message)" }
}

# ---------------------------------------------------------------- timers ------

$script:PollTimer = New-Object System.Windows.Forms.Timer
$script:PollTimer.Interval = [int]$script:State.intervalMinutes * 60000
$script:PollTimer.Add_Tick({ Start-FyndCheck })

$script:WatchTimer = New-Object System.Windows.Forms.Timer
$script:WatchTimer.Interval = 400
$script:WatchTimer.Add_Tick({
        if ($script:Pending -and $script:Pending.Handle.IsCompleted) { Complete-FyndCheck }
    })

$script:BlinkTimer = New-Object System.Windows.Forms.Timer
$script:BlinkTimer.Interval = 650
$script:BlinkTimer.Add_Tick({
        $script:BlinkOn = -not $script:BlinkOn
        if ($script:BlinkOn) { $script:Notify.Icon = $script:IconAlert }
        else { $script:Notify.Icon = $script:IconIdle }
    })

# ---------------------------------------------------------------- events ------

$script:Menu.Add_Opening({ Build-Menu })

$script:Notify.Add_BalloonTipClicked({
        $first = @($script:State.unread) | Select-Object -First 1
        if ($first) {
            $target = $first.DealLink
            if (-not $target) { $target = $first.Permalink }
            Open-Url -Url $target
        }
        Clear-Unread
    })

# Left-click opens the same menu as right-click, so the unread list is one click away.
# Showing it at the cursor uses the public API; the Opening event fills it in.
$script:Notify.Add_MouseUp({
        if ($_.Button -eq [System.Windows.Forms.MouseButtons]::Left) {
            Stop-Blink
            $script:Menu.Show([System.Windows.Forms.Cursor]::Position)
        }
    })

# ------------------------------------------------------------------ main ------

$script:Mutex = New-Object System.Threading.Mutex($false, 'Global\FyndkollTray')
if (-not $script:Mutex.WaitOne(0, $false)) {
    [System.Windows.Forms.MessageBox]::Show('Fyndkoll körs redan.', 'Fyndkoll') | Out-Null
    return
}

Write-FyndLog "started (interval $($script:State.intervalMinutes) min)"
Set-TrayTooltip
$script:PollTimer.Start()
Start-FyndCheck

try {
    [System.Windows.Forms.Application]::Run($script:AppContext)
}
finally {
    Write-FyndLog 'stopped'
    try { $script:Notify.Visible = $false; $script:Notify.Dispose() } catch {}
    try { $script:Mutex.ReleaseMutex() } catch {}
}
