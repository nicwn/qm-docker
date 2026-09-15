# Hetzner single-VM qm deployment

A single Hetzner Cloud VM running qm with the `docker` target and local sandboxes
(agent computers as co-located Docker containers, no Fly dependency). One deployment
operator; a full org of authenticated end users, each with an isolated scope, sandbox,
memory, and keychain.

This is the deployment this fork exists for — see the repository README for the two
upstream bugs [`qm-docker`](https://github.com/nicwn/qm-docker) fixes.

## What lives where

| File                                 | Purpose                                                           |
| ------------------------------------ | ----------------------------------------------------------------- |
| `qm.config.jsonc`                    | deployment config template (placeholders) — edit with real values |
| `Caddyfile`                          | reverse proxy + TLS, routes the public origin to portal           |
| `vm-bootstrap.sh`                    | host prerequisites (Docker, Buildx, Node 24, Caddy, jq)           |
| `caddy.service`                      | systemd unit for Caddy                                            |
| `postgres-backup.sh`                 | `pg_dump` + restic backup                                         |
| `postgres-backup.service` / `.timer` | systemd timer (daily 03:00 UTC)                                   |
| `PANGOLIN-NEWT.md`                   | ingress guide for Pangolin + Newt (Docker-Newt routing)           |

Secrets never live here. `qm init` generates `.env.example`, `.gitignore`,
`package.json`, `deployment.md`, and `sandbox/` scaffolding on the VM; real secret
values go in the gitignored `.env`.

## Install runbook (operator, on the VM)

1. Provision a Hetzner Cloud VM (Debian/Ubuntu; CX32 or larger for a team).

2. As the deployment user, install git, make the deployment directory writable, then clone
   and bootstrap. (`/opt` is root-owned and a fresh VM has no git, so both have to be dealt
   with before the clone):

   ```bash
   sudo apt-get update && sudo apt-get install -y git curl
   sudo mkdir -p /opt/qm && sudo chown "$USER" /opt/qm
   git clone https://github.com/nicwn/qm-docker /opt/qm && cd /opt/qm
   sudo bash deploy/layers/hetzner/vm-bootstrap.sh
   npm ci
   ```

3. Scaffold the deployment directory (the published CLI is fine for this one step):

   ```bash
   npm exec --yes --package=@yc-software/qm@latest -- \
     qm init . --org <org-slug> --target docker --model-provider <provider>
   ```

4. Overwrite the generated `qm.config.jsonc` with this layer's template, then edit the
   placeholders — `<org-slug>` (lowercase DNS label), `<public-url>` (your domain),
   `<sandbox-image>` (normally `qm-<org-slug>-sandbox-local:latest`), and `modelProvider`:

   ```bash
   cp deploy/layers/hetzner/qm.config.jsonc qm.config.jsonc
   ```

   The template sets `"sandbox": { "backend": "local", … }`, which is what selects the
   co-located Docker sandbox path. Do **not** set `DATABASE_URL`: qm runs its own `pg`
   container and injects the URL into core itself.

5. Fill `.env` with the interactive wizard, which generates the signing secrets and
   validates the provider key:

   ```bash
   node cli/bin/qm.ts setup
   ```

   Have ready: the provider API key for your `modelProvider`, `ADMIN_GRANTS=<email>:org_admin`,
   SMTP credentials for the built-in `auth` broker, `BACKUP_REPO` (a restic repo), and a
   **non-interactive** restic credential — `RESTIC_PASSWORD_FILE` (preferred) or
   `RESTIC_PASSWORD` — because the backup timer has no terminal to prompt on. Then:

   ```bash
   source .env && restic --repo "$BACKUP_REPO" init
   ```

   `PUBLIC_API_URL` is still a required secret name, but on this path the CLI **overrides
   its value** with the address sandboxes actually use, so what you put here is ignored.
   Never commit `.env`.

6. Build the agent-computer image from this checkout:

   ```bash
   LOCAL_SANDBOX_IMAGE=<sandbox-image> npm run sandbox:local:build
   ```

   Do this **before** `up`: with `sandbox.image` set, `up` skips its own image build, so a
   missing image means `up` reports success and the first agent turn is what fails.

7. Deploy with **this fork's CLI**, so the fork's fixes apply:

   ```bash
   node cli/bin/qm.ts up --build-from=/opt/qm
   node cli/bin/qm.ts conformance
   ```

   `check --live` is not implemented for the `docker` target; verify by signing in and
   running a real turn (step 9) instead.

   **Never run a bare `up`** (without `--build-from`). `cli/manifest.json` is deliberately
   left as the release sentinel, so that path fails loudly rather than pulling upstream
   images and silently reverting this fork.

8. Ingress. Note the portal host port `up` prints (default `8081` = `QM_BASE_PORT` 8080 +
   the portal's offset) — that is the target for whichever ingress you choose.

   **Caddy on the VM:** edit the placeholder first — the template ships `<public-url>`, which
   Caddy cannot load — then validate and reload. Bootstrap already installed and started
   Caddy, so `enable --now` on its own would not pick up the new config:

   ```bash
   sed -i 's|<public-url>|qm.example.com|' deploy/layers/hetzner/Caddyfile
   caddy validate --config deploy/layers/hetzner/Caddyfile   # validate BEFORE installing it
   sudo cp deploy/layers/hetzner/Caddyfile /etc/caddy/Caddyfile
   sudo systemctl enable caddy
   sudo systemctl reload caddy || sudo systemctl restart caddy
   ```

   **Or Pangolin + Newt:** skip Caddy entirely. Install Newt, register the site in
   Pangolin, and point the route at qm's portal host port. The target address depends on
   how Newt runs — `http://127.0.0.1:8081` only works for a Newt **host binary**; a Newt
   **Docker container** must target the host gateway (`http://172.17.0.1:8081` or
   `http://host.docker.internal:8081`) or you get a 502. See
   [`PANGOLIN-NEWT.md`](./PANGOLIN-NEWT.md). Set `publicUrl` to the Pangolin domain —
   Pangolin terminates TLS at the tunnel edge.

   Backups (either ingress):

   ```bash
   sudo cp deploy/layers/hetzner/postgres-backup.{service,timer} /etc/systemd/system/
   sudo systemctl daemon-reload
   sudo systemctl enable --now postgres-backup.timer
   sudo systemctl start postgres-backup.service   # one-shot test before trusting the timer
   ```

   If the repo lives outside `/opt/qm`, update `WorkingDirectory` and `ExecStart` in
   `postgres-backup.service` to match.

9. Verify the web surface per `deployment.md`: open `publicUrl`, sign in, send a message,
   get a real model reply. Agent-computer proof:
   ```bash
   docker exec qm-sbx-<scope-slug> cat /root/workspace/qm-computer-proof.txt
   ```

## Network exposure

The `docker` target publishes every service on the host with no IP prefix, so **portal is
reachable on `0.0.0.0:8081`** (and core, web-ui and admin on 8080/8082/8083) whether or not
something is proxying in front of it. Caddy or Pangolin adds TLS and a hostname; it does not
close the port. Restrict it at the Hetzner Cloud Firewall or on the host:

- allow `80`/`443` (and SSH) from the internet;
- allow the portal port `8081` only from what actually needs it: a Newt **container**
  connects from its bridge address (`172.17.0.0/16`), a Newt **host binary** from loopback,
  and Caddy proxies over loopback. The Hetzner Cloud Firewall only sees traffic arriving
  from the internet, so denying `8081` there is enough — it does not touch the internal
  Newt→host hop. If you filter on the host with `ufw` instead, allow `172.17.0.0/16` and
  `lo` explicitly;
- never expose `5432` (Postgres) or `8080` (core).

Check from outside once deployed:

```bash
nmap -Pn -p 80,443,8080,8081,8082,8083 <server-ip>
```

## Trust boundary

One deployment operator; a full org of authenticated users, each in their own scope.
Scope-to-scope network isolation is enforced (a separate Docker network per scope), and
core reaches each sandbox by container name. Read [`SECURITY.md`](../../../SECURITY.md)
before exposing this to anyone you would not already trust with the host: the local
sandbox backend runs containers with the host Docker socket available to core, and the
documented gaps for co-located sandboxes (no per-scope disk quota, no sandbox egress
enforcement, container root) still apply.
