# Jämmer <VERSION>

<!-- Utkast (2026-11-28) till nästa version, från docs/CHANGES.md och commitarna sedan 0.1.0 (daa7c36). Versionen
     väljer Anders; döp om till <version>.sv.md och byt <VERSION> när den görs. 0.1.1 gavs aldrig ut, så dess
     rättelser står här också. Skickas inte ut för sig. -->

Det här är nytt sedan 0.1.0. Kräver macOS 27 eller senare på Apple-kretsar.

## Rättat

- **En batch kunde skicka ljud till OpenAI utan att fråga.** I 0.1.0 laddade ett batchjobb som skrev ut med OpenAI upp ljudet och debiterade ditt OpenAI-konto utan att fråga, om du hade lagt in en egen OpenAI-nyckel och använde ett eget recept med ett sådant jobb, eller lät en agent be om ett. Nu frågar batchfönstret en gång före en sådan körning och nämner varje betalt jobb.
- **Ett stort dokument stoppar inte längre Jämmer när det öppnas.** Innan vågformerna var klara läste tidslinjen ljudet från disken på huvudtråden: för 24 spår på en timme svarade Jämmer inte på ungefär två och en halv minut. Nu säger varje spår att det väntar eller hur långt dess vågform har lästs, och fönstret svarar direkt.
- **Skadade filer läses inom gränser.** Markörer, etiketter och kodningshistorik i en WAV, en toppfil, en DAWproject-fils packade filer och EDL- och OTIO-filer har var sin övre gräns, så att en trasig eller fientlig fil vägras eller öppnas med en varning i stället för att stoppa Jämmer.
- **Frysning i surround.** Ett fryst placerat spår behöll bara platsen där det började, inte dit automationen flyttade det, och en fryst buss som var vriden runt lyssnaren vreds två gånger. Båda låter nu som innan de frystes.
- Ett klipp som en ändring renderar om behåller kopplingen till Flimmer-klippet det kom från, så att Send to Flimmer skickar tillbaka det som en ny take av det klippet.

## Inspelning

- Tryck på **R** i ett spårhuvud för att förbereda spåret, och sedan **Transport › Spela in** (⌘R). Flera spår spelas in samtidigt, vart och ett från sin egen ingång, medan de andra spelar. En markering blir en inslagning, med två sekunders förrulle.
- Varje take över en sträcka sparas; ett klipps meny väljer en annan eller raderar en. En krasch förlorar högst den sista sekunden, och dokumentet erbjuder sina takes igen när det öppnas.
- macOS frågar första gången om Jämmer får använda mikrofonen. En agent kan se inspelningen och välja bland takes, men förbereder aldrig ett spår och spelar aldrig in.

## Tidslinjen

- **En verktygspalett** till vänster om tidslinjen med tio verktyg, vart och ett med sin bokstav: Markering A, Dela S, Trimma T, Fade F, Nivå G, Ruta B, Lasso L, Pensel P, Zooma Z och Hand H.
- **Handtag:** pekaren visar vad ett tryck tar tag i. Dra i ett klipps kant för att trimma det, i dess tonrutor för att sätta toningar och i markeringens kanter för att ändra den.
- **Spårhuvuden** med namnet, tysta, solo, förbered, ett lås, nivån och en toppmätare, och reglage för nivå och panorering när spåret är högt nog. **Spår › Lås spåret** hindrar att spåret redigeras. En klipplampa i statusfältet säger var mixen först når 0 dBFS; klicka på den för att gå dit.
- **Många spår rullar i höjdled.** Ett lodrätt svep eller hjul rullar nu alltid spåren; tiden rullar med ett svep i sidled eller ⇧ med hjulet, och med den nya rullningslisten längst ner. **Visa › Högre spår** (⌃⌘+), **Lägre spår** (⌃⌘−) och **Anpassa spår** (⌃⌘0).
- **Spår › Föregående spår** och **Nästa spår** (⌥↑, ⌥↓). ⌥← och ⌥→ flyttar de markerade klippen 10 ms, med ⇧ 100 ms.
- **Ljudmenyn är uppdelad** i Spår, Ljud, Reparera och Tal, och ett högerklick på ett klipp, ett spårhuvud eller en mixerkanal ger dess egen meny.
- **Reglage:** ett dubbelklick eller ⌥-klick ställer tillbaka ett reglage, ⌥-dragning flyttar det en tiondel så långt, och värdet bredvid ett nivå- eller panoreringsreglage går att skriva in.
- Ett spår visar hur det hörs: tystat, tyst för att ett annat har solo, med solo eller fryst.

