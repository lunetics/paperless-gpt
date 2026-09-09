# Umsetzungsplan: nativer Ollama-Client und eigene GHCR-Releases

Stand: 2026-09-09, Planung abschließend geprüft. Ausgangscommit: `72ddde7`.
Arbeitsbranch: `feat/native-ollama-fork`.
Fork: `lunetics/paperless-gpt`; Upstream: `icereed/paperless-gpt`.

Dieser Plan wurde vor der Implementierung verfasst und dokumentiert den damals
vorgesehenen Ablauf. Aktuelle Implementierungs- und Prüfergebnisse stehen in den
zugehörigen Pull Requests und, sobald etwas veröffentlicht ist, in den Release-Notizen.
Dieses Dokument behauptet keine bereits erfolgte Veröffentlichung.

## Entscheidungen und Umfang

- Nur die Metadaten-LLM für `LLM_PROVIDER=ollama` bekommt den offiziellen Client
  `github.com/ollama/ollama/api`, hinter der bestehenden Schnittstelle `llms.Model`.
- Die sechs Metadaten-Aufrufe, die Prompt-Vorschau und `NewRateLimitedLLM` behalten
  ihre Schnittstellen. Die übrigen vier Anbieter und sämtliche Vision-/OCR-Konstruktoren
  behalten ihre bisherigen Implementierungen.
- `LLM_TEMPERATURE` wird zunächst ausschließlich für Metadaten über Ollama unterstützt.
  Für andere Anbieter wird diese Einschränkung ausdrücklich dokumentiert; eine gesetzte
  Variable erzeugt dort einen verständlichen Hinweis statt eines Wirkungsversprechens.
- Ohne `LLM_TEMPERATURE` bleibt die bisher tatsächlich übertragene Temperatur `0` erhalten.
  Ein gültiger Wert überschreibt sie; ein ungültiger Wert wird mit Warnung ignoriert.
  `0` muss ausdrücklich im HTTP-JSON stehen bleiben. Negative und nicht endliche Werte
  (`NaN`, `Inf`) werden ebenfalls abgewiesen; keine erfundene Obergrenze einführen.
- `OLLAMA_THINK` bleibt dreiwertig: nicht gesetzt = Feld fehlt, `true` = JSON true,
  `false` = JSON false. Ungültige Werte werden wie bisher mit Warnung ignoriert.
- Der vorhandene Proxy bleibt vollständig unverändert. Eine spätere Entfernung seiner
  Think-Injektion und ein Wechsel des produktiven Images benötigen die ausdrücklich
  im Auftrag verlangte Betriebsfreigabe. Resolver, Token-Deckelung und Protokollierung
  sind kein Teil dieses Umbaus.
- Alle Installationen, Builds, Formatierungswerkzeuge und Tests laufen in Wegwerf-Containern.
  Keine Go-/npm-Installation auf dem Host, keine Verwendung produktiver Dokumente oder Schlüssel.

## Phase 0 — Quellenprüfung und technische Grundlage

### Bereits geprüft

| Befund | Quelle / zu lesendes Muster |
| --- | --- |
| `createLLM() (llms.Model, error)`, Ollama-Konfiguration, HTTP-Client und Wrapper | `main.go:1032`, Ollama-Zweig ab `main.go:1091` |
| Sechs Metadaten-Aufrufe ohne CallOptions | `app_llm.go:59`, `129`, `237`, `307`, `363`, `466` |
| Zusätzlich existiert ein `Call`-Aufruf in der Prompt-Vorschau | `app_http_handlers.go:1072` |
| Wrapper reicht beide Modellmethoden und Optionen weiter | `llm_client.go:24`, `115`; Konstruktor `llm_client.go:82` |
| Ollama-Header müssen weiter funktionieren | `ocr/llm_provider.go:230`, Funktion `OllamaHTTPClient()` |
| Eigenständige Vision-Konfiguration | `main.go:1180` ff., `ocr/llm_provider.go:157` und `269` |
| Env-Parsing als Vorlage | `main.go:257` ff., `VISION_LLM_TEMPERATURE` |
| Tatsächliches Frontend-Embedding ist `web-app/dist/*` | `embedded_assets.go:14`, `Dockerfile:63` |
| Build verwendet Go 1.25.5, Modul nennt Go 1.24.4 und Toolchain 1.25.5 | `Dockerfile:28`, `go.mod:3` |
| Fork existiert bereits und zeigt auf den richtigen Parent | GitHub-API für `repos/lunetics/paperless-gpt`, geprüft am Plandatum |

