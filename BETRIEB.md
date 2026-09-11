# Betrieb

Wie dieses Twenty lokal und auf dem Server betrieben wird. Fuer die
Ersteinrichtung des Servers siehe `deploy/README.md`.

---

## Portbelegung lokal

Auf dem Entwicklungsrechner laufen parallel andere Projekte. Twenty weicht
deshalb bei Postgres und Redis von den Standardports ab.

| Dienst | Twenty | Standard | Belegt durch |
|---|---|---|---|
| Postgres | **5434** | 5432 | `kenergy-local-db` |
| Redis | **6380** | 6379 | `kenergy-local-redis` |
| Server | 3000 | 3000 | frei |
| Frontend | 3001 | 3001 | frei |

Ebenfalls belegt und zu meiden: 3100 und 8100 (`mdv_*`), 8001
(`kenergy-local-api`), 55432 (`mdv_db`), 5433.

Die Abweichung steht in `packages/twenty-docker/docker-compose.override.yml`
und **nicht** in der versionierten `docker-compose.dev.yml`, damit der
Rebase auf neue Twenty-Releases dort konfliktfrei bleibt.

Zwei Fallstricke dabei:

Compose merged Listen additiv. Ohne das `!override`-Tag wuerde der
Container auf 5432 **und** 5434 binden und am belegten 5432 scheitern.

Compose laedt `docker-compose.override.yml` nur automatisch, wenn die
Basisdatei `docker-compose.yml` heisst. Bei `-f docker-compose.dev.yml`
muessen beide Dateien explizit angegeben werden.

`packages/twenty-utils/setup-dev-env.sh` ist hier unbrauchbar: das Skript
hat 5432 und 6379 an rund acht Stellen fest verdrahtet und wuerde gegen
`kenergy-local-db` pruefen. Nicht benutzen.

---

## Lokal starten, von Null

Voraussetzungen: Node 24 ueber nvm, Yarn 4 ueber Corepack, Docker laeuft.

```bash
cd ~/Documents/Kenergy_Solutions/GitHub/twenty-Kenergy
nvm use 24 && corepack enable
yarn install
```

Container starten:

```bash
cd packages/twenty-docker
docker compose -f docker-compose.dev.yml -f docker-compose.override.yml up -d
docker compose -f docker-compose.dev.yml -f docker-compose.override.yml ps
```

Beide muessen `(healthy)` zeigen.

`packages/twenty-server/.env` muss existieren und auf die abweichenden
Ports zeigen:

```
PG_DATABASE_URL=postgres://postgres:postgres@localhost:5434/default
REDIS_URL=redis://localhost:6380
APP_SECRET=<lokaler Zufallswert>
```

Datenbank aufsetzen und starten:

```bash
cd ~/Documents/Kenergy_Solutions/GitHub/twenty-Kenergy
yarn nx database:reset twenty-server --skip-nx-cache
yarn start
```

`yarn start` startet Server, Frontend und Worker zusammen.
`http://localhost:3001`, Login `tim@apple.dev` / `tim@apple.dev`, im
Dev-Modus vorausgefuellt.

### Wenn etwas haengt

Zwei parallel laufende Stacks sind der haeufigste Grund fuer merkwuerdiges
Verhalten: zwei Worker auf derselben Redis-Queue fuehren Jobs doppelt aus.

```bash
lsof -nP -iTCP:3000 -iTCP:3001 -sTCP:LISTEN
ps -eo pid,lstart,command | grep twenty-Kenergy | grep -v grep
```

Zeigt das mehr als einen Stack, alles beenden und einmal sauber starten.

### App entwickeln

Die App liegt in einem eigenen Repo, `JaBu3001/kenergy-crm-app`, und
**nicht** im Fork. Alles, was als Objekt, Feld oder Logic Function geht,
gehoert dorthin.

```bash
cd ~/Documents/Kenergy_Solutions/GitHub/kenergy-crm-app
yarn twenty remote:add --as kenergy --url http://localhost:3000
yarn twenty dev
```

