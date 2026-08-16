# Hetzner single-VM qm deployment

A single Hetzner Cloud VM running qm with the `docker` target and
`SANDBOX_BACKEND=local` (agent computers as co-located Docker containers, no
Fly dependency). Multi-user: one deployment operator; a full org of authenticated
end users, each with an isolated scope, sandbox, memory, and keychain.

## Prerequisites

This layer requires a qm CLI change that relaxes the docker target's
`sandbox.app` requirement when `SANDBOX_BACKEND=local` (see `spec.md` §6.3).
That change ships upstream and syncs back into the fork via `update-qm`. Until
it merges, `qm check` refuses a docker target with no `sandbox.app`; the deploy
runs once the change is in your fork's `main`.

## What lives where

| File | Purpose |
|---|---|
| `qm.config.jsonc` | deployment config template (placeholders) — edit with real values |
| `Caddyfile` | reverse proxy + TLS, routes the public origin to portal |
| `vm-bootstrap.sh` | host prerequisites (Docker, Buildx, Node 24, Caddy, jq) |
| `caddy.service` | systemd unit for Caddy |
| `postgres-backup.sh` | `pg_dump` + restic backup |
| `postgres-backup.timer` | systemd timer (daily 03:00 UTC) |
| `spec.md` | design spec + trust boundary + upstream changes |

Secrets never live here. `qm init` generates `.env.example`, `.gitignore`,
`package.json`, `deployment.md`, and `sandbox/` scaffolding on the VM; real
secret values go in the gitignored `.env`.

## Install runbook (operator, on the VM)

1. Provision a Hetzner Cloud VM (Debian/Ubuntu; CX32 or larger for a team).

2. Bootstrap the host and clone the fork:
   ```bash
   sudo bash deploy/layers/hetzner/vm-bootstrap.sh
   git clone git@github.com:<your-org>/qm-private /opt/qm && cd /opt/qm
   npm ci
   ```

3. Scaffold the docker layer (generates `.env.example`, `.gitignore`,
   `package.json`, `deployment.md`, `sandbox/`):
   ```bash
   node cli/bin/qm.ts init . --org <org-slug> --target docker --model-provider <provider>
   npm install
   ```

4. Overlay this layer's `qm.config.jsonc` onto the generated one. Edit the
   placeholders: `<org-slug>` (lowercase DNS label), `<public-url>` (your
   domain), and confirm the sign-in route (default `auth` broker + SMTP).
   `DATABASE_URL` and `PUBLIC_API_URL` live in `secretEnv` — fill their values
   in `.env`, not in `env.core`.

5. Fill `.env` with real secret values (`ANTHROPIC_API_KEY`, the signing
   secrets generated with `openssl rand -hex 32`, `DATABASE_URL`,
   `ADMIN_GRANTS=<email>:org_admin`, `PUBLIC_API_URL`, the SMTP credentials,
   and `BACKUP_REPO` for restic). Initialize the restic repo once:
   ```bash
   source .env && restic --repo "$BACKUP_REPO" init
   ```
   Never commit `.env`.

6. Build the agent-computer image:
   ```bash
   npm run sandbox:local:build
   ```

7. Validate and deploy:
   ```bash
   node cli/bin/qm.ts check
   node cli/bin/qm.ts up
   node cli/bin/qm.ts doctor
   node cli/bin/qm.ts check --live
   ```
   Note the portal host port `qm up` prints (default `8081`; see Caddyfile).

8. Point Caddy at this layer and enable the units:
   ```bash
   sudo cp deploy/layers/hetzner/Caddyfile /etc/caddy/Caddyfile  # or use caddy.service
   sudo systemctl enable --now caddy
   sudo cp deploy/layers/hetzner/postgres-backup.{service,timer} /etc/systemd/system/
   sudo systemctl daemon-reload
   sudo systemctl enable --now postgres-backup.timer
   sudo systemctl start postgres-backup.service  # one-shot test before relying on the timer
   ```

   Alternative ingress — Pangolin + Newt: skip Caddy (don't install it, drop
   the Caddyfile). Install Newt on the host, register the site in Pangolin,
   and create a Pangolin route targeting `http://127.0.0.1:8081` (the portal
   host port). Set `publicUrl` to the Pangolin domain. Pangolin terminates TLS at
   the tunnel edge; keep only the `postgres-backup.{service,timer}` units. If the
   repo lives outside `/opt/qm`, update `WorkingDirectory` and `ExecStart` in
   `postgres-backup.service` to match (see step 1 clone path).

9. Verify the web surface per `deployment.md`: open `publicUrl`, sign in,
   send a message, get a real model reply. Agent-computer proof:
   ```bash
   docker exec qm-sbx-<scope-slug> cat /root/workspace/qm-computer-proof.txt
   ```

## Trust boundary (per `spec.md` §3 and SECURITY.md)

Single deployment operator; a full org of authenticated end users. Scope-to-scope
network isolation is enforced (separate Docker networks per scope). Known gaps
until the upstream hardening (`spec.md` §6.4/§6.5) merges back: host-gateway on
(sandboxes can reach core/Postgres on the host), no per-scope disk quota, no
sandbox egress enforcement, container-root. These match the documented threat
model for authenticated internal users; the upstream changes close them.
