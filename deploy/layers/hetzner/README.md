# Hetzner single-VM qm deployment

A single Hetzner Cloud VM running qm with the `docker` target and
`SANDBOX_BACKEND=local` (agent computers as co-located Docker containers, no
Fly dependency). Multi-user: one deployment operator; a full org of authenticated
end users, each with an isolated scope, sandbox, memory, and keychain.

## Prerequisites

This layer requires qm CLI changes (upstream PR #553): the docker target's
`sandbox.app` relaxation for `SANDBOX_BACKEND=local`, and the auth-broker
`.internal` networking fix (portal's private-network guard rejects the bare
`http://auth:8080` the docker backend used). Until those merge upstream and
sync back into `main`, deploy from a branch that includes them (e.g.
`local-sandbox-hardening`), not bare `main`.

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

> Run the CLI as `node cli/bin/qm.ts <command>` (e.g. `init`, `setup`, `check`,
> `up`). Never `npm exec qm` or bare `qm` — a source checkout has no published
> binary, and `npm exec qm` errors with "could not determine executable to run".

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

4. Overwrite the generated `qm.config.jsonc` with this layer's template (which
   omits the `sandbox.app` block `qm init` scaffolds — the local backend needs no
   Fly app), then edit the placeholders: `<org-slug>` (lowercase DNS label),
   `<public-url>` (your domain), `modelProvider` (anthropic/openai/openrouter),
   and confirm the sign-in route (default `auth` broker + SMTP).
   ```bash
   cp deploy/layers/hetzner/qm.config.jsonc qm.config.jsonc
   ```
   `PUBLIC_API_URL` lives in `secretEnv` — fill it in `.env`, not in `env.core`.
   Do **not** set `DATABASE_URL`: qm manages Postgres (starts a `pg` container
   and injects `DATABASE_URL` into core itself); setting it makes core look for
   an external database that isn't there.

5. Fill `.env`. The easiest path is the interactive wizard, which generates the
   signing secrets and validates the provider key:
   ```bash
   node cli/bin/qm.ts setup
   ```
   Have ready: the provider API key for your `modelProvider`,
   `ADMIN_GRANTS=<email>:org_admin`,
   `PUBLIC_API_URL=http://host.docker.internal:8080` (sandboxes reach core via
   the Docker host gateway), SMTP credentials, and `BACKUP_REPO` (restic repo).
   Then initialize restic:
   ```bash
   source .env && restic --repo "$BACKUP_REPO" init
   ```
   Never commit `.env`.

6. Build the agent-computer image:
   ```bash
   npm run sandbox:local:build
   ```

7. Validate and deploy. A private fork has no published service images, so
   `qm up` builds them locally with `--build-from` (cached after the first run):
   ```bash
   node cli/bin/qm.ts check
   node cli/bin/qm.ts up --build-from
   node cli/bin/qm.ts doctor
   node cli/bin/qm.ts check --live
   ```
   Note the portal host port `qm up` prints (default `8081`; that's the
   Caddy/Pangolin target). The "no sandbox image pinned" note (if shown) is a
   false positive for the local path — ignore it.

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
