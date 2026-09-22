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

<#
Hide our own console window, first thing.

Task Scheduler allocates a console before PowerShell gets to act on
-WindowStyle Hidden, so a black console window turns up in the taskbar next to
the app. Closing it sends CTRL_CLOSE to the process and kills the app - which is
where the mysterious 0xC000013A exits came from.
#>
if (-not ('FyndkollConsole' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

public static class FyndkollConsole
{
    [DllImport("kernel32.dll")] private static extern IntPtr GetConsoleWindow();
    [DllImport("user32.dll")] private static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);

    private const int SW_HIDE = 0;

    public static bool Hide()
    {
        IntPtr handle = GetConsoleWindow();
        if (handle == IntPtr.Zero) { return false; }
        return ShowWindow(handle, SW_HIDE);
    }
}
'@
}
[void][FyndkollConsole]::Hide()

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

. (Join-Path $PSScriptRoot 'FyndSources.ps1')

# ---------------------------------------------------------------- state -------

$script:DataDir = Join-Path $env:LOCALAPPDATA 'Fyndkoll'
$script:StatePath = Join-Path $script:DataDir 'state.json'
$script:LogPath = Join-Path $script:DataDir 'fyndkoll.log'
$script:ModulePath = Join-Path $PSScriptRoot 'FyndSources.ps1'

if (-not (Test-Path $script:DataDir)) { New-Item -ItemType Directory -Path $script:DataDir -Force | Out-Null }

function Write-FyndLog {
    param([string]$Message)
    $line = "{0}  {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message
    try { Add-Content -Path $script:LogPath -Value $line -Encoding UTF8 } catch {}
}

# Logged before anything heavy happens, so a failure during setup leaves a trace.
# Without this a silent death during startup looked identical to "never launched".
Write-FyndLog "launch: pid $PID from $PSScriptRoot"

# break, not continue: a half-built window is worse than a clean exit, and the
# log line is what makes the difference between "crashed" and "never launched".
trap {
    Write-FyndLog "FATAL: $($_.Exception.GetType().Name): $($_.Exception.Message)"
    Write-FyndLog "  at line $($_.InvocationInfo.ScriptLineNumber): $($_.InvocationInfo.Line.Trim())"
    break
}

<#
An exception on the UI thread - a timer tick, a menu handler, anywhere - would
otherwise terminate the process outright, and with nothing logged the app simply
vanished mid-run. That is what killed it after ten minutes of polling.

This has to run before ANY WinForms control exists, otherwise
SetUnhandledExceptionMode throws "Thread exception mode cannot be changed once
any Controls are created on the thread".
#>
[System.Windows.Forms.Application]::SetUnhandledExceptionMode(
    [System.Windows.Forms.UnhandledExceptionMode]::CatchException)

