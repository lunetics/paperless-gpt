# Fork-Container warten und veröffentlichen

Dieser Fork veröffentlicht stabile Linux/AMD64-Container nach GHCR. Ein
Release entsteht nur durch einen Push eines Tags im Format `vX.Y.Z`. Der
Workflow führt Frontend- und Backend-Prüfungen in Containern aus, baut das
Release-Image einmal, testet genau dieses Image mit der geheimnisfreien
Mock-LLM-E2E-Prüfung und versieht es anschließend mit dem Versions-Tag. Der
bewegliche Tag `latest` wird nur auf eine neuere stabile Version gesetzt.
Bereits veröffentlichte Versions-Tags werden nicht überschrieben.

## Containerprüfungen lokal ausführen

Die Release-Prüfungen verwenden ausschließlich Wegwerf-Container. Vom
Repository-Root aus entsprechen diese Befehle dem geheimnisfreien CI-Pfad:

```bash
docker build --target frontend-test .
docker build --target backend-test .
docker build --platform linux/amd64 --tag paperless-gpt:e2e-local .
./scripts/verify-containers.sh paperless-gpt:e2e-local
```

Der letzte Befehl startet einen isolierten Playwright-/Testcontainers-Runner
gegen genau das angegebene Image. Er benötigt einen laufenden Docker-Daemon;
keine lokale Node-, Playwright- oder Go-Installation ist erforderlich.

## Image auswählen und bereitstellen

Verwende für einen Wechsel zuerst einen unveränderlichen Versions-Tag oder
einen Digest, beispielsweise:

```yaml
image: ghcr.io/lunetics/paperless-gpt:vX.Y.Z
# Nach dem Ablesen des Release-Digests bevorzugen:
# image: ghcr.io/lunetics/paperless-gpt@sha256:<digest>
```

Vor dem Wechsel die vorhandene Compose- oder andere Laufzeitkonfiguration
sichern. Bestehende Umgebungsvariablen, Prompt-Konfiguration und persistente
Volumes bleiben erhalten. Das aktualisierte Image zuerst mit der vorhandenen
Konfiguration starten, den Webserver prüfen und eine nicht sensible
Beispielverarbeitung einschließlich Metadaten kontrollieren. Erst danach darf
eine Umgebung auf das neue Image zeigen. `latest` eignet sich für Tests, aber
nicht als alleiniger Rollback-Anker.

Zum Rollback wieder den zuvor notierten Versions-Tag oder Digest in der
Konfiguration eintragen und mit denselben Umgebungsvariablen und Volumes
starten. Anschließend Webserver und eine Beispielverarbeitung erneut prüfen.
Ein Rollback löscht keine Daten und verlangt kein Überschreiben eines
veröffentlichten Images.

Der vorhandene Proxy bleibt zunächst Teil der Konfiguration. Für Think-Anfragen
zuerst den unveränderten Originalrequest vor einer möglichen Proxy-Umschreibung
belegen. Eine Entfernung der Think-Injektion ist ein separat freizugebender
Betriebswechsel, keine Folge eines Container-Releases.

Für Ollama-Metadaten mit Temperatur 0 und deaktiviertem Thinking können nur die
folgenden zwei Zeilen zur bestehenden Laufzeitkonfiguration ergänzt werden:

```yaml
environment:
  LLM_TEMPERATURE: "0"
  OLLAMA_THINK: "false"
```

Alle vorhandenen Umgebungsvariablen, insbesondere Zugangsdaten,
Provider-Konfiguration und Proxy-Einstellungen, bleiben dabei unverändert. Die
Werte gelten für den Ollama-Metadatenpfad; sie ersetzen keine bestehende
Vision-/OCR-Konfiguration. Temperatur 0 garantiert keine identischen Antworten.

## Stabilen Release-Tag erstellen und prüfen

Vor einem Release eine noch nicht verwendete stabile Version auswählen. Der
Workflow akzeptiert nur `vX.Y.Z` ohne führende Nullen in den Komponenten. Das
Beispiel verwendet absichtlich einen Platzhalter:

```bash
git fetch origin --tags
git ls-remote --tags origin 'refs/tags/vX.Y.Z'
git tag -a vX.Y.Z -m 'Release vX.Y.Z'
git push origin vX.Y.Z
```

Die Ausgabe von `git ls-remote` muss vor der Tag-Erstellung leer sein. Nach
einem erfolgreichen Actions-Lauf das Versions-Image von einem Client ohne
Registry-Anmeldung ziehen und den Digest festhalten:

```bash
docker pull ghcr.io/lunetics/paperless-gpt:vX.Y.Z
docker image inspect ghcr.io/lunetics/paperless-gpt:vX.Y.Z \
  --format '{{index .RepoDigests 0}}'
```

Zusätzlich die Paket-Sichtbarkeit in GHCR prüfen. Der anonyme Pull und der
angezeigte Versions-Tag sowie `latest` müssen auf denselben Digest zeigen,
wenn `latest` auf diese Version fortgeschritten ist. Den Release-Tag, den
Commit und den Digest zusammen in den Release-Notizen dokumentieren.

Falls nur der Publish-Job nach erfolgreicher Prüfung scheitert, innerhalb der
eintägigen Artefakt-Aufbewahrung in GitHub Actions ausschließlich den
fehlgeschlagenen Publish-Job erneut ausführen. Er lädt dann das schon geprüfte
Image-Artefakt, vergleicht dessen Image-ID und setzt gegebenenfalls `latest`
fort. Keine Images neu bauen und keinen vorhandenen Versions-Tag manuell
überschreiben. Ist das Artefakt abgelaufen, zuerst den Release-Zustand prüfen
und den Wiederanlauf gezielt planen.

## Upstream nachziehen

Die veröffentlichte Fork-Historie wird nicht umgeschrieben. Neue Upstream-Stände
werden auf einem Integrationsbranch vom aktuellen Fork-Hauptbranch verarbeitet:

```bash
git fetch upstream --tags
git switch main
git pull --ff-only origin main
git switch -c integrate-upstream-<date>
git merge upstream/main
```

Konflikte gezielt lösen, die vollständigen Containerprüfungen ausführen und
einen Pull Request in den Fork eröffnen. Nach dessen Merge folgt ein neuer
stabiler Versions-Tag. Eine Freigabe verlangt außerdem die Prüfung, dass das
GHCR-Paket öffentlich lesbar ist und der dokumentierte Digest anonym gezogen
werden kann.

## Änderungen wieder an Upstream geben

Adapter und Temperatur bleiben zwei fachlich getrennte Commits; CI und
Fork-Betriebsdokumentation sind davon getrennt. Ein Upstream-PR entsteht von
einem neuen Branch auf dem aktuellen Upstream-Stand und enthält nur die
passenden Adapter-/Temperatur-Commits. Beide Commits gehören in denselben PR,
weil die Temperatur-Erweiterung den Adapter voraussetzt. Vor dem Einreichen
synthetische Wire-Evidenz und die Containerprüfungen beilegen, aber keine
Fork-Releasepolitik oder interne Betriebsdaten.

Ein möglicher Fix für LangChainGo gehört als eigener Patch in dessen Repository.
Dieser Fork nutzt den nativen Adapter und benötigt ihn daher nicht. Das bekannte
Problem ist in [tmc/langchaingo#1514](https://github.com/tmc/langchaingo/issues/1514)
dokumentiert.
