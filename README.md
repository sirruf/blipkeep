# Installing Blipkeep

Step-by-step: the panel and its agents on clean servers, without sources and
without Elixir or Go on the target machines. Everything is installed from a
prebuilt image and a single signed binary.

## Quick start

On the server that will run the panel — Linux x86_64 with Docker:

```bash
sudo ./install.sh --host mon.example.com
```

That deploys the panel, prints where the administrator password is stored, and
prints the ready-to-paste command for installing an agent, token included. Point
a DNS record at this server first, and put a reverse proxy in front of the panel
afterwards (see “TLS”).

Everything below explains what that command does, and covers the cases it does
not: air-gapped environments, built-in TLS, older systems, federation.

## What the system is made of

- **Panel** — the web interface and the data receiver. Deployed as a Docker
  Swarm stack of two services: the panel itself and TimescaleDB. One server,
  one panel.
- **Agent** — a small program on the monitored server. It collects metrics,
  runs service checks and keeps a persistent WebSocket connection to the panel.
  Installed as a systemd unit, runs as root.
- **Federation** (optional) — a panel can forward its data to an upstream
  panel, so several sites end up in a single overview.

The agent connects to the panel, never the other way round: the monitored
server needs no open ports.

## Requirements

For the panel:

- Linux x86_64, 2 GB RAM or more (the database is the main consumer), 20 GB disk
- Docker 20.10+ with Swarm enabled (`bootstrap` enables it for you)
- `openssl` (secret generation) and `curl`
- a domain name pointing at the server, if the panel faces the internet

For the agent:

- Linux x86_64 with systemd, root privileges
- outbound access to the panel over HTTPS/WSS
- `curl` and `openssl` (or `sha256sum` — see “Older systems”)

The panel image is public; no `docker login` is required.

## What is in the kit

```
install.sh                  one-command install: panel + token + agent command
server/bootstrap            panel installer (the same file ships inside the image)
server/stack.yml            Swarm stack manifest
server/.env.example         annotated settings template
server/update.sh            switches an installed panel to another version
server/nginx.example.conf   reverse proxy example with WebSocket support
agent/tinymon-agent         agent binary (linux/amd64)
agent/tinymon-agent.sig     signature made with the release key
agent/tinymon-agent.sha256  hash, for hosts whose openssl cannot verify Ed25519
```

There is no agent installer in the kit on purpose: the panel generates it with
its own address baked in, so it only exists once your panel is up. Take it from
`https://<your-panel>/install.sh` — the quick-start output hands you the whole
command already.

The kit exists for air-gapped environments. With internet access the panel is
installed by a single command (step 1), and the agent by the command the panel
itself displays.

### Environment without internet access

The kit contains everything except the Docker images themselves — bring them
separately. On a machine with internet access:

```bash
docker pull sirruf/tinymon-server:0.7.29
docker pull timescale/timescaledb-ha:pg17
docker save sirruf/tinymon-server:0.7.29 timescale/timescaledb-ha:pg17 \
  | gzip > blipkeep-images.tar.gz
```

On the panel server, before running bootstrap:

```bash
gunzip -c blipkeep-images.tar.gz | sudo docker load
```

Then install with an explicit version (`--version 0.7.29`) rather than
`latest`: there will be nowhere to pull that tag from. Monitored servers need
no internet at all — only access to the panel.

---

## From a fresh VPS, start to finish

Everything below assumes a newly rented VPS with Ubuntu 22.04 or 24.04, root
access and a public IP. Roughly 15 minutes, most of it spent waiting for images
to download.

### 1. DNS

Point an `A` record at the server's IP before installing: the panel's address
ends up in links, in the agent install command and in the TLS certificate.

```
mon.example.com.   A   203.0.113.10
```

Check that it resolves — `dig +short mon.example.com` — and only then continue.
Certbot will fail on a record that has not propagated yet.

### 2. The system

```bash
ssh root@203.0.113.10

apt update && apt upgrade -y
apt install -y curl ca-certificates
timedatectl set-timezone UTC        # optional, but log timestamps get easier
```

### 3. Docker

```bash
curl -fsSL https://get.docker.com | sh
docker version
```

Swarm is initialised by the installer itself; nothing to do here.

### 4. Firewall

```bash
apt install -y ufw
ufw allow 22/tcp
ufw allow 80/tcp
ufw allow 443/tcp
ufw --force enable
```

