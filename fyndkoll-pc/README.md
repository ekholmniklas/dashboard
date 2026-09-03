| Visa fönster | Tar upp listan med fynd |
| *(lista med fynd)* | Öppnar butikslänken; undermeny för forumsinlägget |
| `Fyndkoll-Tray.ps1` | Fönstret, taskbar-knappen, ikonen, menyn, notiserna, timern |
# Fyndkoll för PC

Liten app som bevakar SweClockers fyndtrådar och säger till när något nytt postas:
en taskbar-knapp som blinkar, en Windows-notis och en ikon i systemfältet.

- [Dagens fynd](https://www.sweclockers.com/forum/trad/999559-dagens-fynd-bara-tips-ingen-diskussion-las-forsta-inlagget-forst/sista-sidan)
- [Övriga fynd](https://www.sweclockers.com/forum/trad/1465406-ovriga-fynd-bara-tips-ingen-diskussion-las-forsta-inlagget-forst/sista-sidan)

## Starta

Dubbelklicka **`Start-Fyndkoll.vbs`**. Ingen installation, inget konsollfönster,
inga admin-rättigheter. En rund ikon med "kr" dyker upp bland ikonerna nere till
höger.

Första körningen läser in de inlägg som redan finns *utan* att larma, och säger
bara "Fyndkoll bevakar nu". Efter det får du en notis så fort något nytt dyker upp.

För att den ska starta automatiskt: högerklicka på ikonen → **Starta med Windows**.

## Vad den gör när något nytt kommer

1. **Taskbar-knappen blinkar orange** — samma knapp som ligger nere bland Word
   och Excel. Den blinkar tills du faktiskt tar upp fönstret, precis som när
   Teams vill något.
2. En Windows-notis: rubriken är produkten, raden under är priset. Är det flera
   fynd samtidigt blir det en sammanslagen notis med de fem senaste.
3. Ikonen i systemfältet blinkar också (grå ⇄ orange), om den är synlig.

Klicka på taskbar-knappen och fönstret listar fynden — pris, produkt, butik,
tråd och tid. Nya fynd står i fetstil. **Dubbelklicka** en rad för att öppna
butiken, **Ctrl+Enter** för forumsinlägget. Att titta på fönstret räknas som
läst, så blinkandet slutar av sig självt.

Stänger du fönstret minimeras det bara — appen fortsätter bevaka. Den avslutas
via **Avsluta** i högerklicksmenyn på systemfältsikonen.

### Om systemfältsikonen ligger dold

Windows gömmer nya ikoner bakom pilen `^`. Antingen drar du ikonen därifrån ner
till fältet, eller så slår du på den under *Inställningar → Anpassning →
Aktivitetsfältet → Andra ikoner i systemfältet*. Taskbar-knappen syns alltid,
så det är mest en smaksak.

## Menyn

| Val | Gör |
|---|---|
| *(lista med fynd)* | Öppnar butikslänken; undermeny för forumsinlägget |
| Markera alla som lästa | Tömmer listan och slutar blinka |
| Kolla nu | Kontrollerar direkt istället för att vänta |
| Öppna tråd | Öppnar någon av trådarna i webbläsaren |
| Intervall | 5, 10, 15 (standard), 30 eller 60 minuter |
| Starta med Windows | Lägger en genväg i autostart-mappen |
| Visa logg | Öppnar loggen, bra vid felsökning |
| Avsluta | Stänger av |

## Filer

| Fil | Roll |
|---|---|
| `Start-Fyndkoll.vbs` | Startar appen utan konsollfönster |
| `Fyndkoll-Tray.ps1` | Ikonen, menyn, notiserna, timern |
| `FyndParse.ps1` | Hämtar och tolkar trådarna |

Inställningar, "senast sedda inlägg" och loggen ligger i
`%LOCALAPPDATA%\Fyndkoll\`. Ta bort mappen för att börja om från noll.

## Hur den läser trådarna

SweClockers har ingen RSS, så appen hämtar `/sista-sidan` (som redirectar till
sista sidnumret och inte kräver inloggning) och tolkar HTML.

Två saker är värda att veta om implementationen:

**Hämtningen går via `curl.exe`, inte `Invoke-WebRequest`.** SweClockers ligger
bakom Cloudflare, som svarar 403 på .NET:s HTTP-stack men släpper igenom curl.
`curl.exe` följer med Windows 10/11, så det är inget att installera.

**Tolkningen räknar `<div>`-nivåer** istället för att köra regex över hela
dokumentet, så "innehållet i `div.message`" betyder samma sak som en riktig
HTML-parser skulle mena. Det är det som håller signaturer och citerade inlägg
utanför tipsen.

Per inlägg:

| Del | Varifrån |
|---|---|
| Post-id, tidpunkt | `div.forum-post[data-post]` — JSON med `postid` och `createTime` |
| Författare | `span[itemprop=name]` |
| Text | `div.message[itemprop=text]`, med `.bbQuote` och `.signature` borttagna |

Fälten `Produkt`, `Pris`, `Kategori`, `Länk` och `Prisjakt` plockas ut. Allt annat
posteren skrivit sparas som kommentar och visas när notisen fälls ut — det är ofta
det mest användbara ("Bara 9h kvar", "Power har samma för 124 kr + frakt").

Priser normaliseras till `7128 kr`. Verifierat mot alla prisformat som faktiskt
förekommer i trådarna: `369:-`, `1999kr`, `1 279 kr`, `120 kr (ord 177 kr)`,
`7128 kr. Flex-avtal 297 kr/mån` och `399kr/mån`.

Inlägg som inte följer mallen får en notis ändå: rubriken blir första meningsfulla
textraden och priset första pris-liknande talet i texten.

"Nytt sedan sist" avgörs på `postid`, som växer monotont. Normalt räcker sista
sidan (~29 inlägg); om varje inlägg där är nyare än det senast sedda backar appen
upp till tre sidor för att inte tappa något.

## Bra att veta

- **Notiser kommer bara när datorn är på.** Appen kan inte köras i molnet:
  SweClockers Cloudflare blockerar datacenter-IP:n (testat — curl från en GitHub
  Actions-runner får 403, curl härifrån får 200). Den behöver en vanlig
  hemma-uppkoppling.
- Trådarna är "bara tips, ingen diskussion", men det slinker in svar ibland. De
  får en notis de också, med den textrad de nu har ("Missade det, tack."). Vill du
  bara ha inlägg som följer `Produkt:`-mallen är det en enradsändring.
- Appen skrapar HTML. Om SweClockers gör om sin markup slutar tolkningen fungera;
  ikonens tooltip visar då ett fel och loggen detaljerna.