Der Remote darf **nicht** `local` heissen. Das ist im CLI der reservierte
Default-Name; `remote:add` nimmt dann den Zweig "bestehendes Remote neu
authentifizieren", liest die Standard-Config und ignoriert `--url` still.
Die Discovery geht dann gegen `localhost:2020` statt gegen euren Server.

Die Befehle heissen in dieser Version `yarn twenty dev`,
`yarn twenty remote:add` und `yarn twenty dev:function:exec`. Aeltere
Anleitungen nennen `app:dev`, `auth:login` und `function:execute`, die
gibt es nicht, auch nicht als Alias.

---

## Stages

Die neun Stages sind der einzige Teil des Datenmodells, der nicht als Code
vorliegt. Eine App kann die Optionen des Standard-Feldes `stage` nicht per
Manifest setzen: der Sync-Diff ist auf die eigene `applicationId`
beschraenkt, und ein zweites Feld namens `stage` wird abgelehnt.

Einzutragen unter Settings > Datenmodell > Opportunities > Stage:

| # | Label | Farbe | gespeicherter Wert |
|---|---|---|---|
| 1 | Recherche | gray | `RECHERCHE` |
| 2 | Verschickt / Antwort offen | blue | `VERSCHICKT_ANTWORT_OFFEN` |
| 3 | In Kontakt | sky | `IN_KONTAKT` |
| 4 | Follow-up needed | orange | `FOLLOW_UP_NEEDED` |
| 5 | Call scheduled | purple | `CALL_SCHEDULED` |
| 6 | Gewonnen | green | `GEWONNEN` |
| 7 | Verloren | red | `VERLOREN` |
| 8 | Closed - Keine Antwort | brown | `CLOSED_KEINE_ANTWORT` |
| 9 | Nurture | yellow | `NURTURE` |

Die rechte Spalte leitet Twenty selbst aus dem Label ab, per `slugify` auf
UPPER_SNAKE. Eintippen muss man sie nicht. Nachpruefen sollte man sie, denn
`brief-verschickt` vergleicht gegen `VERSCHICKT_ANTWORT_OFFEN`:

```sql
SELECT opt->>'position', opt->>'label', opt->>'value', opt->>'color'
FROM core."fieldMetadata" f
JOIN core."objectMetadata" o ON o.id = f."objectMetadataId",
LATERAL jsonb_array_elements(f.options::jsonb) opt
WHERE o."nameSingular" = 'opportunity' AND f.name = 'stage'
ORDER BY (opt->>'position')::int;
```

Die Farben vergibt Twenty beim Anlegen automatisch, und zwar irrefuehrend
(Verloren wurde gruen). Nach dem Anlegen korrigieren.

Beim Umbenennen migriert Twenty bestehende Records automatisch mit, aus
`NEW` wird `RECHERCHE`. Die Stage-Konfiguration liegt in der Datenbank und
ist damit im `pg_dump` enthalten, auch wenn sie nicht in git steht.

---

## Neues Twenty-Release in den Fork rebasen

Der Fork soll so klein wie moeglich bleiben. Stand heute enthaelt er
gegenueber Upstream nur `docker-compose.override.yml`, `BETRIEB.md`, das
Verzeichnis `deploy/` und einen Workflow. Alles Fachliche liegt im
App-Repo. Genau deshalb ist der Rebase billig; das bleibt nur so, wenn
nichts Fachliches in den Fork wandert.

```bash
git fetch upstream
git log --oneline HEAD..upstream/main | head -30
```

Ein Release-Tag statt `main` ist der ruhigere Weg:

```bash
git tag -l 'v*' --sort=-v:refname | head -5
```

Dann auf einem Zweig arbeiten, nie direkt auf `main`:

```bash
git switch -c rebase-v<version> dev
git rebase upstream/v<version>
```

Nach dem Rebase zwingend, in dieser Reihenfolge:

```bash
yarn install
npx nx build twenty-shared --skip-nx-cache
```

`twenty-shared/dist` ist Zustand pro Branch, den nichts nachhaelt. Ohne
den Neubau sind Typfehler in abhaengigen Paketen nicht vertrauenswuerdig.

```bash
yarn nx database:reset twenty-server --skip-nx-cache
yarn start
```

