# Fyndkoll - watches the SweClockers fynd threads.
#
# Keeps a taskbar button (next to Word, Excel and the rest) plus a tray icon.
# Every ten minutes it checks both threads; when something new turns up the
# taskbar button says "KAMPANJ!" and flashes, the tray icon blinks between a grey
# "kr" and a hot pink "%", and a notification appears. The flashing continues
# until the window is brought to the foreground.
#
# The window lists the finds. Hovering a row shows the whole post; double-click
# opens the fynd post, Ctrl+double-click (or Ctrl+Enter) goes to the shop.
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
        intervalMinutes = 10
        unread          = @()
        recent          = @()
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
# 'recent' was added after the first release; older state files will not have it.
if (-not $script:State.PSObject.Properties['recent']) {
    $script:State | Add-Member -NotePropertyName recent -NotePropertyValue @()
}
if ($IntervalMinutes -gt 0) { $script:State.intervalMinutes = $IntervalMinutes }
if (-not $script:State.intervalMinutes -or $script:State.intervalMinutes -lt 1) { $script:State.intervalMinutes = 10 }

# ---------------------------------------------------------------- icons -------

$script:ColorIdle = [System.Drawing.ColorTranslator]::FromHtml('#5D5958')
# Kampanj-rosa, som på skyltarna i butik.
$script:ColorAlert = [System.Drawing.ColorTranslator]::FromHtml('#D6004F')

<#
Tray icons are 16x16 once Windows is done with them, so a word like "KAMPANJ"
is unreadable. The glyph carries the state instead: a calm grey "kr" normally,
a hot pink "%" when there is something to look at. The word itself goes where
there is room for it - the taskbar button and the notification.
#>
function New-FyndIcon {
    param(
        [System.Drawing.Color]$Background,
        [System.Drawing.Color]$Foreground,
        [string]$Glyph = 'kr',
        [int]$FontSize = 14
    )

    $bmp = New-Object System.Drawing.Bitmap 32, 32
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $g.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::AntiAlias
    $g.Clear([System.Drawing.Color]::Transparent)

    $bg = New-Object System.Drawing.SolidBrush $Background
    $g.FillEllipse($bg, 0, 0, 31, 31)

    $font = New-Object System.Drawing.Font 'Segoe UI', $FontSize, ([System.Drawing.FontStyle]::Bold), ([System.Drawing.GraphicsUnit]::Pixel)
    $fg = New-Object System.Drawing.SolidBrush $Foreground
    $fmt = New-Object System.Drawing.StringFormat
    $fmt.Alignment = [System.Drawing.StringAlignment]::Center
    $fmt.LineAlignment = [System.Drawing.StringAlignment]::Center
    $rect = New-Object System.Drawing.RectangleF 0, 1, 32, 32
    $g.DrawString($Glyph, $font, $fg, $rect, $fmt)

    $bg.Dispose(); $fg.Dispose(); $font.Dispose(); $fmt.Dispose(); $g.Dispose()
    $icon = [System.Drawing.Icon]::FromHandle($bmp.GetHicon())
    $bmp.Dispose()
    $icon
}

$script:IconIdle = New-FyndIcon -Background $script:ColorIdle -Foreground ([System.Drawing.Color]::White) -Glyph 'kr' -FontSize 14
$script:IconAlert = New-FyndIcon -Background $script:ColorAlert -Foreground ([System.Drawing.Color]::White) -Glyph '%' -FontSize 19

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
    if ($script:Form -and -not $script:Form.IsDisposed) { Update-Window }
}

# ---------------------------------------------------------------- window ------