**Korrektur einer Auftragsannahme:** Langchaingo v0.1.14 sendet im aktuellen Pfad
bereits `temperature: 0`: Die Options-Struktur verwendet hier kein `omitempty`, und
`GenerateContent` kopiert den ungesetzten Go-Nullwert. Der angenommene wirksame
Ollama-Standard `0.8` erklärt das Verhalten dieses Checkouts daher nicht.
Das neue Feature macht die Temperatur konfigurierbar; es behebt keinen bewiesenen
Temperatur-0.8-Fehler. Den tatsächlichen bisherigen Body zusätzlich im Regressionstest belegen.
Quellen: [langchaingo Options](https://github.com/tmc/langchaingo/blob/v0.1.14/llms/ollama/internal/ollamaclient/types.go#L150)
und [Options-Zuordnung](https://github.com/tmc/langchaingo/blob/v0.1.14/llms/ollama/ollamallm.go#L310).

Der Think-Fehler ist dagegen im gepinnten Quellcode bestätigt: `Think bool` liegt in
`Options` mit `omitempty`; `ChatRequest` besitzt kein eigenes Think-Feld.
Die Issues [paperless-gpt #1024](https://github.com/icereed/paperless-gpt/issues/1024)
und [langchaingo #1514](https://github.com/tmc/langchaingo/issues/1514) waren am Plandatum offen.

### Erlaubte APIs und Versionsentscheidung

Geprüfte Kandidatenversion: **Ollama v0.13.5**, Modulanforderung Go 1.24.1.
Sie enthält bereits die benötigte Think-Semantik und passt auf Ebene der Go-Anforderung
zur vorhandenen Build-Toolchain. Ollama v0.33.3 verlangt dagegen Go 1.26.0.
Client- und Serverversion müssen nicht dieselbe Versionsnummer haben; die tatsächlich
verwendeten Requests müssen jedoch gegen den Zielserver validiert werden.

Version v0.13.5 dient als konkret geprüfter Ausgangspunkt, nicht als Behauptung über
die neueste kompatible Version. Vor Implementierung einmal im Container den Modulgraphen,
verfügbare neuere kompatible Tags und die benötigten API-Felder prüfen; eine geeignete
Version exakt pinnen. Kein pauschales `@latest` und kein stilles Toolchain-Upgrade.
Falls eine neue Toolchain nötig wird, Build-Anpassung als eigenen Commit dokumentieren.

Vor dem Implementieren diese Quellen lesen:

- [Ollama v0.13.5 go.mod](https://github.com/ollama/ollama/blob/v0.13.5/go.mod)
  und zum Vergleich [v0.33.3 go.mod](https://github.com/ollama/ollama/blob/v0.33.3/go.mod).
- [Ollama Client v0.13.5](https://github.com/ollama/ollama/blob/v0.13.5/api/client.go#L81):
  `api.NewClient(base *url.URL, http *http.Client) *api.Client`.
- Dieselbe Datei ab Zeile 287:
  `type ChatResponseFunc func(ChatResponse) error` und
  `(*api.Client).Chat(context.Context, *api.ChatRequest, api.ChatResponseFunc) error`.
- [Ollama Typen v0.13.5](https://github.com/ollama/ollama/blob/v0.13.5/api/types.go#L131):
  `ChatRequest.Model`, `Messages`, `Options map[string]any`, `Stream *bool`,
  `Think *ThinkValue`; `Message.Content` und `Message.Thinking` ab Zeile 195;
  `ThinkValue{Value: false}` ab Zeile 908.
- [Langchaingo Modellinterface](https://github.com/tmc/langchaingo/blob/v0.1.14/llms/llms.go#L15),
  [CallOptions](https://github.com/tmc/langchaingo/blob/v0.1.14/llms/options.go)
  und [Antworttypen](https://github.com/tmc/langchaingo/blob/v0.1.14/llms/generatecontent.go).

**Verifikation:** Container-Spike kompiliert mit der gewählten Version und ruft einen
lokalen HTTP-Testserver über den echten offiziellen Client auf. Modul-/Toolchain-Diff
prüfen. Neue direkte Abhängigkeit ist das Ollama-Modul, kein erfundenes separates `/api`-Modul.

**Grenzen:** Keine Serverimplementierung, kein langchaingo-Fork als Ersatz für den nativen
Client und kein Neubau der Ollama-HTTP-Serialisierung. Aussagen aus alten Planungsdateien
ersetzen diese Quellenprüfung nicht.

## Phase 1 — Nativer Adapter und korrekte Think-Übertragung

Vorgesehene Dateien: neu `ollama_metadata.go`, `ollama_metadata_test.go`; gezielt
`main.go`, `go.mod`, `go.sum`. Commit: `fix(ollama): use native client for metadata requests`.

1. Aus den oben genannten offiziellen Client-/Typmustern einen textbasierten
   `OllamaMetadataModel` implementieren und das Interface zur Compile-Zeit absichern:

   ```go
   var _ llms.Model = (*OllamaMetadataModel)(nil)
   ```

2. `GenerateContent(ctx, messages, options...)` implementieren. `Call(ctx, prompt,
   options...)` delegiert nach dem bestehenden Bibliotheksmuster über
   `llms.GenerateFromSinglePrompt(ctx, model, prompt, options...)`.
3. Human/System/AI auf `user`/`system`/`assistant` abbilden und Textteile übernehmen.
   Nicht unterstützte Bild-/Tool-Eingaben klar als Fehler melden. Dieser Adapter wird
   ausschließlich an den textbasierten Metadatenpfad angeschlossen.
4. Konfigurierten Host einschließlich bisher gültiger URL-Formen, Modell,
   `OLLAMA_CONTEXT_LENGTH` und `ocr.OllamaHTTPClient()` übernehmen. Bei nil einen
   funktionierenden Standard-HTTP-Client verwenden. Header-Test auch für Werte mit `=`.
   Konstruktor erzeugt keine Modell-Pulls und keine zusätzlichen Netzwerk-Probes.
5. `Think` bei gültiger Angabe mit `&api.ThinkValue{Value: parsedBool}` setzen;
   andernfalls nil lassen. `temperature: 0` zunächst zur Verhaltenskompatibilität
   direkt über die Options-Map übernehmen. `num_ctx` nur bei gültiger Konfiguration.
6. Standardaufrufe senden ausdrücklich `Stream: &false`. Native Callback-Antworten
   sammeln, erfolgreiche vollständige Antwort prüfen und genau eine nutzbare Choice
   zurückgeben. Ein leerer, abgebrochener oder ausschließlich denkender Response ist
   ein Fehler statt eines Panics beim Zugriff auf `Choices[0]`.
7. `Message.Content` bildet das Antwortfeld. `Message.Thinking` niemals hineinmischen;
   gesammelt in `ContentChoice.ReasoningContent` zurückgeben. Dieses Feld existiert
   bereits in der gepinnten Schnittstelle; der Metadatenparser liest weiterhin nur
   `Content`. `DoneReason` auf `StopReason` abbilden. Bestehendes Entfernen inline
   ausgegebener Reasoning-Tags bleibt wirksam. Tokenzahlen mit den vorhandenen GenerationInfo-Schlüsseln
   `CompletionTokens`, `PromptTokens`, `TotalTokens` erhalten.
8. Streaming bewusst abdecken: Bei `StreamingFunc` oder `StreamingReasoningFunc`
   `stream=true` setzen, Content und Thinking getrennt an die jeweiligen Callbacks
   liefern und Callback-Fehler weiterreichen. Bei gleichzeitig gesetzten Callbacks
   beide je Chunk genau einmal aufrufen, ohne Thinking als normalen Content auszugeben.
   Die sechs Produktionsaufrufe nutzen
   weiterhin den nicht streamenden Modus. Die vorhandene äußere Retry-Semantik bleibt
   erhalten; sie kann bei einem Stream-Neustart erneut Chunks liefern und ist hier
   kein Anlass für einen allgemeinen Retry-Umbau.
9. Verwendete CallOptions anhand der tatsächlichen Felder abbilden: Modell,
   Temperatur, MaxTokens→`num_predict`, StopWords→`stop`, JSONMode→Format `"json"`
   und Sampling-Optionen anhand der Zuordnung in `ollamallm.go:310` ff.
   Options-Maps je Request neu anlegen, damit parallele Aufrufe keine Konfiguration teilen.
   Keine still verworfenen Streaming-Callbacks oder
   Tool-Anforderungen. Keine neuen erzwungenen Tokenlimits oder JSON-Modi.
10. Kontext an `Client.Chat` weiterreichen, Fehler mit `%w` erhalten. Im Ollama-Zweig
    weiterhin `NewRateLimitedLLM(model, getRateLimitConfig(false))` zurückgeben.

**Verifikation:** `httptest.Server` zeichnet den tatsächlich empfangenen Body des
offiziellen Clients auf. Matrix: Think fehlt/true/false/ungültig, `options.think` fehlt
immer, Temperatur zunächst 0, Host/Pfad `/api/chat`, Modell, Kontextlänge, Header,
`stream=false`. Ergänzend Tests für `Call`, Rollen, Streaming-Chunks/Callback-Abbruch,
Thinking-Trennung, leere Antwort, ungültiges JSON, HTTP-/API-Fehler und Kontextabbruch.
Mindestens ein Test startet über `createLLM()` und erreicht den Server durch den Wrapper.
Die gezielten Tests bereits in dieser Phase in einem temporären Container ausführen;
Phase 3 macht diesen Ablauf anschließend vollständig und wiederverwendbar.

**Grenzen:** Keine Änderungen an `app_llm.go`, `llm_client.go` oder Vision-Konstruktoren
erforderlich. Langchaingos Ollama-Import darf für die weiterhin bestehenden Vision-Pfade
nötig bleiben. Kein globales Entfernen der Bibliothek.

## Phase 2 — Konfigurierbare Metadaten-Temperatur

Vorgesehene Dateien: Adapter/Konstruktor und Tests aus Phase 1, `README.md` und
gegebenenfalls vorhandene Env-Beispiele. Commit: `feat(ollama): add metadata temperature setting`.

1. Env-Parsing nach dem Muster `main.go:257` übernehmen: `strconv.ParseFloat`,
   Warnung bei ungültiger Eingabe, bestehender Default bleibt wirksam.
2. Optionalen Konfigurationswert darstellen, z. B. mit `*float64`; Default 0 einmal
   vor dem Anwenden der CallOptions setzen. CallOptions dann genau einmal anwenden,
   sodass auch ein explizites `llms.WithTemperature(0)` einen konfigurierten Wert überschreibt.
3. Den Wert direkt als `Options["temperature"]` setzen. Kein Umweg über eine
   `omitempty`-Options-Struktur, der den expliziten Nullwert wieder verlieren könnte.
4. Env-Tabelle ab `README.md:558` ergänzen: Metadaten/Ollama, Default 0, Warnverhalten,
   Abgrenzung zu `VISION_LLM_TEMPERATURE`, Nichtunterstützung bei anderen Providern.
   Temperatur 0 nicht als Garantie identischer Antworten darstellen.

**Verifikation:** Über `createLLM()` aufgezeichnete Bodies für nicht gesetzt, leer,
`0`, `0.2`, ungültig, negativ, `NaN`, `Inf`; gültige Overrides einschließlich 0.
Andere Provider erhalten die neue Einstellung nicht. Vision behält ihren eigenen Wert.
Die beiden Kernnachweise zusammen als synthetisches, geheimnisfreies Beispiel sichern:

```json
{
  "model": "test-model",
  "messages": [{"role": "user", "content": "Return a title"}],
  "stream": false,
  "think": false,
  "options": {"temperature": 0}
}
```

**Grenzen:** Nicht aus einem Konfigurationslog auf den gesendeten Wert schließen.
Keine Temperatur-Injektion in OCR oder die übrigen Provider; keinen Resolver-Mitschnitt
hinter dessen Body-Umschreibung als alleinigen Beweis verwenden.

## Phase 3 — Vollständige Verifikation in Wegwerf-Containern

Vorgesehene Dateien: gezielte Test-Stages in `Dockerfile` oder separate Test-Dockerfiles,
bei Bedarf ein kleines Prüfskript und E2E-Runner-Konfiguration.
Commit: `test: add disposable container verification`.

**Vorlagen lesen:** `Dockerfile:7`, `28`, `63`, `65`, `84`;
`paperless_test.go:409` und weitere Fixture-Verwendungen;
`web-app/package.json:11`, `web-app/e2e/test-environment.ts:60`–`149`,
`web-app/e2e/setup/global-setup.ts:15`, `.dockerignore:3`.

1. Frontend mit Lockfile (`npm ci`) im Node-Container installieren, linten und bauen.
   `npm test` ist nur ein Platzhalter und kein Nachweis.
2. Backend-Teststage aus dem vorhandenen Builder mit CGO/mupdf ableiten; `tests/`
   und `default_prompts/` zusätzlich kopieren. Der bisherige Builder allein enthält
   die für den vollständigen Testlauf benötigten Fixtures nicht.
3. Im Container Formatierung prüfen und `CGO_ENABLED=1 go test -tags musl ./...`
   ausführen; vollständigen Anwendungsbuild mit Frontend-Embedding erstellen.
   Test-Stages dürfen nicht versehentlich zum ausgelieferten Standard-Runtime-Image werden.
4. Bestehende Tests für andere Provider/OCR ausführen und synthetische lokale
   Provider-Smokes ergänzen, wo ein konkreter Kompatibilitätsnachweis fehlt. Keine
   kostenpflichtigen Live-LLM-Aufrufe voraussetzen; Build/Mock-Tests belegen nicht
   pauschal die aktuelle Funktionsfähigkeit jedes externen Dienstes.
5. Das gebaute Image mit Testkonfiguration starten, Webserver/API-Start und ausgeliefertes
   Frontend auf Port 8080 im isolierten Testumfeld prüfen.
6. `npm run test:e2e:mock` gegen dieses Image aus einem Wegwerf-Playwright-Runner
   ausführen. Runner-Version an das Lockfile anpassen. Testcontainers benötigt Zugriff
   auf Docker und die veröffentlichten Testports: Der Helper verwendet derzeit
   `localhost`. Linux-Hostnetzwerk für den Runner verwenden oder auf `getHost()`
   korrigieren. E2E-Dateien trotz `.dockerignore` gezielt in den Runner bringen.
   Nur eigens erzeugte Testressourcen aufräumen, kein globales Docker-Pruning.

**Verifikation:** Alle genannten Prüfungen bestehen; Request-Assertions und Testergebnisse
als Artefakte ohne interne Konfiguration sichern. npm mindestens 300 s, Go mindestens
600 s, Docker mindestens 1800 s einplanen; langsame Builds nicht abbrechen.

**Grenzen:** Kein Host-`go test`, Host-`npm install` oder Test gegen die laufende Installation.
Root-`dist/` aus älteren Setup-Texten ist hier nicht die maßgebliche Embed-Quelle.

## Phase 4 — Fork-Releases nach GHCR

Vorgesehene Dateien: Fork-Release-Workflow, gezielte Trigger-/Publish-Abgrenzung im
bestehenden Workflow, öffentliche Release-Dokumentation.
Commit: `ci: publish tested fork releases to ghcr`.

**Vorlagen lesen:** `.github/workflows/docker-build-and-push.yml:7`, `11`, `74`,
`79`, `94`, `171`, `248`, `308`, `378`; `Dockerfile:71`.
Die bestehenden `docker/login-action@v3`-/`docker/build-push-action@v6`-Muster übernehmen.

Bereits vorhanden: Fork-GHCR-Push mit `GITHUB_TOKEN`, kein Docker-Hub-Push für Forks.
Lücken: Fork-`latest` wandert bei Main-Pushes; Versions-Tags aktualisieren es nicht.
Zwei Architekturen werden verlangt. Mock-E2E läuft nur bei PRs und sperrt Releases nicht.

1. Ein klarer Release-Auslöser: Tag-Push; Tags zusätzlich streng auf `vX.Y.Z` prüfen.
   Keine doppelte Veröffentlichung desselben Tags durch einen zweiten Release-Trigger.
2. Zielimage aus dem kleingeschriebenen Repositorynamen ableiten:
   `ghcr.io/lunetics/paperless-gpt`. `linux/amd64` genügt.
3. Berechtigungen auf Jobs begrenzen: Tests `contents: read`, Veröffentlichung zusätzlich
   `packages: write`; Login mit `GITHUB_TOKEN`, keine Docker-Hub-Secrets.
4. Containerprüfungen aus Phase 3 inklusive Mock-E2E als Voraussetzung der Veröffentlichung
   einbauen. Einmal gebautes, getestetes Image übernehmen und beide Tags auf denselben
   Inhalt/Digest setzen. Kein ungetesteter Neubau zwischen Test und Veröffentlichung.
5. Versionsmetadaten (`VERSION`, `COMMIT`, `BUILD_DATE`) korrekt setzen und OCI-Quelle
   mitführen. Lockfiles und geeignete Image-Digests pinnen; Zeitmetadaten dokumentieren.
   Reproduzierbarer Ablauf ist noch keine bewiesene bitidentische Reproduktion.
6. Versions-Tag und `latest` veröffentlichen; parallele Releases serialisieren.
   Ältere Wartungsreleases dürfen `latest` nicht hinter eine neuere stabile Version setzen.
   Bestehende Versions-Tags nicht überschreiben.
7. Alten Workflow so abgrenzen, dass er im Fork weder konkurrierendes `latest` publiziert
   noch zusätzlich ARM64 erzwingt. Main/PR bleibt Testpfad; optionale Entwicklungsimages
   bekommen ausschließlich eigene SHA-/PR-Tags. Kein Package-Write aus fremdem PR-Code.
8. Erstes freies Fork-Release bestimmen (Vorschlag `v0.27.1`, vor Tag-Erstellung prüfen),
   öffentlichen Paket-Zugriff prüfen und den Digest dokumentieren. Ein anonymer Pull
   muss funktionieren. Registrierungs-/Sichtbarkeitseinstellungen sind noch ungeprüft.

**Verifikation:** Workflow-Prüfung, erfolgreicher Actions-Lauf, Image für amd64,
Version und `latest` mit gleichem Digest, anonymer Pull und Smoke-Test des gezogenen
Images. Release-URL, Commit, Tags und Digest als Ergebnis festhalten.

**Grenzen:** Bestehende ungeprüfte Real-LLM-Jobs nicht als Freigabenachweis verwenden;
der alte Fork-Main-Pfad erwartet außerdem einen nicht passend gebauten
`unreleased-amd64`-Tag. Kein automatisches Deployment an den Zielbetrieb.

## Phase 5 — Betriebsanleitung und Upstream-Anschluss

Vorgesehene Dateien: neu `docs/fork-maintenance.md`, README-Verweis.
Commit: `docs: document fork releases and upstream maintenance`.

**Vorlagen lesen:** `CONTRIBUTING.md:50`, `145`, `162`, bestehende Compose-/Image-Beispiele
in `README.md`. Beispiele ausschließlich mit Platzhaltern und öffentlichen Image-Namen.

1. Anleitung für späteren NAS-Imagewechsel: Konfiguration sichern, zunächst Version/Digest
   statt beweglichem `latest` wählen, bestehende Env/Volumes erhalten, Start und
   Metadatenverarbeitung prüfen. Rollback auf vorherigen Digest beschreiben.
2. Proxy zunächst beibehalten. Nachweis der unveränderten Originalanfrage vor der
   Think-Umschreibung verwenden; erst separat freigegeben dessen Think-Injektion entfernen.
3. Upstream-Nachziehen dokumentieren: `git fetch upstream --tags`, Integrationsbranch
   vom Fork-Hauptbranch, Upstream-Stand regulär mergen, Konflikte gezielt lösen,
   vollständige Containerprüfung, PR in den Fork und neues Release. Veröffentlichte
   Fork-Historie nicht umschreiben.
4. Adapter und Temperatur als getrennte fachliche Commits halten, CI/Doku separat.
   Upstream-PR-Branch vom aktuellen Upstream erzeugen und nur die passenden Feature-
   Commits übernehmen. Die Temperatur-Erweiterung baut auf dem Adapter auf; zwei
   getrennte Commits bedeuten hier nicht zwei unabhängig kompilierende PRs.
5. Sinnvoller erster PR an `icereed/paperless-gpt`: Adapter plus Temperatur, mit
   synthetischer Wire-Evidenz und ohne Fork-Releasepolitik. Unveränderte Cherry-picks
   sind das Ziel für den geprüften Basisstand, keine Garantie für künftige Upstream-Konflikte.
6. Ein Fix an `tmc/langchaingo` wäre ein eigenständiger Patch in einem anderen Repository,
   kein übertragbarer Adapter-Commit. Für diesen Fork nicht erforderlich; zunächst
   bewusst nicht als zweites Implementierungsprojekt beginnen. Entscheidung in der
   Abschlussdokumentation begründen; #1514 als existierende Fehlerdokumentation verlinken.
7. Öffentliche PR-Beschreibung vor Einreichung auf interne Details prüfen. Im
   Implementierungsauftrag vorgesehene PRs erst mit vollständigem, validiertem Diff
   einreichen; diese Planungsrunde reicht keinen PR ein.

**Verifikation:** Anleitungen lassen sich allein mit Repo und Platzhalterkonfiguration
befolgen. Feature-Commits auf Upstream-Basis prüfen. PR-URL oder konkrete Begründung
des Unterlassens festhalten; keine internen Hostnamen, Adressen, Pfade oder Dokumente
in neuen Diffs, Testfixtures und öffentlichen Beschreibungen.

## Phase 6 — Abschlussprüfung

1. Implementierung gegen die in Phase 0 gepinnten APIs und jede Anforderung dieses
   Plans prüfen; keine unbemerkten Änderungen an Vision und anderen Providern.
2. Gezielte Diff-/Quelltextprüfung: kein Metadaten-`ollama.WithThink`, kein Think in
   `options`, kein temperaturverlierendes `omitempty`, keine Secrets, keine konkurrierenden
   Fork-`latest`-Publisher. Der alte Vision-Import ist dabei zulässig.
3. Vollständige Containerchecks nach dem letzten relevanten Code-/Workflow-Diff ausführen.
   Bestandene Prüfungen ohne weitere Änderungen nicht unnötig wiederholen.
4. Fertig bedeutet: natives Ollama nachweislich `think:false` und `temperature:0` im
   empfangenen HTTP-Body, kompatible übrige Pfade, erfolgreich publiziertes GHCR-Image,
   Pull-/Startnachweis, Betriebs-/Upstream-Anleitung und dokumentierter PR-Status.
5. Übergabe nennt Commit, Release, Digest, Wire-Nachweis, Testergebnisse und verbleibende
   Grenzen. Produktiver Imagewechsel und Proxyänderung bleiben ein späterer eigener Schritt.

## Verbleibende technische Prüfungen, keine blockierenden Nutzerfragen

- Exakte Ollama-Modulversion nach Containerprüfung des Modulgraphen festschreiben.
- Actions-Berechtigungen, öffentliche GHCR-Sichtbarkeit und freie Versionsnummer prüfen.
- Container-E2E-Runner mit Docker-Portzugriff einmal vollständig erproben.
- Ungetrackte vorhandene Dateien außerhalb dieses Plans bleiben erhalten.

Routineentscheidungen werden autonom getroffen. Rückfragen sind nur nötig, wenn eine
wesentliche, nicht aus Auftrag und Quellen ableitbare Entscheidung oder eine explizit
geschützte Betriebsaktion ansteht. Technische Sandbox-Freigaben sind davon unabhängig.

## Nachtrag — Generationseinstellungen pro Prompt

Nach der ursprünglichen Planung wurde der Umfang um Ollama-Einstellungen für die
Metadatengenerierung erweitert. Vorgesehen sind `LLM_MAX_TOKENS` als
`num_predict`-Ausgabebudget, `OLLAMA_KEEP_ALIVE`, Thinking mit booleschen Werten
oder den Stufen `low`, `medium`, `high` sowie eine optionale JSON-Datei mit
Defaults und Einstellungen pro Prompt. Die Priorität lautet Modell/Basis,
Datei-Defaults, gültige Umgebungswerte, Prompt-Einstellungen und schließlich
explizite CallOptions. Vision OCR und Prompt-Templates bleiben außerhalb dieses
Umfangs.

`TOKEN_LIMIT` bleibt die bestehende Eingabekürzung. Es ist weder das
Ausgabebudget noch das Ollama-Kontextfenster `num_ctx`; auch eine per-Prompt-
`num_ctx`-Einstellung verändert die Eingabekürzung nicht automatisch. Format
wird nicht allgemein aktiviert: Es ist ausschließlich für Custom Fields und
Ad-hoc-Analyse vorgesehen, damit bestehende Text- und CSV-Verbraucher
unverändert bleiben.

**Stand der Verifikation:** Wire-Tests für die Prioritätsstufen, die strenge
Validierung einer ausdrücklich gesetzten Settings-Datei und die vollständige
Go-Prüfung sind bestanden. Diese Tests prüfen das Ollama-Protokoll mit Mocks,
nicht die Qualität oder das tatsächliche Verhalten eines einzelnen Modells. Die
Runtime- und Mock-E2E-Prüfung im Wegwerfcontainer ist bestanden: Das geprüfte
Runtime-Image hatte die ID
`sha256:b0d5b57d46f856c31e0e2fec93b38265c31f6a56c678c40c0cce667cd8edaef8`,
und die Mock-E2E-Ausgabe `.last-run.json` meldete Erfolg. Der Nachweis bleibt
Mock-/Protokollprüfung und ist kein Qualitätslauf gegen ein echtes Modell. Die
Erweiterung ergänzt den bestehenden Upstream-PR; Prompt-Templates bleiben einer
folgenden Änderung vorbehalten.