**Watch out for one thing.** The panel publishes its port in Docker's `host`
mode, and such traffic does not pass through the chain ufw manages — the panel
would stay reachable on port 4000 from the outside, bypassing your proxy and its
TLS. Close it in the `raw` table, before Docker's DNAT gets to it:

```bash
cat >> /etc/ufw/before.rules <<'EOF'

*raw
:PREROUTING ACCEPT [0:0]
# The panel is only reachable through nginx on 127.0.0.1; from outside — never
-A PREROUTING -p tcp --dport 4000 ! -i lo -j DROP
COMMIT
EOF

ufw reload
```

Verify from your own machine, not from the server: `curl -m 5 http://203.0.113.10:4000/`
must time out. `ufw status` will not tell you the truth here.

### 5. The panel

With the kit copied to the server:

```bash
scp -r blipkeep-install-kit-0.7.29-en root@203.0.113.10:/root/blipkeep
ssh root@203.0.113.10 'cd /root/blipkeep && ./install.sh --host mon.example.com'
```

Or without the kit at all, straight from the image:

```bash
docker run --rm sirruf/tinymon-server:latest cat /app/bin/bootstrap \
  | bash -s -- --host mon.example.com
```

Either way you end up with `/opt/tinymon` holding `.env`, the manifest and the
administrator's password. The kit's `install.sh` additionally prints the agent
install command with a token already in it — copy it somewhere for the next step.

### 6. TLS

```bash
apt install -y nginx certbot python3-certbot-nginx

cp server/nginx.example.conf /etc/nginx/sites-available/mon.example.com
# replace mon.example.com with your own address inside the file
ln -s /etc/nginx/sites-available/mon.example.com /etc/nginx/sites-enabled/
rm -f /etc/nginx/sites-enabled/default

nginx -t && systemctl reload nginx
certbot --nginx -d mon.example.com
```

Then tell the panel to trust the address the proxy passes on:

```bash
echo 'TINYMON_CLIENT_IP_HEADER=X-Real-IP' >> /opt/tinymon/.env
cd /opt/tinymon && docker stack deploy --with-registry-auth -c stack.yml tinymon
```

Without that line every enrollment request would show the proxy's address
instead of the agent's.

### 7. First sign-in

```bash
cat /opt/tinymon/.initial-credentials
```

Open `https://mon.example.com`, sign in, change the password, delete the file.

### 8. An agent on this very server

The panel does not monitor the machine it runs on until an agent is installed
there too — and that machine is worth watching, since everything else depends on
it. Run the command printed in step 5, right here:

```bash
curl -fsSL https://mon.example.com/install.sh | sudo bash -s -- \
  --server wss://mon.example.com/agent \
  --token <token>
```

Approve the request in the panel (Agents → compare the fingerprint). Repeat the
same command on every other server you want to monitor — the token is reusable.

### 9. Notifications

Settings → Telegram: create a bot through `@BotFather`, paste its token and your
chat id. Until then alerts accumulate in the panel but reach nobody.

### What you end up with

- the panel on `https://mon.example.com` behind nginx with a certificate;
- port 4000 unreachable from outside;
- the host itself monitored, with the default rule set already active;
- alerts going to Telegram;
- updates available from a button in the interface.

---

## Step 1. The panel

### Installation

With internet access — one command, nothing to download in advance:

```bash
docker run --rm sirruf/tinymon-server:latest cat /app/bin/bootstrap \
  | sudo bash -s -- --host mon.example.com
```

From the kit (files already on the server):

```bash
sudo ./server/bootstrap --host mon.example.com
```

Options:

| Flag | What it sets | Default |
|---|---|---|
| `--host` | panel address: goes into links and into the agent install command | required |
| `--admin` | first administrator's email | `admin@<host>` |
| `--scheme` | `https` or `http` in generated links | `https` |
| `--port` | external port of the panel | `4000` |
| `--version` | image tag | `latest` |
| `--dir` | deployment directory | `/opt/tinymon` |
| `--stack` | Swarm stack name | `tinymon` |

The script initialises Swarm, pulls the image, extracts the manifest from it,
generates `/opt/tinymon/.env` with random secrets, deploys the stack, waits for
the database and writes the administrator password to
`/opt/tinymon/.initial-credentials` with mode 0600. Running it again is safe:
an existing `.env` is never overwritten.

Installation takes a few minutes — pulling the database image is the slow part.

### TLS

The panel serves plain HTTP on `PUBLISHED_PORT`. There are two ways to expose it.

**Reverse proxy (the usual path).** Take `server/nginx.example.conf`, replace
the address, link it into `sites-enabled`, then issue a certificate:

