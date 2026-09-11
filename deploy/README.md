# Twenty auf AWS Lightsail einrichten

Diese Anleitung richtet sich an einen Menschen an der Tastatur. Jeder
Schritt hat einen Satz dazu, warum er noetig ist.

Zielbild: eine Lightsail-Instanz, 4 GB RAM, Ubuntu, Region Frankfurt.
Darauf Docker Compose mit Twenty-Server, Worker, Postgres, Redis und Caddy.
Ein einzelner Nutzer, Kosten unter 30 $ im Monat.

---

## Vorher, ausserhalb des Servers

### 1. Lightsail-Instanz anlegen

Region `eu-central-1` (Frankfurt), Blueprint **Ubuntu 24.04 LTS**, Plan mit
**4 GB RAM / 2 vCPU / 80 GB SSD** (aktuell 24 $/Monat). Weniger RAM reicht
nicht: Server und Worker sind zwei Node-Prozesse, dazu Postgres.

### 2. Statische IP zuweisen

In Lightsail unter Networking eine statische IP erzeugen und der Instanz
zuweisen. Ohne das aendert sich die IP bei jedem Neustart und das
Zertifikat bricht.

### 3. Firewall

In Lightsail unter Networking am Instanz-Eintrag freigeben:

| Port | Wofuer |
|---|---|
| 22 | SSH, am besten auf die eigene IP eingeschraenkt |
| 80 | Nur fuer die ACME-Challenge von Let's Encrypt |
| 443 | Die eigentliche Anwendung |

Port 3000 bleibt zu. Der Server ist nur ueber Caddy erreichbar, das
Compose-File veroeffentlicht ihn bewusst nicht.

### 4. DNS

Einen A-Record der Domain auf die statische IP setzen. **Vor** dem ersten
Start von Caddy, sonst scheitert die Zertifikatsausstellung und Let's
Encrypt drosselt nach mehreren Fehlversuchen.

Pruefen:

```bash
dig +short crm.example.de
```

Muss die statische IP ausgeben.

### 5. S3-Bucket und IAM fuer die Backups

Bucket in `eu-central-1` anlegen, Versionierung an, oeffentlichen Zugriff
blockiert. Der Instanz ein IAM-Profil geben, das auf diesem Bucket
`s3:PutObject`, `s3:GetObject`, `s3:ListBucket` und `s3:DeleteObject` darf.

Ueber die Rolle statt ueber Zugangsschluessel, damit keine AWS-Keys auf der
Instanz liegen. Deshalb stehen in `.env.example` auch keine.

### 6. GitHub Personal Access Token

Falls das Repo `Kenergy-Solutions/twenty-Kenergy` privat ist, ist auch das
Image auf ghcr.io privat und die Instanz muss sich anmelden. Dafuer einen
PAT mit dem Scope `read:packages` erzeugen.

Wenn das Repo oeffentlich ist oder ihr das Paket auf ghcr.io auf public
stellt, entfaellt Schritt 9.

---

## Auf dem Server

### 7. Einloggen und Grundausstattung

```bash
ssh ubuntu@<statische-ip>
```

```bash
sudo apt-get update && sudo apt-get install -y ca-certificates curl unzip
```

### 8. Docker installieren

```bash
curl -fsSL https://get.docker.com | sudo sh
sudo usermod -aG docker ubuntu
```

Danach einmal ab- und wieder anmelden, damit die Gruppenmitgliedschaft
greift.

### 8b. Swap anlegen

```bash
sudo fallocate -l 2G /swapfile && sudo chmod 600 /swapfile
sudo mkswap /swapfile && sudo swapon /swapfile
echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab
```

4 GB RAM sind fuer diesen Stack knapp. Ohne Swap kann der OOM-Killer im
laufenden Betrieb den Worker abraeumen, und das faellt erst auf, wenn eine
Logic Function nicht mehr feuert.

### 8c. AWS CLI installieren

```bash
curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o /tmp/aws.zip
unzip -q /tmp/aws.zip -d /tmp && sudo /tmp/aws/install && rm -rf /tmp/aws /tmp/aws.zip
```

Das Backup-Skript braucht `aws s3`.

### 9. An ghcr.io anmelden

Nur noetig, wenn das Paket privat ist.

```bash
docker login ghcr.io -u <github-benutzername>
```

Bei der Passwortabfrage den PAT aus Schritt 6 einfuegen. Der Token landet
in `~/.docker/config.json` und wird nicht abgefragt, wenn er als Argument
uebergeben wird, deshalb hier die interaktive Variante.