[System.Windows.Forms.Application]::add_ThreadException({
        param($eventSender, $e)
        try {
            Write-FyndLog "UI-undantag: $($e.Exception.GetType().Name): $($e.Exception.Message)"
            $stack = $e.Exception.StackTrace
            if ($stack) { Write-FyndLog "  $(($stack -split "`n" | Select-Object -First 2) -join ' ')" }
        }
        catch { }
    })

[AppDomain]::CurrentDomain.add_UnhandledException({
        param($eventSender, $e)
        try { Write-FyndLog "FATALT undantag: $($e.ExceptionObject)" } catch { }
    })

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
        seenIds         = [pscustomobject]@{}
        sources         = [pscustomobject]@{}
        muted           = $false
        intervalMinutes = 10
        unread          = @()
        recent          = @()
        filter          = 'all'
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

# Nycklarna är källornas id ('swec-999559', 'pepper-hot'), inte trådnummer, så
# alla källtyper delar samma bokföring.
function Get-LastSeenFor {
    param($State, [string]$SourceId)
    $prop = $State.lastSeen.PSObject.Properties[$SourceId]
    if ($prop) { return [int64]$prop.Value }
    return [int64]0
}

function Set-LastSeenFor {
    param($State, [string]$SourceId, [int64]$PostId)
    if ($State.lastSeen.PSObject.Properties[$SourceId]) { $State.lastSeen.$SourceId = $PostId }
    else { $State.lastSeen | Add-Member -NotePropertyName $SourceId -NotePropertyValue $PostId }
}

<#
RSS-källor kan inte använda högvattenmärke: Pepperdeals id:n växer inte med
tiden, eftersom ett äldre fynd kan bli hett senare och då dyka upp i flödet. För
dem sparas sedda id:n som en mängd istället. Flödet rymmer 30 poster, så 300
sparade id:n räcker med god marginal.
#>
function Get-SeenIdsFor {
    param($State, [string]$SourceId)
    $prop = $State.seenIds.PSObject.Properties[$SourceId]
    if ($prop) { return @($prop.Value) }
    return @()
}

function Set-SeenIdsFor {
    param($State, [string]$SourceId, $Ids)
    $arr = @($Ids | Select-Object -Unique | Select-Object -First 300)
    if ($State.seenIds.PSObject.Properties[$SourceId]) { $State.seenIds.$SourceId = $arr }
    else { $State.seenIds | Add-Member -NotePropertyName $SourceId -NotePropertyValue $arr }
}

# Nya källor är påslagna tills man aktivt bockar ur dem.
function Test-SourceEnabled {
    param($State, [string]$SourceId)
    $prop = $State.sources.PSObject.Properties[$SourceId]
    if ($prop) { return [bool]$prop.Value }
    return $true
}

function Set-SourceEnabled {
    param($State, [string]$SourceId, [bool]$Enabled)
    if ($State.sources.PSObject.Properties[$SourceId]) { $State.sources.$SourceId = $Enabled }
    else { $State.sources | Add-Member -NotePropertyName $SourceId -NotePropertyValue $Enabled }
}

function Get-EnabledSources {
    @($script:FyndSources | Where-Object { Test-SourceEnabled -State $script:State -SourceId $_.Id })
}

$script:State = Get-FyndState
# Fält har tillkommit efterhand; en statefil från en äldre version saknar dem.
foreach ($fld in @(
        @{ Name = 'recent'; Value = @() },
        @{ Name = 'filter'; Value = 'all' },
        @{ Name = 'seenIds'; Value = [pscustomobject]@{} },
        @{ Name = 'sources'; Value = [pscustomobject]@{} },
        @{ Name = 'muted'; Value = $false }
    )) {
    if (-not $script:State.PSObject.Properties[$fld.Name]) {
        $script:State | Add-Member -NotePropertyName $fld.Name -NotePropertyValue $fld.Value
    }
}

<#
Tidigare versioner nycklade lastSeen på trådnummer ("999559"); nu används
källornas id. Utan den här flytten skulle de två ursprungliga trådarna se ut som
att de aldrig lästs, och larma om allt på sista sidan en gång till.
#>
foreach ($old in @(
        @{ From = '999559'; To = 'swec-999559' },
        @{ From = '1465406'; To = 'swec-1465406' }
    )) {
    $p = $script:State.lastSeen.PSObject.Properties[$old.From]
    if ($p -and -not $script:State.lastSeen.PSObject.Properties[$old.To]) {
        $script:State.lastSeen | Add-Member -NotePropertyName $old.To -NotePropertyValue ([int64]$p.Value)
        $script:State.lastSeen.PSObject.Properties.Remove($old.From)
        Write-FyndLog "flyttade lastSeen $($old.From) -> $($old.To)"
    }
}
# Samma sak för raderna som redan ligger sparade.
foreach ($row in (@($script:State.recent) + @($script:State.unread))) {
    if ($row -and $row.PSObject.Properties['ThreadId'] -and "$($row.ThreadId)" -match '^\d+$') {
        $row.ThreadId = "swec-$($row.ThreadId)"
    }
}
if ($IntervalMinutes -gt 0) { $script:State.intervalMinutes = $IntervalMinutes }
if (-not $script:State.intervalMinutes -or $script:State.intervalMinutes -lt 1) { $script:State.intervalMinutes = 10 }

# ---------------------------------------------------------------- icons -------

<#
Without an explicit AppUserModelID, Windows 11 attributes this window to
powershell.exe and shows PowerShell's icon on the taskbar button instead of
ours. This has to run before the first window is created.
#>
if (-not ('FyndkollShell' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

public static class FyndkollShell
{
    [DllImport("shell32.dll", SetLastError = true)]
    private static extern int SetCurrentProcessExplicitAppUserModelID(
        [MarshalAs(UnmanagedType.LPWStr)] string AppID);

    public static void SetAppId(string id)
    {
        try { SetCurrentProcessExplicitAppUserModelID(id); } catch { }
    }
}
'@
}
[FyndkollShell]::SetAppId('Ekholm.Fyndkoll')

$script:ColorAlert = [System.Drawing.ColorTranslator]::FromHtml('#D6004F')

<#
The SweClockers mascot, on grey when idle and on kampanj-red when there is
something new. Multi-size .ico files, so the 16x16 tray version and the larger
taskbar and alt-tab versions are all properly resampled rather than squashed.
Generated from https://www.sweclockers.com/gfx/apple-touch-icon.png
#>
function Get-FyndIcon {
    param([string]$FileName, [System.Drawing.Color]$Fallback)

    $path = Join-Path $PSScriptRoot $FileName
    if (Test-Path $path) {
        try { return New-Object System.Drawing.Icon $path }
        catch { Write-FyndLog "could not load $FileName : $($_.Exception.Message)" }
    }
    # Drawn fallback, so a missing .ico never stops the app from starting.
    $bmp = New-Object System.Drawing.Bitmap 32, 32
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $g.Clear([System.Drawing.Color]::Transparent)
    $brush = New-Object System.Drawing.SolidBrush $Fallback
    $g.FillEllipse($brush, 0, 0, 31, 31)
    $brush.Dispose(); $g.Dispose()
    $icon = [System.Drawing.Icon]::FromHandle($bmp.GetHicon())
    $bmp.Dispose()
    $icon
}

$script:IconIdle = Get-FyndIcon -FileName 'fyndkoll.ico' -Fallback ([System.Drawing.ColorTranslator]::FromHtml('#5D5958'))
$script:IconAlert = Get-FyndIcon -FileName 'fyndkoll-alert.ico' -Fallback $script:ColorAlert

<#
An unread count drawn onto the icon, like a chat app. Every generated icon holds
a GDI handle, so they are cached per (count, size, variant) - the set is small
and bounded because anything above nine collapses to "9+".

The mascot is taken from the PNG masters rather than from the .ico files:
Icon.ToBitmap() garbles PNG-compressed icon frames on .NET Framework and turns
the mascot into coloured noise.
#>
$script:BadgeCache = @{}

function Get-MascotBitmap {
    param([switch]$Alert)

    $key = if ($Alert) { 'png-a' } else { 'png-i' }
    if ($script:BadgeCache.ContainsKey($key)) { return $script:BadgeCache[$key] }

    $name = if ($Alert) { 'mascot-alert.png' } else { 'mascot.png' }
    $path = Join-Path $PSScriptRoot $name
    $bmp = $null
    if (Test-Path $path) {
        try { $bmp = New-Object System.Drawing.Bitmap $path }
        catch { Write-FyndLog "could not load $name : $($_.Exception.Message)" }
    }
    if (-not $bmp) {
        # Last resort: a plain disc, so a badge still renders.
        $bmp = New-Object System.Drawing.Bitmap 256, 256, ([System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
        $g = [System.Drawing.Graphics]::FromImage($bmp)
        $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
        $colour = if ($Alert) { $script:ColorAlert } else { [System.Drawing.ColorTranslator]::FromHtml('#5D5958') }
        $brush = New-Object System.Drawing.SolidBrush $colour
        $g.FillEllipse($brush, 0, 0, 255, 255)
        $brush.Dispose(); $g.Dispose()
    }
    $script:BadgeCache[$key] = $bmp
    $bmp
}

function Get-BadgedIcon {
    param(
        [Parameter(Mandatory)][int]$Count,
        [int]$Size = 32,
        [switch]$Alert
    )

    if ($Count -le 0) { if ($Alert) { return $script:IconAlert } else { return $script:IconIdle } }

    $variant = if ($Alert) { 'a' } else { 'i' }
    $label = if ($Count -gt 9) { '9+' } else { [string]$Count }
    $key = "$variant-$Size-$label"
    if ($script:BadgeCache.ContainsKey($key)) { return $script:BadgeCache[$key] }

    $base = Get-MascotBitmap -Alert:$Alert
    $bmp = New-Object System.Drawing.Bitmap $Size, $Size, ([System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    try {
        $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
        $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
        $g.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::AntiAliasGridFit
        $g.Clear([System.Drawing.Color]::Transparent)

        # The mascot, shrunk a little to leave room for the badge.
        $inset = [int][Math]::Round($Size * 0.12)
        $g.DrawImage($base, (New-Object System.Drawing.Rectangle 0, 0, ($Size - $inset), ($Size - $inset)))

        # Badge: white ring so it reads on both the grey and the red mascot.
        $d = [int][Math]::Round($Size * 0.60)
        $x = $Size - $d
        $y = $Size - $d
        $ring = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::White)
        $g.FillEllipse($ring, $x, $y, ($d - 1), ($d - 1))
        $fill = New-Object System.Drawing.SolidBrush ([System.Drawing.ColorTranslator]::FromHtml('#E01B24'))
        $pad = [Math]::Max(1, [int][Math]::Round($Size * 0.055))
        $g.FillEllipse($fill, ($x + $pad), ($y + $pad), ($d - 1 - 2 * $pad), ($d - 1 - 2 * $pad))

        $fontSize = [Math]::Max(6.0, $d * 0.62)
        if ($label.Length -gt 1) { $fontSize = $fontSize * 0.72 }
        $font = New-Object System.Drawing.Font 'Segoe UI', $fontSize, ([System.Drawing.FontStyle]::Bold), ([System.Drawing.GraphicsUnit]::Pixel)
        $fmt = New-Object System.Drawing.StringFormat
        $fmt.Alignment = [System.Drawing.StringAlignment]::Center
        $fmt.LineAlignment = [System.Drawing.StringAlignment]::Center
        $textRect = New-Object System.Drawing.RectangleF $x, ($y + $pad * 0.2), ($d - 1), ($d - 1)
        $white = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::White)
        $g.DrawString($label, $font, $white, $textRect, $fmt)

        $ring.Dispose(); $fill.Dispose(); $white.Dispose(); $font.Dispose(); $fmt.Dispose()
    }
    finally { $g.Dispose() }

    $icon = [System.Drawing.Icon]::FromHandle($bmp.GetHicon())
    $bmp.Dispose()
    $script:BadgeCache[$key] = $icon
    $icon
}

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
    if ($script:State.muted) { $parts += 'TYST' }
    if ($unread -gt 0) { $parts += "$unread nya fynd" }
    if ($script:LastCheck) { $parts += "kollat $($script:LastCheck.ToString('HH:mm'))" }
    else { $parts += 'inte kollat än' }
    if ($script:LastError) { $parts += "fel: $($script:LastError)" }
    $text = $parts -join ' - '
    # NotifyIcon.Text throws above 63 characters.
    if ($text.Length -gt 63) { $text = $text.Substring(0, 60) + '...' }
    $script:Notify.Text = $text
}

# The resting icon follows the unread count, not the blink state: stopping the
# blink should leave the red mascot, with its count, in place while finds are
# still unread.
function Set-TrayIcon {
    $unread = @($script:State.unread).Count
    if ($unread -gt 0) { $script:Notify.Icon = Get-BadgedIcon -Count $unread -Size 32 -Alert }
    else { $script:Notify.Icon = $script:IconIdle }
}

function Start-Blink {
    if ($script:Blinking) { return }
    $script:Blinking = $true
    $script:BlinkTimer.Start()
}

function Stop-Blink {
    $script:Blinking = $false
    $script:BlinkTimer.Stop()
    Set-TrayIcon
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
[void]$script:List.Columns.Add('Fynd', 300)
[void]$script:List.Columns.Add('Kategori', 115)
[void]$script:List.Columns.Add('Pris', 90)
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

# Which thread the list shows. 'all', or a thread id as a string.
$script:FilterButton = New-Object System.Windows.Forms.ToolStripDropDownButton
$script:FilterButton.DisplayStyle = [System.Windows.Forms.ToolStripItemDisplayStyle]::Text
$script:FilterButton.ToolTipText = 'Visa bara en av trådarna'

function Set-FyndFilter {
    param([string]$Value)
    $script:State.filter = $Value
    Save-FyndState -State $script:State
    Update-Window
}

$script:FilterChoices = @(
    [pscustomobject]@{ Value = 'all'; Label = 'Allt' }
) + @($script:FyndSources | ForEach-Object {
        [pscustomobject]@{ Value = $_.Id; Label = $_.Label }
    })

foreach ($choice in $script:FilterChoices) {
    $mi = New-Object System.Windows.Forms.ToolStripMenuItem $choice.Label
    $mi.Tag = $choice.Value
    $mi.Add_Click({ Set-FyndFilter -Value ([string]$this.Tag) }.GetNewClosure())
    [void]$script:FilterButton.DropDownItems.Add($mi)
}
[void]$script:Bar.Items.Add($script:FilterButton)

[void]$script:Bar.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))

<#
Källor: bockar man ur en slutar den hämtas och larma helt. Det är något annat än
"Visar:" bredvid, som bara filtrerar vad fönstret listar.
#>
$script:SourceButton = New-Object System.Windows.Forms.ToolStripDropDownButton
$script:SourceButton.Text = 'Källor'
$script:SourceButton.DisplayStyle = [System.Windows.Forms.ToolStripItemDisplayStyle]::Text
$script:SourceButton.ToolTipText = 'Välj vilka källor som bevakas'

function Switch-FyndSource {
    param([string]$SourceId)
    $now = Test-SourceEnabled -State $script:State -SourceId $SourceId
    Set-SourceEnabled -State $script:State -SourceId $SourceId -Enabled (-not $now)
    Save-FyndState -State $script:State
    Write-FyndLog "kalla $SourceId $(if ($now) { 'av' } else { 'pa' })"
    Update-Window
    Update-Bar
}

foreach ($src in $script:FyndSources) {
    $mi = New-Object System.Windows.Forms.ToolStripMenuItem $src.Label
    $mi.Tag = $src.Id
    $mi.CheckOnClick = $false
    $mi.Add_Click({ Switch-FyndSource -SourceId ([string]$this.Tag) }.GetNewClosure())
    [void]$script:SourceButton.DropDownItems.Add($mi)
}
[void]$script:Bar.Items.Add($script:SourceButton)

[void]$script:Bar.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))

# Tyst läge, för möten. Fynden samlas fortfarande in.
$script:MuteButton = New-Object System.Windows.Forms.ToolStripButton
$script:MuteButton.DisplayStyle = [System.Windows.Forms.ToolStripItemDisplayStyle]::Text
$script:MuteButton.CheckOnClick = $false
$script:MuteButton.Add_Click({
        $script:State.muted = -not $script:State.muted
        Save-FyndState -State $script:State
        Write-FyndLog "tyst lage: $($script:State.muted)"
        if ($script:State.muted) { Stop-Blink; Stop-Flash }
        Update-Bar
        Set-TrayTooltip
    })
[void]$script:Bar.Items.Add($script:MuteButton)

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
        $rows = @($script:State.recent)
        if ($script:State.filter -and $script:State.filter -ne 'all') {
            $rows = @($rows | Where-Object { [string]$_.ThreadId -eq [string]$script:State.filter })
        }
        foreach ($find in $rows) {
            # Column 0 is the row's own text, so Fynd has to be first.
            $item = New-Object System.Windows.Forms.ListViewItem $find.Title
            $category = $find.Category
            if (-not $category) { $category = '' }
            [void]$item.SubItems.Add($category)
            $price = $find.Price
            if (-not $price) { $price = '' }
            [void]$item.SubItems.Add($price)
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
        $script:Form.Icon = Get-BadgedIcon -Count $unread -Size 64 -Alert
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

    if ($script:MuteButton) {
        if ($script:State.muted) {
            $script:MuteButton.Text = 'Notiser: AV'
            $script:MuteButton.ToolTipText = 'Tyst läge. Fynd samlas in men inget larmar. Klicka för att slå på.'
            $script:MuteButton.ForeColor = [System.Drawing.ColorTranslator]::FromHtml('#B00020')
            $script:MuteButton.Font = New-Object System.Drawing.Font $script:Bar.Font, ([System.Drawing.FontStyle]::Bold)
        }
        else {
            $script:MuteButton.Text = 'Notiser: på'
            $script:MuteButton.ToolTipText = 'Klicka för tyst läge, t.ex. under möten.'
            $script:MuteButton.ForeColor = [System.Drawing.SystemColors]::ControlText
            $script:MuteButton.Font = $script:Bar.Font
        }
    }

    if ($script:SourceButton) {
        $on = 0
        foreach ($mi in $script:SourceButton.DropDownItems) {
            $enabled = Test-SourceEnabled -State $script:State -SourceId ([string]$mi.Tag)
            $mi.Checked = $enabled
            if ($enabled) { $on++ }
        }
        $total = @($script:FyndSources).Count
        $script:SourceButton.Text = if ($on -eq $total) { "Källor ($total)" } else { "Källor ($on/$total)" }
    }

    if ($script:FilterButton) {
        $current = [string]$script:State.filter
        if (-not $current) { $current = 'all' }
        $match = @($script:FilterChoices | Where-Object { $_.Value -eq $current }) | Select-Object -First 1
        $name = if ($match) { $match.Label } else { 'Allt' }
        $script:FilterButton.Text = "Visar: $name"
        foreach ($mi in $script:FilterButton.DropDownItems) {
            $mi.Checked = ([string]$mi.Tag -eq $current)
        }
    }
}

function Start-Flash {
    try { [FyndkollFlash]::Start($script:Form.Handle) } catch {}
}

function Stop-Flash {
    try { [FyndkollFlash]::Stop($script:Form.Handle) } catch {}
}

<#
Drags the window back onto a real monitor if it is no longer on one.

The app runs for days at a time, so the display layout changes underneath it:
undock the laptop and a window centred on the second screen keeps coordinates
like x=-1691 that no longer exist. It is not minimised and not hidden, so
clicking the taskbar button appears to do nothing at all.
#>
function Reset-WindowIfOffScreen {
    $bounds = $script:Form.Bounds
    $visible = $false
    foreach ($screen in [System.Windows.Forms.Screen]::AllScreens) {
        if ($screen.WorkingArea.IntersectsWith($bounds)) { $visible = $true; break }
    }
    if ($visible) { return }

    Write-FyndLog "fonstret lag utanfor skarmen ($($bounds.X),$($bounds.Y)) - centrerar om"
    $area = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
    $width = [Math]::Min($script:Form.Width, $area.Width)
    $height = [Math]::Min($script:Form.Height, $area.Height)
    $script:Form.Bounds = New-Object System.Drawing.Rectangle(
        [int]($area.X + ($area.Width - $width) / 2),
        [int]($area.Y + ($area.Height - $height) / 2),
        $width, $height)
}

function Show-FyndWindow {
    Stop-Flash
    Stop-Blink
    Update-Window
    $script:Form.Show()
    if ($script:Form.WindowState -eq [System.Windows.Forms.FormWindowState]::Minimized) {
        $script:Form.WindowState = [System.Windows.Forms.FormWindowState]::Normal
    }
    Reset-WindowIfOffScreen
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

# Docking and undocking changes the desktop under a window that has been open for
# days. Fix it when it happens rather than waiting for someone to notice.
[Microsoft.Win32.SystemEvents]::add_DisplaySettingsChanged({
        try { Reset-WindowIfOffScreen } catch { }
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
    $wanted = @()
    foreach ($s in (Get-EnabledSources)) {
        $seen[$s.Id] = Get-LastSeenFor -State $script:State -SourceId $s.Id
        $wanted += $s.Id
    }
    if ($wanted.Count -eq 0) {
        # Allt urbockat - inget att hämta.
        $script:Checking = $false
        Update-Bar
        return
    }

    $runspace = [runspacefactory]::CreateRunspace()
    $runspace.ApartmentState = 'MTA'
    $runspace.Open()
    $shell = [powershell]::Create()
    $shell.Runspace = $runspace
    [void]$shell.AddScript({
            param($ModulePath, $Seen, $Wanted)
            . $ModulePath
            $out = @{ posts = @(); errors = @() }
            foreach ($s in $script:FyndSources) {
                if ($Wanted -notcontains $s.Id) { continue }
                try {
                    $last = [int64]$Seen[$s.Id]
                    $out.posts += @(Get-FyndSourcePosts -Source $s -LastSeen $last)
                }
                catch {
                    $out.errors += "$($s.Label): $($_.Exception.Message)"
                }
            }
            $out | ConvertTo-Json -Depth 6 -Compress
        }).AddArgument($script:ModulePath).AddArgument($seen).AddArgument($wanted)

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

    # Allt fönstret listar, läst som oläst. Slås ihop i stället för att skrivas
    # över: en tråd som just bytt sida returnerar nästan ingenting, och en
    # överskrivning skulle kasta historiken som redan syns.
    # Sorteras på tid, inte på PostId - id:n är bara jämförbara inom en källa.
    $merged = @(@($posts) + @($script:State.recent))
    $byKey = [ordered]@{}
    foreach ($r in ($merged | Sort-Object { [int64]$_.CreatedAt } -Descending)) {
        $key = "$($r.ThreadId)/$($r.PostId)"
        if (-not $byKey.Contains($key)) { $byKey[$key] = $r }
    }
    $script:State.recent = @($byKey.Values | Select-Object -First 120)

    $isFirstRun = -not $script:State.seeded
    $fresh = @()

    foreach ($s in (Get-EnabledSources)) {
        $mine = @($posts | Where-Object { $_.ThreadId -eq $s.Id })
        if ($mine.Count -eq 0) { continue }

        if ($s.Type -eq 'rss') {
            # Mängd av sedda id:n; id växer inte med tiden för RSS.
            $already = @(Get-SeenIdsFor -State $script:State -SourceId $s.Id)
            if ($already.Count -gt 0) {
                $fresh += @($mine | Where-Object { $already -notcontains [int64]$_.PostId })
            }
            Set-SeenIdsFor -State $script:State -SourceId $s.Id `
                -Ids (@($mine | ForEach-Object { [int64]$_.PostId }) + $already)
        }
        else {
            $last = Get-LastSeenFor -State $script:State -SourceId $s.Id
            if ($last -gt 0) { $fresh += @($mine | Where-Object { $_.PostId -gt $last }) }
            $highest = ($mine | Measure-Object -Property PostId -Maximum).Maximum
            if ($highest -gt $last) { Set-LastSeenFor -State $script:State -SourceId $s.Id -PostId $highest }
        }
    }

    $script:State.seeded = $true

    if ($isFirstRun) {
        # Larma inte om inlägg som redan låg där när appen kom till.
        Write-FyndLog "seedade med $($posts.Count) befintliga inlägg"
        Save-FyndState -State $script:State
        if (-not $script:State.muted) {
            $script:Notify.ShowBalloonTip(6000, 'Fyndkoll bevakar nu',
                "Läste in $($posts.Count) befintliga inlägg. Du får en notis när något nytt postas.",
                [System.Windows.Forms.ToolTipIcon]::Info)
        }
        Update-Window
        Set-TrayTooltip
        return
    }

    if ($fresh.Count -eq 0) {
        Write-FyndLog 'no new posts'
        Save-FyndState -State $script:State
        Update-Window
        Set-TrayTooltip
        return
    }

    $fresh = @($fresh | Sort-Object { [int64]$_.CreatedAt } -Descending)
    Write-FyndLog "$($fresh.Count) nya inlägg: $(($fresh | ForEach-Object { "[$($_.ThreadLabel)] $($_.Title)" }) -join ' | ')"

    $unreadAll = @(@($fresh) + @($script:State.unread))
    $seenKeys = [ordered]@{}
    foreach ($r in ($unreadAll | Sort-Object { [int64]$_.CreatedAt } -Descending)) {
        $key = "$($r.ThreadId)/$($r.PostId)"
        if (-not $seenKeys.Contains($key)) { $seenKeys[$key] = $r }
    }
    $script:State.unread = @($seenKeys.Values | Select-Object -First 40)
    Save-FyndState -State $script:State

    <#
    Tyst läge: fynden samlas, fönstret och siffran uppdateras som vanligt, men
    ingen notis, inget blink och ingen blinkande taskbar-knapp. Tanken är att
    kunna sitta i möte utan att missa något - bara utan att bli avbruten.
    #>
    if ($script:State.muted) {
        Write-FyndLog 'tyst läge - hoppar over notis'
    }
    else {
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
    }

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

    $threads = New-Object System.Windows.Forms.ToolStripMenuItem 'Öppna källa'
    foreach ($src in $script:FyndSources) {
        $ti = New-Object System.Windows.Forms.ToolStripMenuItem $src.Label
        $ti.Tag = switch ($src.Type) {
            'sweclockers' { Get-FyndLastPageUrl ([pscustomobject]@{ Slug = $src.Slug }) }
            default { $src.Url }
        }
        $ti.Add_Click({ Open-Url -Url $this.Tag }.GetNewClosure())
        [void]$threads.DropDownItems.Add($ti)
    }
    [void]$script:Menu.Items.Add($threads)

    $mute = New-Object System.Windows.Forms.ToolStripMenuItem 'Tyst läge'
    $mute.Checked = [bool]$script:State.muted
    $mute.ToolTipText = 'Samla in fynd men larma inte'
    $mute.Add_Click({
            $script:State.muted = -not $script:State.muted
            Save-FyndState -State $script:State
            if ($script:State.muted) { Stop-Blink; Stop-Flash }
            Update-Bar
            Set-TrayTooltip
        })
    [void]$script:Menu.Items.Add($mute)

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
        $icon = Join-Path $PSScriptRoot 'fyndkoll.ico'
        if (Test-Path $icon) { $sc.IconLocation = "$icon,0" }
        $sc.Description = 'Fyndkoll - bevakar SweClockers fyndtrådar'
        $sc.Save()
        Write-FyndLog "startup shortcut created at $script:StartupLink"
    }
    catch { Write-FyndLog "could not create startup shortcut: $($_.Exception.Message)" }
}

