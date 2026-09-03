# Fetches and parses the SweClockers fynd threads.
#
# Fetching goes through curl.exe on purpose: SweClockers sits behind Cloudflare,
# which challenges the .NET HTTP stack (Invoke-WebRequest gets 403) but lets
# curl through. curl.exe ships with Windows 10/11, so there is nothing to install.
#
# Parsing walks balanced <div> tags rather than using regex across the whole
# document, so "the div.message subtree" means the same thing a real HTML parser
# would mean - which is what keeps signatures and quoted posts out of the tips.

$script:FyndThreads = @(
    [pscustomobject]@{
        Id    = 999559
        Slug  = '999559-dagens-fynd-bara-tips-ingen-diskussion-las-forsta-inlagget-forst'
        Label = 'Dagens fynd'
    },
    [pscustomobject]@{
        Id    = 1465406
        Slug  = '1465406-ovriga-fynd-bara-tips-ingen-diskussion-las-forsta-inlagget-forst'
        Label = 'Övriga fynd'
    }
)

$script:FyndBase = 'https://www.sweclockers.com'

$script:FyndUserAgent = 'Mozilla/5.0 (Linux; Android 14) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Mobile Safari/537.36'

# Labels that belong to the fynd template; everything else stays as free text.
$script:FyndTemplateLabels = @(
    'produkt', 'produkter', 'pris', 'priser', 'ord pris', 'ordpris',
    'kategori', 'länk', 'lank', 'link', 'url',
    'prisjakt', 'pricerunner', 'pricrunner', 'prisrunner',
    'butik', 'handlare', 'webbutik', 'säljare'
)

# Never a shop: screenshots, video and links back into the forum.
$script:FyndJunkHosts = @(
    'sweclockers.com', 'youtube.com', 'youtu.be',
    'imgur.com', 'ibb.co', 'postimg.', 'prnt.sc'
)

# Useful, but only as a fallback - the template lists these under "Prisjakt:".
$script:FyndComparisonHosts = @('prisjakt.nu', 'pricerunner.', 'pricespy.')

$script:FyndLabelRe = [regex]'^\s*([\p{L}][\p{L} /&-]{0,24})\s*:\s*(.*)$'
$script:FyndPriceRe = [regex]::new(
    '(\d{1,3}(?:[ \u00A0\u2009.]\d{3})+|\d+)(?:[.,](\d{1,2}))?\s*(kr|:-|sek|kronor)',
    'IgnoreCase')
$script:FyndPerMonthRe = [regex]::new('^\s*/\s*(mån|manad|månad|mnd|mon)', 'IgnoreCase')

function Get-FyndLastPageUrl { param($Thread) "$script:FyndBase/forum/trad/$($Thread.Slug)/sista-sidan" }
function Get-FyndPageUrl { param($Thread, [int]$Page) "$script:FyndBase/forum/trad/$($Thread.Slug)?p=$Page" }