# FlashWindowEx is what makes a taskbar button pulse orange. FLASHW_TIMERNOFG
# keeps it pulsing until the window is actually brought to the foreground, which
# is the behaviour we want: it should not stop until it has been looked at.
if (-not ('FyndkollFlash' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

public static class FyndkollFlash
{
    [StructLayout(LayoutKind.Sequential)]
    private struct FLASHWINFO
    {
        public uint cbSize;
        public IntPtr hwnd;
        public uint dwFlags;
        public uint uCount;
        public uint dwTimeout;
    }

    [DllImport("user32.dll")]
    private static extern bool FlashWindowEx(ref FLASHWINFO pwfi);

    private const uint FLASHW_STOP = 0;
    private const uint FLASHW_ALL = 3;
    private const uint FLASHW_TIMERNOFG = 12;

    private static bool Flash(IntPtr handle, uint flags, uint count)
    {
        FLASHWINFO info = new FLASHWINFO();
        info.cbSize = (uint)Marshal.SizeOf(typeof(FLASHWINFO));
        info.hwnd = handle;
        info.dwFlags = flags;
        info.uCount = count;
        info.dwTimeout = 0;
        return FlashWindowEx(ref info);
    }

    public static void Start(IntPtr handle) { Flash(handle, FLASHW_ALL | FLASHW_TIMERNOFG, uint.MaxValue); }
    public static void Stop(IntPtr handle) { Flash(handle, FLASHW_STOP, 0); }
}
'@
}

$script:Form = New-Object System.Windows.Forms.Form
$script:Form.Text = 'Fyndkoll'
$script:Form.Icon = $script:IconIdle
$script:Form.Size = New-Object System.Drawing.Size 980, 460
$script:Form.MinimumSize = New-Object System.Drawing.Size 520, 260
$script:Form.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterScreen
$script:Form.ShowInTaskbar = $true

# Row colours. Unread finds get a solid green whatever their age; everything else
# is shaded by how old the post is, so freshness is readable at a glance.
$script:ColorNewBack = [System.Drawing.ColorTranslator]::FromHtml('#8FE3A6')
$script:ColorNewText = [System.Drawing.ColorTranslator]::FromHtml('#0B4A1D')

# Upper bound in days (inclusive) -> background, foreground.
$script:AgeBands = @(
    [pscustomobject]@{ MaxDays = 0;  Back = '#EAF9EE'; Text = '#24492F'; Label = 'Idag' }
    [pscustomobject]@{ MaxDays = 2;  Back = '#E6F1FC'; Text = '#1C3B57'; Label = '1-2 d' }
    [pscustomobject]@{ MaxDays = 8;  Back = '#FDF6D9'; Text = '#544612'; Label = '3-8 d' }
    [pscustomobject]@{ MaxDays = 20; Back = '#FBE4E8'; Text = '#5E2028'; Label = '9-20 d' }
    [pscustomobject]@{ MaxDays = [int]::MaxValue; Back = '#F3B6BD'; Text = '#6B1220'; Label = '21+ d' }
)

function Get-AgeBand {
    param([int]$AgeDays)
    foreach ($band in $script:AgeBands) {
        if ($AgeDays -le $band.MaxDays) { return $band }
    }
    $script:AgeBands[-1]
}

$script:List = New-Object System.Windows.Forms.ListView
$script:List.View = [System.Windows.Forms.View]::Details
$script:List.FullRowSelect = $true
$script:List.GridLines = $false
$script:List.Dock = [System.Windows.Forms.DockStyle]::Fill
[void]$script:List.Columns.Add('Pris', 85)
[void]$script:List.Columns.Add('Fynd', 300)
[void]$script:List.Columns.Add('Kategori', 115)
[void]$script:List.Columns.Add('Datum', 85)
[void]$script:List.Columns.Add('Tid', 50)
[void]$script:List.Columns.Add('Butik', 130)
[void]$script:List.Columns.Add('Tråd', 95)

$script:Status = New-Object System.Windows.Forms.StatusStrip
$script:StatusLabel = New-Object System.Windows.Forms.ToolStripStatusLabel
[void]$script:Status.Items.Add($script:StatusLabel)

$script:Bar = New-Object System.Windows.Forms.ToolStrip
$script:Bar.GripStyle = [System.Windows.Forms.ToolStripGripStyle]::Hidden
$script:Bar.RenderMode = [System.Windows.Forms.ToolStripRenderMode]::System

$script:RefreshButton = New-Object System.Windows.Forms.ToolStripButton
$script:RefreshButton.Text = 'Uppdatera'
$script:RefreshButton.DisplayStyle = [System.Windows.Forms.ToolStripItemDisplayStyle]::Text
$script:RefreshButton.ToolTipText = 'Kolla trådarna nu'
$script:RefreshButton.Add_Click({ Start-FyndCheck })
[void]$script:Bar.Items.Add($script:RefreshButton)

[void]$script:Bar.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))

