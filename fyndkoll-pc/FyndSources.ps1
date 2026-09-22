# Källorna Fyndkoll bevakar, och hämtningen för varje typ.
#
# FyndParse.ps1 sköter SweClockers. Här läggs de andra typerna ovanpå, så den
# verifierade SweClockers-tolkningen inte behöver röras.
#
# Tre typer:
#   sweclockers  HTML, Produkt/Pris-mall, post-id växer monotont
#   xenforo      HTML (Swedroid), post-id växer monotont
#   rss          Pepperdeals. Id växer INTE med tiden - ett äldre fynd kan bli
#                hett senare - så för RSS sparas sedda id:n som en mängd
#                istället för ett högvattenmärke.

. (Join-Path $PSScriptRoot 'FyndParse.ps1')

$script:FyndSources = @(
    [pscustomobject]@{
        Id = 'swec-999559'; Label = 'Dagens fynd'; Type = 'sweclockers'
        ThreadId = 999559
        Slug = '999559-dagens-fynd-bara-tips-ingen-diskussion-las-forsta-inlagget-forst'
    },
    [pscustomobject]@{
        Id = 'swec-1465406'; Label = 'Övriga fynd'; Type = 'sweclockers'
        ThreadId = 1465406
        Slug = '1465406-ovriga-fynd-bara-tips-ingen-diskussion-las-forsta-inlagget-forst'
    },
    [pscustomobject]@{
        Id = 'swec-1012271'; Label = 'Digitala spelfynd'; Type = 'sweclockers'
        ThreadId = 1012271
        Slug = '1012271-digitala-spelfynd-bara-tips-ingen-diskussion'
    },
    [pscustomobject]@{
        Id = 'swedroid-186347'; Label = 'Swedroid Amazon'; Type = 'xenforo'
        Url = 'https://swedroid.se/forum/threads/fyndtipstraden-amazon-se-inga-diskussioner.186347/'
    },
    [pscustomobject]@{
        Id = 'pepper-hot'; Label = 'Pepperdeals'; Type = 'rss'
        Url = 'https://www.pepperdeals.se/rss/hot'
    }
)

function Get-FyndSourceById {
    param([string]$Id)
    $script:FyndSources | Where-Object { $_.Id -eq $Id } | Select-Object -First 1
}

# ------------------------------------------------------------------ xenforo ---

<#
Swedroid kör XenForo. Inläggen ligger i <article data-content="post-N"> med
författaren i data-author, tiden i <time datetime> och texten i div.bbWrapper.
Citat (blockquote) plockas bort, precis som .bbQuote gör på SweClockers.
#>
function Get-FyndXenForoPosts {
    param($Source)

    # /latest hoppar till sista sidan utan inloggning.
    $page = Get-FyndPage -Url ($Source.Url.TrimEnd('/') + '/latest')
    $html = $page.Html

    $results = @()
    $starts = @([regex]::Matches($html, '<article[^>]*data-content="post-\d+"') | ForEach-Object { $_.Index })

    for ($k = 0; $k -lt $starts.Count; $k++) {
        $from = $starts[$k]
        $to = if ($k + 1 -lt $starts.Count) { $starts[$k + 1] } else { $html.Length }
        $chunk = $html.Substring($from, $to - $from)

        $postId = [int64]([regex]::Match($chunk, 'data-content="post-(\d+)"').Groups[1].Value)
        if ($postId -eq 0) { continue }

        $author = ''
        $am = [regex]::Match($chunk, 'data-author="([^"]*)"')
        if ($am.Success) { $author = [System.Net.WebUtility]::HtmlDecode($am.Groups[1].Value).Trim() }

        $created = 0
        $dm = [regex]::Match($chunk, '<time[^>]+datetime="([^"]+)"')
        if ($dm.Success) {
            try { $created = [int64]([datetimeoffset]::Parse($dm.Groups[1].Value)).ToUnixTimeSeconds() } catch {}
        }

        $bm = [regex]::Match($chunk, '(?s)<div class="bbWrapper">(.*?)</article>')
        if (-not $bm.Success) { continue }
        $body = $bm.Groups[1].Value
        $body = [regex]::Replace($body, '(?s)<blockquote.*?</blockquote>', '')
        $body = [regex]::Replace($body, '(?s)<div class="message-signature".*$', '')

        $hrefs = @([regex]::Matches($body, 'href="(https?://[^"]+)"') |
            ForEach-Object { [System.Net.WebUtility]::HtmlDecode($_.Groups[1].Value) })
        $usable = @($hrefs | Where-Object {
                $h = $_.ToLower()
                (@($script:FyndJunkHosts | Where-Object { $h.Contains($_) }).Count -eq 0) -and -not $h.Contains('swedroid.se')
            })
        $dealLink = $usable | Select-Object -First 1

        $lines = @(ConvertTo-FyndLines -Html $body)
        if ($lines.Count -eq 0 -and -not $dealLink) { continue }

        $price = Get-FyndPrice -Raw ($lines -join ' ')
        $headline = @($lines | Where-Object { $_.Length -gt 3 -and $_ -notmatch '^https?:' }) | Select-Object -First 1
        if (-not $headline) { $headline = $lines | Select-Object -First 1 }

        $store = $null
        if ($dealLink) {
            $hm = [regex]::Match($dealLink, '^https?://([^/?#]+)')
            if ($hm.Success) { $store = ($hm.Groups[1].Value -replace '^www\.', '').ToLower() }
        }

        $titleSrc = $headline
        if (-not $titleSrc) { $titleSrc = $store }
        if (-not $titleSrc) { $titleSrc = 'Nytt inlägg' }

        $results += [pscustomobject]@{
            PostId      = $postId
            ThreadId    = $Source.Id
            ThreadLabel = $Source.Label
            Author      = $author
            CreatedAt   = $created
            Title       = Get-FyndEllipsized -Text (($titleSrc -replace '[ \t]+', ' ').Trim()) -Max 90
            Price       = $price
            Category    = $null
            Store       = $store
            DealLink    = $dealLink
            Note        = (@($lines | Where-Object { $_ -ne $headline }) -join "`n").Trim()
            FullText    = ($lines -join "`n")
            Permalink   = "https://swedroid.se/forum/posts/$postId/"
        }
    }

    $results | Sort-Object PostId -Unique
}