```bash
sudo certbot --nginx -d mon.example.com
```

Two things matter, and without them it only half works:

- forwarding the `Upgrade`/`Connection` headers — otherwise agents cannot
  establish a WebSocket and the panel stays empty;
- `proxy_set_header X-Real-IP $remote_addr` plus `TINYMON_CLIENT_IP_HEADER=X-Real-IP`
  in `/opt/tinymon/.env` — otherwise enrollment requests show the proxy's
  address instead of the agent's. Without that variable the panel deliberately
  distrusts the header: otherwise a client could set its own address and bypass
  the rate limiter.

**Built-in TLS.** The panel can terminate TLS itself, with no proxy. In `.env`:

```
TINYMON_TLS_DIR=/etc/letsencrypt/live/mon.example.com
TINYMON_TLS_CERTFILE=/etc/tinymon-tls/fullchain.pem
TINYMON_TLS_KEYFILE=/etc/tinymon-tls/privkey.pem
PHX_SCHEME=https
PHX_URL_PORT=4000
```

`TINYMON_TLS_DIR` is mounted into the container as `/etc/tinymon-tls`, so the
file paths point inside the container. `PHX_URL_PORT` is needed when the panel
listens on a non-standard port: without it links (and the agent upgrade command)
would carry port 443.

After editing `.env`:

```bash
cd /opt/tinymon && docker stack deploy --with-registry-auth -c stack.yml tinymon
```

### First sign-in

```bash
sudo cat /opt/tinymon/.initial-credentials
```

Open `https://mon.example.com`, sign in, change the password (the panel will
ask) and delete the credentials file.

---

## Step 2. The agent on a monitored server

### Token

In the panel: **Agents** → “Create token”. A token is reusable and time-limited,
so one token can enroll a whole batch of servers. The panel immediately shows a
ready-to-paste install command.

The same thing from the panel server's shell:

```bash
docker exec $(docker ps -q -f name=tinymon_tinymon | head -1) \
  /app/bin/tinymon eval 'Tinymon.Release.enrollment_token()'
```

### Installation

On the monitored server:

```bash
curl -fsSL https://mon.example.com/install.sh | sudo bash -s -- \
  --server wss://mon.example.com/agent \
  --token <token>
```

The script downloads the binary from the panel, verifies its signature against
the release key, installs it to `/usr/local/bin/tinymon-agent`, creates
`/etc/tinymon/agent.yml` (mode 0600), installs a systemd unit and starts it.
At the end it prints the **agent key fingerprint**.

The address must start with `wss://`. The agent executes panel commands as
root, so an unencrypted channel means anyone in the middle gets a shell on that
server. In a trusted network `ws://` is accepted only together with an explicit
`--insecure` flag.

### Approval

In the panel: **Agents** → the request from that server. Compare the
fingerprint with the one the installer printed, then approve. Within seconds the
host shows up in the overview with metrics.

### Air-gapped and older systems

`openssl pkeyutl -rawin`, which verifies the Ed25519 signature, only appeared in
OpenSSL 3.0. Ubuntu 18.04 and 20.04 ship 1.1.1 — there the installer says so
plainly and offers hash verification instead.

Take the hash on a machine with a modern openssl (or use the bundled
`agent/tinymon-agent.sha256`):

```bash
curl -fsSL https://mon.example.com/download/tinymon-agent | sha256sum
```

Then, on the target server:

```bash
curl -fsSL https://mon.example.com/install.sh | sudo bash -s -- \
  --server wss://mon.example.com/agent \
  --token <token> \
  --sha256 <hash>
```

If the panel is unreachable from that server altogether, bring the binary with
you and point at the file:

```bash
sudo ./agent/install.sh \
  --server wss://mon.example.com/agent \
  --token <token> \
  --binary ./agent/tinymon-agent \
  --sha256 $(cut -d' ' -f1 agent/tinymon-agent.sha256)
```

Download `https://<panel>/install.sh` while you still have a machine that can
reach the panel, and carry it in together with the binary — the script has your
panel's address baked in, so it cannot be shipped in the kit in advance.

---

## Step 3. What to set up afterwards

**Service checks.** Metrics tell you how much a service consumes, not whether it
works: a container stays `running` while the application inside hangs. Host page
→ “Data collection” → “Service checks”. Available kinds: HTTP endpoint, TCP
port, script on the host, command inside a container, HTTP inside a container,
and Redis PING. Check state and the last output are shown on the host page
itself.