$script:MarkReadButton = New-Object System.Windows.Forms.ToolStripButton
$script:MarkReadButton.Text = 'Markera alla som lästa'
$script:MarkReadButton.DisplayStyle = [System.Windows.Forms.ToolStripItemDisplayStyle]::Text
$script:MarkReadButton.Add_Click({ Clear-Unread })
[void]$script:Bar.Items.Add($script:MarkReadButton)

[void]$script:Bar.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))

# Coloured chips beat explaining the scale in words.
function Add-LegendChip {
    param([string]$Text, [string]$Back, [string]$Fore, [bool]$Bold = $false)
    $chip = New-Object System.Windows.Forms.ToolStripLabel
    $chip.Text = " $Text "
    $chip.BackColor = [System.Drawing.ColorTranslator]::FromHtml($Back)
    $chip.ForeColor = [System.Drawing.ColorTranslator]::FromHtml($Fore)
    $chip.Margin = New-Object System.Windows.Forms.Padding 0, 3, 3, 3
    if ($Bold) {
        $chip.Font = New-Object System.Drawing.Font $script:Bar.Font, ([System.Drawing.FontStyle]::Bold)
    }
    [void]$script:Bar.Items.Add($chip)
}

Add-LegendChip -Text 'Nytt' -Back '#8FE3A6' -Fore '#0B4A1D' -Bold $true
foreach ($band in $script:AgeBands) {
    Add-LegendChip -Text $band.Label -Back $band.Back -Fore $band.Text
}

# Order matters and is the opposite of what you would guess: docking is resolved
# last-added-first, so the Fill control has to go in FIRST or it claims the whole
# client area and the toolbar ends up drawn on top of the list.
$script:Form.Controls.Add($script:List)
$script:Form.Controls.Add($script:Status)
$script:Form.Controls.Add($script:Bar)