# ---------------------------------------------------------------- timers ------

$script:PollTimer = New-Object System.Windows.Forms.Timer
$script:PollTimer.Interval = [int]$script:State.intervalMinutes * 60000
$script:PollTimer.Add_Tick({
        try { Start-FyndCheck }
        catch { Write-FyndLog "poll-tick fel: $($_.Exception.Message)" }
    })

$script:WatchTimer = New-Object System.Windows.Forms.Timer
$script:WatchTimer.Interval = 400
$script:WatchTimer.Add_Tick({
        try {
            if ($script:Pending -and $script:Pending.Handle.IsCompleted) { Complete-FyndCheck }
        }
        catch {
            # Never let a bad poll take the whole app down; reset and wait for the next one.
            Write-FyndLog "check-tick fel: $($_.Exception.Message)"
            $script:WatchTimer.Stop()
            $script:Pending = $null
            $script:Checking = $false
            try { Update-Bar } catch { }
        }
    })

$script:BlinkTimer = New-Object System.Windows.Forms.Timer
$script:BlinkTimer.Interval = 650
$script:BlinkTimer.Add_Tick({
        $script:BlinkOn = -not $script:BlinkOn
        $unread = @($script:State.unread).Count
        if ($script:BlinkOn) { $script:Notify.Icon = Get-BadgedIcon -Count $unread -Size 32 -Alert }
        else { $script:Notify.Icon = Get-BadgedIcon -Count $unread -Size 32 }
    })