**Alert rules.** A default set is installed on first deployment: disk space,
memory, CPU, stopped containers, unreachable host, failing check. Edit them on
the “Rules” screen.

**Notifications.** Settings → Telegram channel (bot token and chat). Without a
channel, alerts pile up in the panel but go nowhere.

**Collectors.** Host page → “Data collection”: what to collect and how often.
PostgreSQL and nginx need a target (connection string, `stub_status` address);
everything else works out of the box.

---

## Step 4. Federation (optional)

A panel can forward its data upstream, so several sites end up in one overview.

1. On the **upstream** panel: **Agents** → create an enrollment token.
2. On the **downstream** one: Settings → Uplink → the upstream address
   (`wss://upstream.example.com/agent`) and that token.
3. On the upstream panel: Settings → Installations → approve the request.

Hosts of the downstream panel appear upstream marked “through federation”.
Collection settings for such hosts are configured where their agent lives; the
upstream panel only displays them.

---

## Updating and rolling back

The panel:

```bash
cd /opt/tinymon && sudo ./update.sh 0.7.29     # or: --current
```

The script pulls the image and updates the service; the database and settings
are untouched, migrations run when the container starts. Rolling back is the
same call with the previous version: images stay in the registry.

Without the kit, re-running bootstrap does the same:

```bash
docker run --rm sirruf/tinymon-server:latest cat /app/bin/bootstrap \
  | sudo bash -s -- --host mon.example.com --version 0.7.29
```

Since 0.7.26 the panel learns about new versions on its own and updates itself
from a button in the interface — for that, its settings must name the host it
runs on (otherwise the button stays disabled: the panel does not know which
agent to send the command to).

Agents are updated from the host page with the “Update agent” button — the
binary comes from the panel and its signature is verified before replacement.

---

## Troubleshooting

```bash
# Panel: logs and state
docker service logs tinymon_tinymon --since 10m
docker service ps tinymon_tinymon --no-trunc

# Is the panel answering?
curl -sk -o /dev/null -w '%{http_code}\n' https://127.0.0.1:4000/    # expect 302

# Agent
systemctl status tinymon-agent
journalctl -u tinymon-agent -f
```

The usual suspects:

- **Host is “up” but no metrics arrive.** Usually the agent was moved from
  another panel without deleting `/var/lib/tinymon/state.json`: it arrives with
  a foreign `host_id` and accumulated packet numbers, which the panel discards
  as duplicates. Delete the state file and restart the agent.
- **Empty host page while the agent is alive.** The proxy does not forward
  `Upgrade`, so no WebSocket is established.
- **Wrong address in the enrollment request.** `TINYMON_CLIENT_IP_HEADER` is
  unset, or the proxy does not set `X-Real-IP`.
- **`unsupported_record_type` in the panel log.** Something spoke plain HTTP to
  a port with built-in TLS enabled. Check with `curl -k https://…`.
- **The systemd collector is silent on Ubuntu 18.04.** `systemctl --output=json`
  appeared in systemd 246; 18.04 ships 237. Other collectors work.
- **The panel port is reachable from outside, bypassing the proxy.** The stack
  publishes its port in `host` mode, and such traffic never traverses the
  `DOCKER-USER` chain — ufw rules simply do not see it. Block it in the `raw`
  table before DNAT, or bind the publication to `127.0.0.1`. Verify with `curl`
  from outside, not with `ufw status`.

---

## Where things live

| Path | What |
|---|---|
| `/opt/tinymon/.env` | panel settings and secrets (0600) |
| `/opt/tinymon/stack.yml` | stack manifest |
| `/opt/tinymon/.initial-credentials` | first administrator's password (delete after signing in) |
| volume `tinymon_db_data` | database: metrics, events, settings |
| `/etc/tinymon/agent.yml` | agent configuration (0600) |
| `/etc/tinymon/agent.key` | agent private key |
| `/var/lib/tinymon/state.json` | agent state: host_id and packet number |
| `/var/lib/tinymon/spool` | buffer for data while the panel is unreachable |

## Uninstalling

The agent:

```bash
sudo systemctl disable --now tinymon-agent
sudo rm -f /etc/systemd/system/tinymon-agent.service /usr/local/bin/tinymon-agent
sudo rm -rf /etc/tinymon /var/lib/tinymon
sudo systemctl daemon-reload
```

Then revoke the host in the panel so it is not listed as unreachable.

The panel:

```bash
docker stack rm tinymon
docker volume rm tinymon_db_data      # along with the entire metric history
sudo rm -rf /opt/tinymon
```