function Update-Window {
    $script:List.BeginUpdate()
    try {
        $script:List.Items.Clear()
        $unreadIds = @(@($script:State.unread) | ForEach-Object { $_.PostId })
        foreach ($find in @($script:State.recent)) {
            $price = $find.Price
            if (-not $price) { $price = '' }
            $item = New-Object System.Windows.Forms.ListViewItem $price
            [void]$item.SubItems.Add($find.Title)
            $category = $find.Category
            if (-not $category) { $category = '' }
            [void]$item.SubItems.Add($category)
            $day = ''
            $stamp = ''
            $ageDays = -1
            if ($find.CreatedAt -gt 0) {
                $when = [DateTimeOffset]::FromUnixTimeSeconds([int64]$find.CreatedAt).ToLocalTime()
                $day = $when.ToString('yyyy-MM-dd')
                $stamp = $when.ToString('HH:mm')
                # Whole calendar days, so "igår" is 1 regardless of the clock.
                $ageDays = [int]((Get-Date).Date - $when.Date).TotalDays
            }
            [void]$item.SubItems.Add($day)
            [void]$item.SubItems.Add($stamp)
            $store = $find.Store
            if (-not $store) { $store = '' }
            [void]$item.SubItems.Add($store)
            [void]$item.SubItems.Add($find.ThreadLabel)
            # Unread wins over age: it is the one thing you have not looked at yet.
            if ($unreadIds -contains $find.PostId) {
                $item.BackColor = $script:ColorNewBack
                $item.ForeColor = $script:ColorNewText
                $item.Font = New-Object System.Drawing.Font $script:List.Font, ([System.Drawing.FontStyle]::Bold)
            }
            elseif ($ageDays -ge 0) {
                $band = Get-AgeBand -AgeDays $ageDays
                $item.BackColor = [System.Drawing.ColorTranslator]::FromHtml($band.Back)
                $item.ForeColor = [System.Drawing.ColorTranslator]::FromHtml($band.Text)
            }
            $shop = $find.DealLink
            if (-not $shop) { $shop = $find.Permalink }
            # Hovering shows the post as written; fall back to the trailing note
            # for state saved before FullText existed.
            $hover = $find.FullText
            if (-not $hover) { $hover = $find.Note }
            $header = @($find.Title, $find.Price) | Where-Object { $_ }
            $meta = @($find.ThreadLabel, $find.Author) | Where-Object { $_ }
            $tip = (@(($header -join '  -  '), ($meta -join ' · '), '', $hover) | Where-Object { $null -ne $_ }) -join "`n"
            $item.Tag = [pscustomobject]@{ Post = $find.Permalink; Shop = $shop; Tip = $tip.Trim() }
            [void]$script:List.Items.Add($item)
        }
    }
    finally { $script:List.EndUpdate() }

    $bits = @()
    if ($script:LastCheck) { $bits += "Senast kollat $($script:LastCheck.ToString('HH:mm:ss'))" }
    else { $bits += 'Inte kollat än' }
    $bits += "var $($script:State.intervalMinutes) min"
    $unread = @($script:State.unread).Count
    if ($unread -gt 0) { $bits += "$unread olästa" }
    if ($script:LastError) { $bits += "fel: $($script:LastError)" }
    $script:StatusLabel.Text = ($bits -join '  ·  ')
    Update-Bar

    # The taskbar button is where there is actually room for a word, so that is
    # where "KAMPANJ!" goes. It sits right next to Word and Excel and is hard to
    # miss when it is also flashing.
    if ($unread -gt 0) {
        $script:Form.Text = "KAMPANJ! $unread nya fynd"
        $script:Form.Icon = $script:IconAlert
    }
    else {
        $script:Form.Text = 'Fyndkoll'
        $script:Form.Icon = $script:IconIdle
    }
}

function Update-Bar {
    if (-not $script:RefreshButton) { return }
    $script:RefreshButton.Enabled = -not $script:Checking
    if ($script:Checking) { $script:RefreshButton.Text = 'Uppdaterar...' }
    else { $script:RefreshButton.Text = 'Uppdatera' }
    $script:MarkReadButton.Enabled = (@($script:State.unread).Count -gt 0)
}

function Start-Flash {
    try { [FyndkollFlash]::Start($script:Form.Handle) } catch {}
}

function Stop-Flash {
    try { [FyndkollFlash]::Stop($script:Form.Handle) } catch {}
}

function Show-FyndWindow {
    Stop-Flash
    Stop-Blink
    Update-Window
    $script:Form.Show()
    if ($script:Form.WindowState -eq [System.Windows.Forms.FormWindowState]::Minimized) {
        $script:Form.WindowState = [System.Windows.Forms.FormWindowState]::Normal
    }
    [void]$script:Form.Activate()
    $script:Form.BringToFront()
}

# Double-click goes to the fynd post itself - that has the full tip, the poster's
# comment and any replies. Ctrl+double-click (or Ctrl+Enter) jumps to the shop.
$script:List.Add_DoubleClick({
        $sel = @($script:List.SelectedItems)
        if ($sel.Count -eq 0) { return }
        if ([System.Windows.Forms.Control]::ModifierKeys -band [System.Windows.Forms.Keys]::Control) {
            Open-Url -Url $sel[0].Tag.Shop
        }
        else {
            Open-Url -Url $sel[0].Tag.Post
        }
    })