### 10. Dateien auf den Server bringen

```bash
mkdir -p ~/twenty && cd ~/twenty
```

Aus diesem Verzeichnis des Repos kopieren: `docker-compose.yml`,
`Caddyfile`, `backup.sh`, `.env.example`. Entweder per `scp` vom Laptop
oder per `git clone` des Forks und dann aus `deploy/` heraus.

### 11. .env ausfuellen

```bash
cp .env.example .env
```

Secrets auf dem Server erzeugen, nicht auf dem Laptop, und nicht durch
einen Chat schicken:

```bash
openssl rand -base64 32   # -> ENCRYPTION_KEY
openssl rand -hex 32      # -> PG_DATABASE_PASSWORD
```

Dann `.env` bearbeiten und ausfuellen: `DOMAIN`, `ACME_EMAIL`,
`SERVER_URL`, `ENCRYPTION_KEY`, `PG_DATABASE_PASSWORD`,
`BACKUP_S3_BUCKET`.

`SERVER_URL` muss die echte HTTPS-Domain sein. Bleibt dort localhost,
wird das Session-Cookie ohne `Secure` gesetzt, alle Dateilinks zeigen ins
Leere, und die Logic Functions bekommen eine API-Adresse, unter der im
Worker-Container nichts lauscht.

Rechte einschraenken, die Datei enthaelt den Datenbankschluessel:

```bash
chmod 600 .env
```

### 12. Starten

```bash
docker compose pull && docker compose up -d
```

Der erste Start dauert ein paar Minuten: der Entrypoint legt das Schema an
und laesst die Migrationen laufen.

Zusehen:

```bash
docker compose logs -f server
```

Fertig, wenn dort `Nest application successfully started` steht.

### 13. Nachsehen, ob es laeuft

```bash
docker compose ps
curl -sf https://crm.example.de/healthz && echo OK
```

Wenn Caddy kein Zertifikat bekommt: `docker compose logs caddy`. Fast
immer zeigt der A-Record noch nicht richtig oder Port 80 ist zu.

### 14. Ersten Nutzer anlegen

`https://crm.example.de` im Browser oeffnen und registrieren. Die erste
Registrierung erzeugt den Workspace und macht den Nutzer zum Admin. Jede
weitere wird abgelehnt, weil `IS_MULTIWORKSPACE_ENABLED` auf `false`
steht. Das ist die gewuenschte Einzelnutzer-Konfiguration und braucht
keine zusaetzliche Variable.

### 15. Stages eintragen

Unter Settings > Datenmodell > Opportunities > Stage die neun Stages
anlegen. Die Liste mit Reihenfolge und Farben steht in `BETRIEB.md`.

Das ist der eine Teil des Datenmodells, der nicht aus der App kommt: eine
App kann die Optionen eines Standard-Feldes nicht per Manifest setzen.

### 16. App installieren

Einen API-Key unter Settings > MCP & APIs erzeugen und im App-Repo als
GitHub-Secret `TWENTY_PROD_API_KEY` hinterlegen, die Domain als
`TWENTY_PROD_URL`. Danach installiert sich die App bei jedem Push auf
`main` von selbst.

Einmalig von Hand geht auch:

```bash
yarn twenty remote:add --as prod --url https://crm.example.de
yarn twenty app:publish --private --remote prod
yarn twenty app:install --remote prod
```

### 17. Backup einrichten

```bash
chmod +x ~/twenty/backup.sh
~/twenty/backup.sh
```

Einmal von Hand laufen lassen und pruefen, dass die Datei im Bucket
ankommt. Erst dann in die Crontab:

```bash
crontab -e
```

```
30 2 * * * /home/ubuntu/twenty/backup.sh >> /home/ubuntu/twenty/backup.log 2>&1
```

02:30 UTC, also 03:30 bzw. 04:30 deutscher Zeit, ausserhalb der
Arbeitszeit.

### 18. Wiederherstellung einmal durchspielen

Nicht optional. Ein Backup, das nie zurueckgespielt wurde, ist kein
Backup. Wie das geht, steht in `BETRIEB.md` unter "Wiederherstellung".

---

## Spaeter aktualisieren

Der Deploy ist bewusst nicht automatisch. Wenn ein neues Image gebaut ist:

```bash
cd ~/twenty && docker compose pull && docker compose up -d
```

Vor einem Versionssprung erst sichern und die Migration testen, siehe
`BETRIEB.md`.
