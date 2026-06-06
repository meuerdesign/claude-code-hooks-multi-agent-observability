# Deploying obs (live agent observability)

Self-contained: one Bun service (API + WebSocket + built dashboard) plus a
Cloudflare tunnel. Runs as its own compose project on the **telemetry pet box**
(separate Hetzner project), alongside the telemetry stack. **No host ports** are
published - `cloudflared` dials out to Cloudflare, so the box has zero public
inbound. The agent boxes POST events to `https://obs.example.com/events`
(write-only, bearer-gated); you view the dashboard at `https://obs.example.com`
(Cloudflare Access SSO, your identity only).

```
agent boxes ──POST /events (bearer)──┐
                                     ▼
                          Cloudflare edge ── Access SSO ──> you (dashboard)
                                     │  (WAF + rate-limit on /events)
                                     ▼  cloudflared tunnel (outbound)
                          obs-server :4000  ── events.db (volume)
```

## 1. Cloudflare (Zero Trust dashboard, in your Cloudflare account (the zone for your domain))

1. **Tunnel:** Networks → Tunnels → *Create tunnel* (Cloudflared) → name `obs`.
   Copy the **tunnel token** → goes in `.env` as `TUNNEL_TOKEN`.
2. **Public hostname** (on the tunnel): `obs.example.com` → service
   `http://obs-server:4000`. This creates/overwrites the `obs.example.com` DNS
   record as a tunnel CNAME — **delete any manual A-record you made for it.**
3. **Access application:** Access → Applications → *Add* → Self-hosted →
   domain `obs.example.com`.
   - Policy **Allow**: Emails = `you@example.com` (your identity only).
   - Add a **Bypass** policy scoped to path `/events` (so headless boxes can
     POST without SSO). It stays protected by the bearer `INGEST_TOKEN` below.
   - `/stream` (the dashboard's WebSocket) stays under the SSO policy — your
     authenticated browser carries the cookie, boxes never touch it.
4. **(Recommended) WAF rate-limit** on `obs.example.com/events` to blunt a
   compromised box flooding ingest.

> Stricter alternative to the `/events` Bypass: a second Access app on the
> `/events` path with a **Service Auth** policy + service token, and have the
> boxes send the `CF-Access-Client-Id/Secret` headers. The bearer-only Bypass
> is simpler and already origin-enforced; upgrade later if you want edge auth on
> ingest too.

## 2. The box

```bash
# clone the obs repo onto the telemetry pet (the 'obs' branch with the patches)
git clone -b obs https://github.com/meuerdesign/claude-code-hooks-multi-agent-observability.git /opt/obs
cd /opt/obs
cp .env.deploy.sample .env
#   INGEST_TOKEN  -> openssl rand -hex 32   (use the SAME value as the boxes' OBS_TOKEN)
#   TUNNEL_TOKEN  -> the token from step 1.1
$EDITOR .env

docker compose up -d --build      # builds the image, starts obs-server + cloudflared
docker compose logs -f cloudflared   # should show 4 connections registered
```

## 3. Point the agent boxes at it

In the agent golden (`infra/`), set `secrets/obs.env` (uncomment both lines):

```
OBS_SERVER_URL=https://obs.example.com/events
OBS_TOKEN=<same value as INGEST_TOKEN above>
```

Rebuild the golden so it sticks across spawns (see `infra/README.md`).
`OBS_TOKEN` is **write-only** — it can only POST `/events`, never read the
dashboard or stored data.

## 4. Verify end to end

```bash
# from anywhere, an unauthenticated read must be blocked by Access (302/403):
curl -sI https://obs.example.com | head -1
# a write WITHOUT the bearer must be rejected by the origin (401):
curl -s -o /dev/null -w '%{http_code}\n' -X POST https://obs.example.com/events \
  -H 'content-type: application/json' -d '{}'
```
Then spawn a box, run a Claude session, and watch events stream onto the
dashboard (open `https://obs.example.com` in a browser → SSO → timeline).

## Notes
- **Metadata only:** the box hooks ship event metadata + `last_assistant_message`,
  **not** full transcripts (`--add-chat` is off). To debug one box, flip
  `--add-chat` on for that box's `Stop` hook only.
- Pin `cloudflared` in `docker-compose.yml` (currently `:latest`).
- Backups: the `obs_data` volume holds `events.db`.