$script:List.Add_KeyDown({
        if ($_.KeyCode -eq [System.Windows.Forms.Keys]::Return) {
            $sel = @($script:List.SelectedItems)
            if ($sel.Count -gt 0) {
                if ($_.Control) { Open-Url -Url $sel[0].Tag.Shop } else { Open-Url -Url $sel[0].Tag.Post }
            }
        }
    })

# A ToolTip shown by hand rather than ListView's own ShowItemToolTips, because
# the built-in one clips long text and these posts are the whole point.
$script:Tooltip = New-Object System.Windows.Forms.ToolTip
$script:Tooltip.InitialDelay = 350
$script:Tooltip.ReshowDelay = 100
$script:Tooltip.AutoPopDelay = 32000
$script:Tooltip.ShowAlways = $true
$script:TooltipFor = -1

$script:List.Add_MouseMove({
        $hit = $script:List.HitTest($_.X, $_.Y)
        $item = $hit.Item
        if ($null -eq $item) {
            if ($script:TooltipFor -ne -1) {
                $script:Tooltip.Hide($script:List)
                $script:TooltipFor = -1
            }
            return
        }
        if ($item.Index -ne $script:TooltipFor) {
            $script:TooltipFor = $item.Index
            $text = $item.Tag.Tip
            if ($text) { $script:Tooltip.Show($text, $script:List, ($_.X + 18), ($_.Y + 18), 32000) }
        }
    })

$script:List.Add_MouseLeave({
        $script:Tooltip.Hide($script:List)
        $script:TooltipFor = -1
    })

# Closing hides the window instead of quitting; quitting is the tray menu's job.
$script:Form.Add_FormClosing({
        if ($_.CloseReason -eq [System.Windows.Forms.CloseReason]::UserClosing) {
            $_.Cancel = $true
            $script:Form.WindowState = [System.Windows.Forms.FormWindowState]::Minimized
        }
    })

# Looking at the window counts as reading the finds.
$script:Form.Add_Activated({
        Stop-Flash
        Stop-Blink
        if (@($script:State.unread).Count -gt 0) { Clear-Unread }
    })

# --------------------------------------------------------------- checking -----

<#
The fetch runs in its own runspace so the tray stays responsive. A watchdog
timer picks up the result; the runspace returns JSON to keep marshalling simple.
#>
function Start-FyndCheck {
    if ($script:Checking) { return }
    $script:Checking = $true
    Set-TrayTooltip
    Update-Bar

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
    Update-Bar

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

    # Everything the window lists, unread or not.
    $script:State.recent = @($posts | Sort-Object PostId -Descending -Unique | Select-Object -First 40)

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
        $1
    }

    if ($fresh.Count -eq 0) {
        Write-FyndLog 'no new posts'
        Save-FyndState -State $script:State
        Update-Window
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
    Start-Flash
    Update-Window
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
            $hover = $find.FullText
            if (-not $hover) { $hover = $find.Note }
            $item.ToolTipText = ((@($find.ThreadLabel, $find.Store, $hover) | Where-Object { $_ }) -join "`n")
            # The post first - it carries the full tip and any replies.
            $shop = $find.DealLink
            if (-not $shop) { $shop = $find.Permalink }
            $item.Add_Click({
                    Open-Url -Url $this.Tag
                    Clear-Unread
                }.GetNewClosure())
            $item.Tag = $find.Permalink
            $sub = New-Object System.Windows.Forms.ToolStripMenuItem 'Till butiken'
            $sub.Tag = $shop
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

    $show = New-Object System.Windows.Forms.ToolStripMenuItem 'Visa fönster'
    $show.Add_Click({ Show-FyndWindow })
    [void]$script:Menu.Items.Add($show)

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
        if ($first) { Open-Url -Url $first.Permalink }
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

# Shown-but-minimised gives a taskbar button next to Word and Excel, which is
# what actually flashes when a find turns up. Closing it minimises again.
$script:Form.WindowState = [System.Windows.Forms.FormWindowState]::Minimized
$script:Form.Show()
Update-Window

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