Nx-Caching kann einen veralteten Erfolg liefern. Wer einen Fix pruefen
will, laeuft `npx tsgo -p tsconfig.json --noEmit` direkt im Paket statt
`nx typecheck`.

Danach die App gegen die neue Version pruefen:

```bash
cd ../kenergy-crm-app
yarn install && yarn typecheck && yarn test:unit
yarn twenty dev
```

Die SDK-Version im App-Repo ist auf `2.40.0` festgenagelt. Nach einem
Versionssprung des Forks muessen `twenty-sdk`, `twenty-client-sdk` und
`twenty-ui` in der `package.json` der App mitgezogen werden, sonst passt
das generierte API-Client-Schema nicht mehr zum Server.

---

## Vor einem Versionssprung sichern und die Migration testen

Nie direkt auf Produktion aktualisieren. Der Ablauf:

### 1. Sichern

```bash
cd ~/twenty && ./backup.sh
aws s3 ls s3://<bucket>/postgres/ | tail -3
```

Der jüngste Eintrag muss von eben sein und eine plausible Groesse haben.

### 2. Die Migration gegen eine Kopie testen

Den Dump lokal einspielen und dort die Migration laufen lassen. Auf dem
Server hat man nur einen Versuch, lokal beliebig viele.

```bash
aws s3 cp s3://<bucket>/postgres/<datei>.sql.gz /tmp/prod.sql.gz
cd ~/Documents/Kenergy_Solutions/GitHub/twenty-Kenergy/packages/twenty-docker
DC="docker compose -f docker-compose.dev.yml -f docker-compose.override.yml"
$DC exec -T db psql -U postgres -d postgres -c 'DROP DATABASE IF EXISTS migration_test;' -c 'CREATE DATABASE migration_test;'
gunzip -c /tmp/prod.sql.gz | $DC exec -T db psql -U postgres -d migration_test -v ON_ERROR_STOP=1 -q
```

`ON_ERROR_STOP=1` ist wichtig. Ohne das laeuft psql ueber Fehler hinweg und
meldet am Ende Erfolg.

Dann `PG_DATABASE_URL` in `packages/twenty-server/.env` voruebergehend auf
`migration_test` zeigen lassen, die neue Version starten und zusehen, ob
die Migration durchlaeuft. Danach zuruecksetzen und `migration_test`
loeschen.

### 3. Versionsfenster pruefen

Twenty unterstuetzt den Sprung nur aus einer bekannten Vorversion. Die
Liste steht in
`packages/twenty-server/src/engine/core-modules/upgrade/constants/twenty-previous-versions.constant.ts`
und reicht aktuell von 1.21.0 bis zur laufenden Version. Wer eine Version
ueberspringt, die aelter ist als der Anfang dieser Liste, muss in Etappen
aktualisieren.

### 4. Auf dem Server aktualisieren

```bash
cd ~/twenty
echo "TAG=<neuer-sha>" # in .env eintragen
docker compose pull && docker compose up -d
docker compose logs -f server
```

Der Entrypoint ruft beim Start `yarn command:prod upgrade` auf. Das deckt
die schnellen Migrationen ab, **nicht** die langsamen. Die laufen nur mit
einem eigenen Aufruf:

```bash
docker compose exec server yarn command:prod run-instance-commands --include-slow
```

`--include-slow` gehoert zu `run-instance-commands`, nicht zu `upgrade`.
Nach einem Versionssprung, der Daten nachzieht, ist dieser Schritt noetig,
sonst bleiben Felder still unbefuellt.

Fuer lange Laeufe ueber SSH die abgekoppelte Variante, sonst stirbt der
Lauf mit der SSH-Verbindung:

```bash
docker compose exec server yarn command:prod:background upgrade
docker compose exec server yarn command:prod:background:logs
```

### 5. Danach pruefen

```bash
curl -sf https://crm.example.de/healthz && echo OK
docker compose logs --since 10m worker | grep -i error
```

Und im Browser: eine Opportunity in die Stage "Verschickt / Antwort offen"
schieben und nachsehen, ob `Nachfass`, `Kontakt am` und `Next Step` gesetzt
werden. Das ist der kuerzeste Test, der Server, Worker, Queue und Logic
Functions auf einmal abdeckt.