# ---------------------------------------------------------------- events ------

$script:Menu.Add_Opening({ Build-Menu })

$script:Notify.Add_BalloonTipClicked({
        $first = @($script:State.unread) | Select-Object -First 1
        if ($first) { Open-Url -Url $first.Permalink }
        Clear-Unread
    })

# Left-click brings up the window. Showing the context menu here instead was
# unreliable - a ContextMenuStrip shown at the cursor with no owner often flashes
# and closes immediately, so clicking the icon looked like it did nothing.
# Right-click still gets the menu, which NotifyIcon handles natively.
$script:Notify.Add_MouseUp({
        if ($_.Button -eq [System.Windows.Forms.MouseButtons]::Left) {
            try { Show-FyndWindow } catch { Write-FyndLog "kunde inte visa fonstret: $($_.Exception.Message)" }
        }
    })

# ------------------------------------------------------------------ main ------

# Exit quietly if an instance already holds the mutex. The scheduled task retries
# every ten minutes to recover from being killed, so a duplicate launch is the
# normal case, not an error - a dialog here would pop up every ten minutes.
$script:Mutex = New-Object System.Threading.Mutex($false, 'Global\FyndkollTray')
if (-not $script:Mutex.WaitOne(0, $false)) {
    Write-FyndLog 'redan igang - avslutar tyst'
    return
}

Write-FyndLog "started (interval $($script:State.intervalMinutes) min)"
Set-TrayTooltip
Set-TrayIcon

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
