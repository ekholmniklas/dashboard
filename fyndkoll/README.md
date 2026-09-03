# Fyndkoll

En liten Android-app som bevakar SweClockers fyndtrådar och notifierar när något nytt postas.

Bevakar:

- [Dagens fynd](https://www.sweclockers.com/forum/trad/999559-dagens-fynd-bara-tips-ingen-diskussion-las-forsta-inlagget-forst/sista-sidan) (tråd 999559)
- [Övriga fynd](https://www.sweclockers.com/forum/trad/1465406-ovriga-fynd-bara-tips-ingen-diskussion-las-forsta-inlagget-forst/sista-sidan) (tråd 1465406)

## Så här får du den i telefonen

Det finns ingen Android SDK på den här datorn, så APK:n byggs i GitHub Actions.

1. Committa och pusha mappen `fyndkoll/` och workflowen:

   ```bash
   git add fyndkoll .github/workflows/build-fyndkoll.yml && git commit -m "Add Fyndkoll" && git push
   ```

2. Gå till **Actions → Build Fyndkoll APK** i repot. Bygget tar ca 3–5 minuter.
3. Öppna releasen **fyndkoll-latest** i telefonens webbläsare och tryck på
   `fyndkoll-latest.apk`. Android frågar om du vill tillåta installation från
   webbläsaren — svara ja.
4. Starta appen. Den frågar efter notistillstånd. Säg ja, annars kan den inte larma.

Första hämtningen läser in de inlägg som redan finns **utan** att skicka 35 notiser.
Därefter kommer en notis per nytt inlägg.

### Om notiser slutar komma

Samsung stänger av bakgrundsarbete ganska aggressivt. I appens meny finns
**Batterioptimering** som öppnar systemlistan där Fyndkoll kan undantas. På One UI
kan du dessutom behöva sätta appen till "Obegränsad" under
*Inställningar → Batteri → Användningsgränser för bakgrund*.

## Notisens utseende

Hopfälld visar den bara det viktigaste, eftersom det är allt som får plats:

```
Fyndkoll · FYND
Dreame Matrix 10 Ultra
7128 kr
```

Fälls den ut kommer resten med — kategori, butik, och posterns egen kommentar,
som ofta är det mest användbara ("Bara 9h kvar", "Power har samma för 124 kr + frakt"):

```
7128 kr · Robotdammsugare · komplett.se

Leasa en robotdammsugare hos Komplett för 297 kr/månaden i 24 månader
(mtk 7128 kr). Eller köp nu för 8990 kr, samma priser hos webbhallen
och netonnet.

Övriga fynd · napahlm · 13:37
```

Tryck på notisen för att öppna inlägget; knappen **Till komplett.se** går direkt
till butiken.

## Hur den läser trådarna

SweClockers har ingen RSS, så appen hämtar `/sista-sidan` (som redirectar till
sista sidnumret och inte kräver inloggning) och parsar HTML med jsoup.

Per inlägg:

| Del | Var den kommer ifrån |
|---|---|
| Post-id, tidpunkt | `div.forum-post[data-post]` — JSON med `postid` och `createTime` |
| Författare | `span[itemprop=name]` |
| Text | `div.message[itemprop=text]`, med `.bbQuote` och signaturer borttagna |

Texten läses som *renderad text*, inte HTML, eftersom fältnamnen förekommer både
som `Produkt: X` och som `<strong>Produkt</strong>: X`. Fälten `Produkt`, `Pris`,
`Kategori`, `Länk` och `Prisjakt` plockas ut; allt annat som posteren skrivit
sparas som kommentar och visas i den utfällda notisen.

Priser normaliseras till `7128 kr`. Verifierat mot alla prisformat som faktiskt
förekommer i trådarna: `369:-`, `1999kr`, `1 279 kr`, `120 kr (ord 177 kr)`,
`7128 kr. Flex-avtal 297 kr/mån` och `399kr/mån`.

Inlägg som inte följer mallen får en notis ändå: rubriken blir första
meningsfulla textraden och priset första pris-liknande talet i texten.

"Nytt sedan sist" avgörs på `postid`, som växer monotont. Normalt räcker en
hämtning av sista sidan (~29 inlägg per sida); om varje inlägg på sidan är nyare
än det senast sedda backar appen upp till tre sidor för att inte tappa något.

## Inställningar

Kontrollintervall väljs i menyn: 15, 30 (standard), 60, 120 eller 180 minuter.
15 minuter är golvet WorkManager tillåter för periodiskt arbete.

## Bra att veta

- Appen skrapar HTML. Om SweClockers gör om sin markup slutar parsningen fungera,
  och statusraden i appen visar då ett fel. Det är fixbart, men inte automatiskt.
- APK:n är debug-signerad. Det gör den installerbar utan nyckelhantering, men den
  kan inte publiceras på Google Play som den är.
- Maskoten i ikonen och notisen är SweClockers egen, hämtad från deras `logo.svg`.
  Helt OK för en privat app, men den bör bytas om appen någonsin sprids vidare.