---

## Backups

Die naechtlichen Dumps liegen in S3 unter
`s3://<BACKUP_S3_BUCKET>/postgres/twenty-<zeitstempel>.sql.gz`,
`eu-central-1`, Storage-Class `STANDARD_IA`. Aufbewahrung standardmaessig
30 Tage, einstellbar ueber `BACKUP_RETENTION_DAYS`.

Erzeugt von `~/twenty/backup.sh` per Crontab um 02:30 UTC. Das Skript
bricht bei jedem Fehler ab, prueft den Dump auf leer und das Archiv mit
`gzip --test`, damit ein beschaedigtes Archiv nicht erst bei der
Wiederherstellung auffaellt.

Nachsehen, ob die Backups wirklich laufen:

```bash
aws s3 ls s3://<bucket>/postgres/ | tail -5
tail -20 ~/twenty/backup.log
```

Wer nur nachsieht, ob die Datei existiert, prueft nicht das Backup,
sondern den Upload.

### Wiederherstellung

**Einmal im Quartal durchspielen.** Ein Backup, das nie zurueckgespielt
wurde, ist kein Backup.

Die Probe geht lokal und ruehrt Produktion nicht an:

```bash
aws s3 cp s3://<bucket>/postgres/<datei>.sql.gz /tmp/restore-test.sql.gz
cd ~/Documents/Kenergy_Solutions/GitHub/twenty-Kenergy/packages/twenty-docker
DC="docker compose -f docker-compose.dev.yml -f docker-compose.override.yml"
$DC exec -T db psql -U postgres -d postgres -c 'DROP DATABASE IF EXISTS restore_test;' -c 'CREATE DATABASE restore_test;'
gunzip -c /tmp/restore-test.sql.gz | $DC exec -T db psql -U postgres -d restore_test -v ON_ERROR_STOP=1 -q
```

Dann nachzaehlen statt hoffen:

```sql
SELECT 'Opportunities', count(*) FROM workspace_<schema>.opportunity
UNION ALL SELECT 'Companies', count(*) FROM workspace_<schema>.company
UNION ALL SELECT 'Logic Functions', count(*) FROM core."logicFunction";
```

Das richtige Schema findet man so:

```sql
SELECT nspname FROM pg_namespace WHERE nspname LIKE 'workspace%';
```

Aufraeumen:

```bash
$DC exec -T db psql -U postgres -d postgres -c 'DROP DATABASE restore_test;'
```

### Im Ernstfall auf dem Server

```bash
cd ~/twenty
docker compose stop server worker
docker compose exec -T db psql -U postgres -d postgres -c 'DROP DATABASE "default";' -c 'CREATE DATABASE "default";'
gunzip -c /pfad/zum/dump.sql.gz | docker compose exec -T db psql -U postgres -d default -v ON_ERROR_STOP=1
docker compose start server worker
```

Server und Worker vorher stoppen, sonst schreiben sie waehrend der
Wiederherstellung weiter.

**Wichtig:** `ENCRYPTION_KEY` muss derselbe sein wie zum Zeitpunkt des
Dumps. Jeder verschluesselte Wert traegt eine Schluesselkennung; passt sie
nicht, sind die JWT-Signaturschluessel, 2FA-Secrets und App-Variablen
unlesbar. Ein Datenbank-Backup ohne den passenden Schluessel ist wertlos.
Den Schluessel getrennt von den Dumps aufbewahren, zum Beispiel im
Passwortmanager.

---

## Schluesselrotation

`ENCRYPTION_KEY` nie einfach ersetzen. Der Ablauf ist:

1. Den alten Wert als `FALLBACK_ENCRYPTION_KEY` eintragen
2. Den neuen Wert als `ENCRYPTION_KEY` eintragen
3. `docker compose up -d`
4. `docker compose exec server yarn command:prod secret-encryption:rotate`
5. Danach `FALLBACK_ENCRYPTION_KEY` wieder leeren und neu starten

Ohne Fallback sind alle verschluesselten Zeilen unlesbar und alle Nutzer
sind ausgeloggt, weil das Signaturgeheimnis des Session-Cookies aus dem
Schluessel abgeleitet wird.