<#
Downloads a page with curl.exe. Returns the HTML plus the URL curl ended on,
which is how we learn the last page number (/sista-sidan redirects to "?p=N").
#>
function Get-FyndPage {
    param([Parameter(Mandatory)][string]$Url)

    $body = [System.IO.Path]::GetTempFileName()
    try {
        $out = & curl.exe -sS -L --compressed --max-time 30 `
            -A $script:FyndUserAgent `
            -H 'Accept-Language: sv-SE,sv;q=0.9,en;q=0.8' `
            -o $body -w '%{http_code}|%{url_effective}' $Url 2>&1

        $parts = ($out | Out-String).Trim() -split '\|', 2
        $code = $parts[0]
        $final = if ($parts.Count -gt 1) { $parts[1] } else { $Url }
        $html = if (Test-Path $body) { [System.IO.File]::ReadAllText($body, [System.Text.Encoding]::UTF8) } else { '' }

        if ($code -ne '200') { throw "HTTP $code" }
        if ($html -match 'Just a moment') { throw 'Cloudflare-utmaning' }

        [pscustomobject]@{ Html = $html; FinalUrl = $final }
    }
    finally {
        Remove-Item $body -ErrorAction SilentlyContinue
    }
}

# Outer HTML of the div starting at $Open, by counting nested <div>/</div>.
function Get-FyndBalancedDiv {
    param([string]$Html, [int]$Open)
    $tagRe = [regex]'</?div\b'
    $depth = 0
    $pos = $Open
    while ($true) {
        $m = $tagRe.Match($Html, $pos)
        if (-not $m.Success) { return $Html.Substring($Open) }
        if ($m.Value -eq '<div') { $depth++ } else { $depth-- }
        $pos = $m.Index + $m.Length
        if ($depth -eq 0) {
            $close = $Html.IndexOf('>', $pos)
            if ($close -lt 0) { $close = $pos }
            return $Html.Substring($Open, $close - $Open + 1)
        }
    }
}

# Removes every <div class="X"> subtree.
function Remove-FyndDivsWithClass {
    param([string]$Html, [string]$Class)
    while ($true) {
        $m = [regex]::Match($Html, '<div\b[^>]*class="[^"]*\b' + [regex]::Escape($Class) + '\b[^"]*"[^>]*>')
        if (-not $m.Success) { return $Html }
        $block = Get-FyndBalancedDiv -Html $Html -Open $m.Index
        $Html = $Html.Remove($m.Index, $block.Length)
    }
}

<#
Rendered text of a post, one entry per visual line. <br> is what separates the
template fields, so it has to become a newline before tags are stripped.
#>
function ConvertTo-FyndLines {
    param([string]$Html)
    $t = [regex]::Replace($Html, '(?is)<(script|style)\b.*?</\1>', '')
    $t = [regex]::Replace($t, '(?i)<br\s*/?>', "`n")
    $t = [regex]::Replace($t, '(?i)</(p|div|li|tr|h[1-6]|blockquote|ul|ol)>', "`n")
    $t = [regex]::Replace($t, '(?s)<[^>]+>', '')
    $t = [System.Net.WebUtility]::HtmlDecode($t)
    $t = $t -replace [char]0x00A0, ' '
    @($t -split "`n" | ForEach-Object { ($_ -replace '[ \t]+', ' ').Trim() } | Where-Object { $_.Length -gt 0 })
}

<#
First price in the text, normalised to "7128 kr". Handles "369:-", "1999kr",
"1 279 kr", "120 kr (ord 177 kr)", "7128 kr. Flex-avtal 297 kr/mån", "399kr/mån".
#>
function Get-FyndPrice {
    param([string]$Raw)
    if ([string]::IsNullOrWhiteSpace($Raw)) { return $null }
    $m = $script:FyndPriceRe.Match($Raw)
    if (-not $m.Success) { return $null }
    $whole = $m.Groups[1].Value -replace '[ \u00A0\u2009.]', ''
    if ($whole.Length -eq 0 -or $whole.Length -gt 9) { return $null }
    $dec = $m.Groups[2].Value
    $trailing = $Raw.Substring([Math]::Min($m.Index + $m.Length, $Raw.Length))
    $suffix = if ($script:FyndPerMonthRe.IsMatch($trailing)) { '/mån' } else { '' }
    $num = if ($dec.Length -gt 0 -and $dec.TrimEnd('0').Length -gt 0) { "$whole,$dec" } else { $whole }
    "$num kr$suffix"
}

function Get-FyndEllipsized {
    param([string]$Text, [int]$Max)
    if ($Text.Length -le $Max) { return $Text }
    $cut = $Text.LastIndexOf(' ', $Max)
    $end = if ($cut -gt [int]($Max / 2)) { $cut } else { $Max }
    $Text.Substring(0, $end).TrimEnd(' ', ',', '.', '-', '/') + [char]0x2026
}

# Parses one thread page into find objects.
function Get-FyndPosts {
    param([string]$Html, $Thread)

    $results = @()
    $starts = @([regex]::Matches($Html, '<div id="post\d+" class="forum-post') | ForEach-Object { $_.Index })

    for ($k = 0; $k -lt $starts.Count; $k++) {
        $from = $starts[$k]
        $to = if ($k + 1 -lt $starts.Count) { $starts[$k + 1] } else { $Html.Length }
        $chunk = $Html.Substring($from, $to - $from)

        $postId = [int64]([regex]::Match($chunk, '<div id="post(\d+)"').Groups[1].Value)
        if ($postId -eq 0) { continue }

        $created = 0
        $meta = [System.Net.WebUtility]::HtmlDecode([regex]::Match($chunk, 'data-post="([^"]*)"').Groups[1].Value)
        if ($meta -match '"isVisible":false') { continue }
        $cm = [regex]::Match($meta, '"createTime":(\d+)')
        if ($cm.Success) { $created = [int64]$cm.Groups[1].Value }
        if ($created -eq 0) {
            $dm = [regex]::Match($chunk, '<time datetime="([^"]+)"')
            if ($dm.Success) {
                try { $created = [int64]([datetimeoffset]::Parse($dm.Groups[1].Value)).ToUnixTimeSeconds() } catch {}
            }
        }

        $author = ''
        $am = [regex]::Match($chunk, '<span itemprop="name">([^<]*)</span>')
        if ($am.Success) { $author = $am.Groups[1].Value.Trim() }

        $mm = [regex]::Match($chunk, '<div class="message" itemprop="text">')
        if (-not $mm.Success) { continue }
        $msg = Get-FyndBalancedDiv -Html $chunk -Open $mm.Index
        foreach ($c in @('signature', 'bbQuote', 'quote', 'controls')) {
            $msg = Remove-FyndDivsWithClass -Html $msg -Class $c
        }

        $hrefs = @([regex]::Matches($msg, 'href="(https?://[^"]+)"') |
            ForEach-Object { [System.Net.WebUtility]::HtmlDecode($_.Groups[1].Value) })
        $usable = @($hrefs | Where-Object {
                $h = $_.ToLower()
                @($script:FyndJunkHosts | Where-Object { $h.Contains($_) }).Count -eq 0
            })
        $dealLink = @($usable | Where-Object {
                $h = $_.ToLower()
                @($script:FyndComparisonHosts | Where-Object { $h.Contains($_) }).Count -eq 0
            }) | Select-Object -First 1
        if (-not $dealLink) { $dealLink = $usable | Select-Object -First 1 }

        $lines = @(ConvertTo-FyndLines -Html $msg)
        if ($lines.Count -eq 0 -and -not $dealLink) { continue }

        $fields = [ordered]@{}
        $free = @()
        for ($i = 0; $i -lt $lines.Count; $i++) {
            $line = $lines[$i]
            $m = $script:FyndLabelRe.Match($line)
            $isFull = $m.Success -and $m.Length -eq $line.Length
            $label = if ($isFull) { $m.Groups[1].Value.Trim().ToLower() } else { $null }
            if ($label -and ($script:FyndTemplateLabels -contains $label)) {
                $value = $m.Groups[2].Value.Trim()
                if ($value.Length -eq 0 -and ($i + 1) -lt $lines.Count) {
                    $nxt = $script:FyndLabelRe.Match($lines[$i + 1])
                    if (-not ($nxt.Success -and $nxt.Length -eq $lines[$i + 1].Length)) {
                        $value = $lines[$i + 1].Trim(); $i++
                    }
                }
                if ($value.Length -gt 0 -and -not $fields.Contains($label)) { $fields[$label] = $value }
            }
            elseif ($line.Trim().Length -gt 0) { $free += $line }
        }

        $getField = {
            param([string[]]$Keys)
            foreach ($key in $Keys) {
                if ($fields.Contains($key) -and $fields[$key].Trim()) { return $fields[$key] }
            }
            return $null
        }

        $product = & $getField @('produkt', 'produkter')
        $priceRaw = & $getField @('pris', 'priser')
        $category = & $getField @('kategori')
        if ($category -and $category.Length -gt 60) { $category = $category.Substring(0, 60) }

        $price = Get-FyndPrice -Raw $priceRaw
        if (-not $price) { $price = Get-FyndPrice -Raw ($lines -join ' ') }

        $store = $null
        if ($dealLink) {
            $hm = [regex]::Match($dealLink, '^https?://([^/?#]+)')
            if ($hm.Success) { $store = ($hm.Groups[1].Value -replace '^www\.', '').ToLower() }
        }
        if (-not $store) { $store = & $getField @('butik', 'handlare', 'webbutik', 'säljare') }

        $headline = $product
        if (-not $headline) {
            $headline = @($free | Where-Object { $_.Length -gt 3 -and $_ -notmatch '^https?:' }) | Select-Object -First 1
            if (-not $headline) { $headline = @($free | Where-Object { $_.Length -gt 3 }) | Select-Object -First 1 }
        }
        # A post that is nothing but a pasted link reads better as the shop name.
        $titleSrc = $headline
        if ($titleSrc -and $titleSrc -match '^https?:') { $titleSrc = $null }
        if (-not $titleSrc) { $titleSrc = $store }
        if (-not $titleSrc) { $titleSrc = 'Nytt inlägg' }
        $title = Get-FyndEllipsized -Text (($titleSrc -replace '[ \t]+', ' ').Trim()) -Max 90

        # Everything outside the template. This is where the good detail lives
        # ("Bara 9h kvar", "Power har samma för 124 kr + frakt").
        $note = (@($free |
                Where-Object { $_ -ne $headline } |
                Where-Object { -not ($_.StartsWith('http') -and $_.EndsWith('...')) }) -join "`n").Trim()

        $results += [pscustomobject]@{
            PostId      = $postId
            ThreadId    = $Thread.Id
            ThreadLabel = $Thread.Label
            Author      = $author
            CreatedAt   = $created
            Title       = $title
            Price       = $price
            Category    = $category
            Store       = $store
            DealLink    = $dealLink
            Note        = $note
            Permalink   = "$script:FyndBase/forum/post/$postId"
        }
    }

    $results
}

<#
Posts from the end of a thread. One request to /sista-sidan is normally enough
(a page holds ~29 posts); if every post on that page is newer than $LastSeen we
may have missed some, so walk back a few pages.
#>
function Get-FyndThreadPosts {
    param($Thread, [int64]$LastSeen = 0, [int]$MaxExtraPages = 3)

    $page = Get-FyndPage -Url (Get-FyndLastPageUrl $Thread)
    $collected = @(Get-FyndPosts -Html $page.Html -Thread $Thread)

    $pageNo = $null
    $pm = [regex]::Match($page.FinalUrl, '[?&]p=(\d+)')
    if ($pm.Success) { $pageNo = [int]$pm.Groups[1].Value }

    $extra = 0
    while ($LastSeen -gt 0 -and $pageNo -and $pageNo -gt 1 -and $extra -lt $MaxExtraPages -and
        $collected.Count -gt 0 -and (($collected | Measure-Object -Property PostId -Minimum).Minimum -gt $LastSeen)) {
        $pageNo--
        $extra++
        $older = @(Get-FyndPosts -Html (Get-FyndPage -Url (Get-FyndPageUrl $Thread $pageNo)).Html -Thread $Thread)
        if ($older.Count -eq 0) { break }
        $collected += $older
    }

    $collected | Sort-Object PostId -Unique
}