# ---------------------------------------------------------------------- rss ---

<#
Pepperdeals RSS. Titeln inleds med en temperatur ("141° - ..."), som är
communityns röstning; den plockas ut separat och visas som kategori istället för
att skräpa ned rubriken.
#>
function Get-FyndRssPosts {
    param($Source)

    $page = Get-FyndPage -Url $Source.Url
    $xml = $null
    try { $xml = [xml]$page.Html } catch { throw "kunde inte tolka RSS: $($_.Exception.Message)" }

    $results = @()
    foreach ($item in @($xml.rss.channel.item)) {
        $text = {
            param($n)
            if ($null -eq $n) { '' } elseif ($n -is [string]) { $n } else { $n.InnerText }
        }

        $link = & $text $item.link
        if (-not $link) { continue }

        # Id ur länkens slut: .../deals/nagot-nagot-18875
        $idMatch = [regex]::Match($link, '-(\d+)(?:[?#]|$)')
        if (-not $idMatch.Success) { continue }
        $postId = [int64]$idMatch.Groups[1].Value

        $title = (& $text $item.title).Trim()
        $degrees = $null
        $tm = [regex]::Match($title, '^\s*(-?\d+)\s*°\s*-\s*(.+)$')
        if ($tm.Success) {
            $degrees = "$($tm.Groups[1].Value)°"
            $title = $tm.Groups[2].Value.Trim()
        }

        $created = 0
        try { $created = [int64]([datetimeoffset]::Parse($item.pubDate)).ToUnixTimeSeconds() } catch {}

        $descHtml = & $text $item.description
        $desc = ($descHtml -replace '(?s)<[^>]+>', ' ')
        $desc = [System.Net.WebUtility]::HtmlDecode($desc) -replace '\s+', ' '
        $desc = $desc.Trim()

        $category = (& $text $item.category).Trim()
        if ($degrees) { $category = (@($degrees, $category) | Where-Object { $_ }) -join ' ' }

        # Butiken står oftast först i rubriken: "Webbhallen - Upp till 50 %".
        $store = $null
        $sm = [regex]::Match($title, '^([^-•|]{2,28})\s*[-•|]')
        if ($sm.Success) { $store = $sm.Groups[1].Value.Trim() }

        $results += [pscustomobject]@{
            PostId      = $postId
            ThreadId    = $Source.Id
            ThreadLabel = $Source.Label
            Author      = ''
            CreatedAt   = $created
            Title       = Get-FyndEllipsized -Text $title -Max 90
            Price       = Get-FyndPrice -Raw "$title $desc"
            Category    = $category
            Store       = $store
            DealLink    = $link
            Note        = $desc
            FullText    = (@($title, '', $desc) -join "`n").Trim()
            Permalink   = $link
        }
    }

    $results | Sort-Object PostId -Unique
}

# ----------------------------------------------------------------- dispatch ---

<#
Hämtar en källa. $LastSeen används av forumtyperna (monotona id), $SeenIds av
RSS. Returnerar inläggen sorterade äldst först.
#>
function Get-FyndSourcePosts {
    param($Source, [int64]$LastSeen = 0)

    switch ($Source.Type) {
        'sweclockers' {
            $thread = [pscustomobject]@{
                Id = $Source.ThreadId; Slug = $Source.Slug; Label = $Source.Label
            }
            $posts = @(Get-FyndThreadPosts -Thread $thread -LastSeen $LastSeen)
            # ThreadId ska vara källans id, inte trådnumret, sa filter och
            # lastSeen använder samma nyckel för alla typer.
            foreach ($p in $posts) { $p.ThreadId = $Source.Id }
            return $posts
        }
        'xenforo' { return @(Get-FyndXenForoPosts -Source $Source) }
        'rss' { return @(Get-FyndRssPosts -Source $Source) }
        default { throw "okänd källtyp: $($Source.Type)" }
    }
}