## Spektrogrammet

- En frekvensskala vid varje spårs vänstra kant, och tiden och frekvensen under pekaren.
- En ruta går att justera i hörnen och kanterna, eller flytta genom att dra inuti den. Penseln visar hur brett den målar. Esc avbryter en ritning och lägger tillbaka området.
- **Reparera › Läk område** säger i menyn varför det inte går (längre än en halv sekund, eller allra först eller sist), i stället för att misslyckas när det har körts.

## Utskrifter och röster

- **Klang Pianissimo** för svenska och danska, med ordtider, på din Mac (Inställningar › Modeller; CC-BY-4.0, av Klang AI AB utifrån NVIDIA Parakeet), eller hos Berget AI med din egen nyckel, till Bergets publicerade pris, med en fråga före varje begäran.
- Rösternas spår namnges från fler sätt att presentera sig ("I'm Anna", "jag är Anna", "jeg er Anna"), aldrig från en nationalitet eller en dag.
- I utskriftspanelen öppnar dubbelklick eller Return på ett ord Rätta ord, och när markeringen på tidslinjen tas bort försvinner också de markerade orden.
- En klonad röst raderas bara i fönstret (**Tal › Radera klonad röst…**), aldrig av en agent.

## Mixning, surround och tempo

- **Pluginer i ett eget fönster** bredvid dokumentet (**Spår › Pluginer…**, ⌥⇧⌘P), så att mellanslag spelar medan det är öppet. Dra en plugin uppåt eller nedåt för att flytta den i kedjan. Varje mixerkanal visar sina pluginer.
- **ADM-objekt:** i ett 5.1-, 7.1- eller 7.1.4-dokument skriver Exportera ljud med "ADM-objekt för placerade spår" varje placerat spår som ett ADM-objekt (ITU-R BS.2076) med sin plats över tid, efter en bädd med allt annat. Jämmer läser tillbaka dem; de är ännu inte provade i ett annat program som renderar ADM.
- **En Ambisonics-buss kan vridas** med yaw, pitch och roll, fast eller med automation, med samma reglage och meny som ett spår som spelar ett ljudfält.
- **Hitta tempo** följer ett tempo som ändras i steg, som en tempokarta med ett tempo per sträcka. Ett tempo som glider vägras, med besked om från vad till vad och var.

## Leverera

- **Ljud › Anpassa till ACX:s krav** tar in en ljudboksfil inom ACX:s gränser för ljudnivå och toppar i ett steg, och använder begränsaren bara när topparna är i vägen.
- **Arkiv › Lagring…** öppnas direkt och läser i bakgrunden, med Uppdatera och Visa i Finder.

## Stoppa och betaltjänster

- Varje jobb, och varje väntan som tar mer än en halv sekund, syns i statusfältet med en Stoppa som stoppar bara det (**Redigera › Stoppa jobbet**). Ett stoppat jobb ändrar ingenting, och det som redan är betalt och har kommit tillbaka sparas.
- Return skickar aldrig en betald begäran och raderar aldrig; Esc avbryter.
- Assistentens textförfrågningar till en betaltjänst visar priset vid första förfrågan; kryssa i tjänsten en gång så frågar Jämmer inte mer, och kryssa ur den i **Inställningar › Betaltjänster**.

## För agenter

- Nytt: `POST …/export` `objects`, `set_bus` `yaw`/`pitch`/`roll`, `set_insert` `position`, `select_track`, `move_clip`, `set_clip`, `acx_match`, `set_take` och `GET …/recording`, `DELETE /api/v1/documents/{id}`, och `POST /api/v1/transcribe` och `/transcribe/file` för en annan apps textning.
- `detect_tempo` svarar med `tempi`, och `GET …/analysis/rhythm` med `segments`. En sparning av ett länkat dokument svarar när filen är skriven. Ett anrops metod och värden kontrolleras innan det kontrolleras om dokumentet är öppet.
- `delete_voice` är borttagen: att radera en klonad röst är personens eget beslut.

## Också

- Ingenting i fönstret blinkar mer än tre gånger i sekunden.
- Appen heter nu Jämmer.app, i Jämmer-<VERSION>.zip.
- Jämmer samarbetar bara med en Glimmer eller Flimmer av exakt samma sort (en utgiven app med utgivna appar).
