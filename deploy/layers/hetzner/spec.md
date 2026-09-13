# Hetzner single-VM deployment — design spec

Status: approved. Operator review gate passed. Config policy: commit template `qm.config.jsonc` with placeholders (operator edits real values at install). Scope: Part A (fork-layer scaffolding) + Part B (upstream core hardening §6.1/6.2), both included in this build.
Scope: fork of qm (`origin` → your fork, `upstream` → `yc-software/qm`).
Fork-rule compliance: org-specific material under `deploy/layers/<org>/`; core stays byte-identical; core changes go upstream via `upstream-pr`.

## 1. Goal

Deploy qm to a single Hetzner Cloud VM for one trusted operator, using the existing `SANDBOX_BACKEND=local` substrate (Docker containers co-located with core). Core-sanctioned production configuration: the production config test fixture runs on `local` (`test/config.test.ts:13`), and the production gate names `local` as valid (`src/config.ts:580`).

## 2. Architecture

Single Hetzner VM (CX/CAX). All qm services as Docker containers. Agent computers as co-located Docker containers via the `local` sandbox backend (`resident_disk`, per-scope Docker networks + named volumes). Postgres as a container on the same VM with `pg_dump`/restic backups.

### 2.1 Topology

```
Internet :443 → Caddy/Traefik (TLS) → portal (OIDC) → {web-ui, admin}
portal → core (private) → Postgres (private)
core → Docker daemon → sandbox[scope] containers (qm-net-<slug>, qm-home-<slug>, 127.0.0.1:0)
```

Portal is the only Internet-facing service. Core, Postgres, auth, sandboxes stay private.

### 2.2 Services (all containers on one VM)

| Service | Container | Exposure | Role |
|---|---|---|---|
| Caddy/Traefik | reverse-proxy | :443 only | TLS terminate, route to portal |
| portal | yes | via proxy | OIDC, proxies web-ui + admin |
| auth | yes | private | email one-time-link broker |
| core | yes | private | API, agent loop, scheduler |
| web-ui | yes | via portal | Vite/Lit UI |
| admin | yes | via portal | admin panel |
| Postgres | yes | private | durable store |
| sandbox ×N | yes (`local`) | private | per-scope agent computers |
| egress-proxy | omitted | — | local = `egressEnforcement: none` |

### 2.3 Agent sandbox flow

Core calls `Sandbox.provision(scope)` → `local` backend creates `qm-sbx-<slug>` on network `qm-net-<slug>`, mounts volume `qm-home-<slug>` (resident_disk), binds `127.0.0.1:0:8080`. Core execs via in-container HTTP daemon. Scope-to-scope networks isolated. Tools persist in the volume across restarts.

## 3. Trust boundary (honest, per SECURITY.md)

**One deployment operator; a full organization of authenticated end users.** Single-VM topology is multi-user, not single-user — the operator deploys, the org signs in, and `ADMIN_GRANTS` is the first admin who then invites others. Each user gets an isolated scope, sandbox, memory, keychain, files — exactly QM's design. SECURITY.md's model is "one organization of authenticated internal users"; N users = up to N scopes = up to N sandbox containers on the same VM. The threat is a *compromised* agent or a *mistaken* one, not a malicious colleague.

This means the sandbox gaps below are **intra-org risks**, not "only you, on your box":

- ✅ Scope-to-scope network isolation (separate Docker networks — verified in `local-sandbox.ts`)
- ✅ Ports bound to `127.0.0.1` (not external — verified)
- ⚠️ host-gateway ON (hardcoded `local-sandbox.ts:256`) — sandboxes can reach core/Postgres on the host. Accepted risk OR upstream knob (§6.1).
- ⚠️ no per-scope disk quota (absent in `local-sandbox.ts`) — one scope can fill the disk. Accepted risk OR upstream change (§6.2).
- ⚠️ `egressEnforcement: none` — matches local coding agents; no sandbox egress filtering.
- ⚠️ container-root — contained by Docker; escape = host root.

## 4. Fork-layer work (`deploy/layers/<org>/`)

No core edits. The deploy is achievable with the existing `docker` CLI target + `SANDBOX_BACKEND=local`.

### 4.1 Config (template — committed with placeholders)

The committed `qm.config.jsonc` is a **template**: placeholder values (`<domain>`, `<slug>`, `<provider>`) that any operator edits to real values at install time. Zero real org identifiers or secrets ship in the repo. Per the qm contract, `qm.config.jsonc` carries no secret values; real secrets live in gitignored `.env`.

`qm.config.jsonc` template:
- `target: "docker"`
- `publicUrl: "https://<domain>"` (operator fills)
- `orgId: "<slug>"` (operator fills)
- `services`: `["portal","auth","core","web-ui","admin"]` (omit egress-proxy)
- **omit the `sandbox` block entirely** (verified: `sandboxCoreEnv` returns empty env when `sandbox` is absent; `sandbox.app` is NOT required for `target=docker` when the block is omitted — `cli/src/config.ts:1243,1304,1308`)
- `env.core.SANDBOX_BACKEND: "local"` (non-secret; core reads it via `sandboxBackendEnvStrict`)
- `env.core.LOCAL_SANDBOX_CPUS` / `LOCAL_SANDBOX_MEMORY_MB` (per-container caps; settable via env — verified `config.ts:252-256`)
- `env.core.NODE_ENV: "production"` (enables production secrets gate; local is accepted)
- `env.core.DATABASE_URL: "postgres://..."` (Postgres container; operator fills)
- sign-in route env (broker: `AUTH_EMAIL_TRANSPORT`, SMTP or resend) or external OIDC `env.portal.OIDC_*`
- `env.core.HARNESS`, `modelProvider` + provider key in `.env`

### 4.2 Operational wrap (fork-layer)

- VM bootstrap script: install Docker, Buildx, Node 24, clone, `npm ci`
- Reverse proxy (Caddy recommended — auto-HTTPS via Let's Encrypt) config + Caddyfile
- systemd units: core, portal, auth, web-ui, admin, Postgres as containers with restart policies
- Postgres: named volume + `pg_dump` cron + restic backup to Hetzner Storage Box or S3-compatible
- Sandbox image build: `npm run sandbox:local:build` (builds `qm-sandbox-base:dev` from `fly/Dockerfile` + `qm-sandbox-local:latest` from `local/Dockerfile`)
- `.env` with computed secret names (core signing, capability, portal identity, connector, skill signing secrets; provider API key)
- `deployment.md` operator runbook (materialized by `qm init`)

### 4.3 Deploy sequence (operator runs on the VM)

The committed `qm.config.jsonc` is a template. At install, the operator either edits it in place with real `<slug>`/`<domain>`/`<provider>` values, or generates a live copy on the VM via `qm init` and keeps it local. Real secrets go in `.env` (gitignored). The agent does not run these commands — they are the operator runbook.

```bash
node cli/bin/qm.ts init deploy/layers/<slug> --org <slug> --target docker --model-provider <provider>
cd deploy/layers/<slug> && (test -f package-lock.json && npm ci || npm install) && cd -
# edit qm.config.jsonc per §4.1 (omit sandbox block, set SANDBOX_BACKEND=local via env.core)
# build the agent computer image
npm run sandbox:local:build
# validate + deploy
node cli/bin/qm.ts check --config deploy/layers/<slug>/qm.config.jsonc
node cli/bin/qm.ts up --config deploy/layers/<slug>/qm.config.jsonc
node cli/bin/qm.ts doctor
node cli/bin/qm.ts check --live
```

### 4.4 Verification (end state per `deployment.md`)

- Sign in on the web at `publicUrl`, send a message, get a real model reply.
- Agent-computer proof: ask agent to write a UUID to `/root/workspace/qm-computer-proof.txt`; verify on the host via `docker exec qm-sbx-<slug> cat /root/workspace/qm-computer-proof.txt`.
- (Optional Slack) mention the bot, get a reply.

## 5. Operator inputs (filled locally at setup time, not collected by the agent)

The operator performs setup on the VM. The agent does not drive the deploy and does not collect these. They split by where they live:

**Secrets → `.env` (gitignored, never committed):** model provider API key, core signing / capability / portal-identity / connector / skill-signing secrets, `ADMIN_GRANTS` admin email (if treated as sensitive), SMTP/Resend credentials. `qm init` scaffolds a `.gitignore` that keeps `.env` out of git.

**Config → `qm.config.jsonc` (committed, no secrets):** org slug (`orgId`), `publicUrl`, `target`, `services`, sign-in transport choice, `env.core.SANDBOX_BACKEND: "local"`.

For a private fork that never travels upstream, committing `qm.config.jsonc` with orgId + publicUrl is the intended design (reproducible, no secrets). If the operator prefers zero org identifiers in the repo, generate the live `qm.config.jsonc` on the VM and keep it local — see §4.3 note.

Inputs the operator gathers at setup:
1. Org slug (lowercase DNS label)
2. Admin email (`ADMIN_GRANTS=<email>:org_admin`)
3. Sign-in route: (a) auth broker + SMTP/Resend, (b) Slack, (c) external OIDC
4. Model provider + key (anthropic/openai/openrouter; key placed in `.env`)
5. Hetzner VM: type, region, and the publicUrl domain

## 6. Upstream core changes (3, included in this build, via `upstream-pr`)

These are general hardening of `SANDBOX_BACKEND=local` — not Hetzner-specific. They benefit any operator running local in production. Each is a small core edit, cut from `upstream/main`, sent upstream, merged back with `update-qm`. Included in this build per operator decision (intra-org protection + unblock the deploy). **Part A's deploy is gated on §6.3 merging upstream and syncing back; Parts A and B are separable deliverables.**

### 6.3 docker target relaxes `requiresSandboxApp` when `SANDBOX_BACKEND=local` (unblocks the deploy)

Current: the docker provider declares `requiresSandboxApp: true` (`cli/src/backends/registry.ts:171`), and `check.ts:32-34` enforces it: a Fly agent-computer app is required even when `SANDBOX_BACKEND=local` runs sandboxes as local Docker containers. This is the gate that makes a fork-layer-only Hetzner deploy impossible without a core change — `qm check` refuses a docker target with no `sandbox.app`.

Change: in `cli/src/commands/check.ts`, relax the gate so a docker target with `env.core.SANDBOX_BACKEND === "local"` does not require `sandbox.app` (the local backend needs no Fly app). Fly target keeps `requiresSandboxApp: true`. Semantically correct: the requirement is "a Fly agent-computer app for real sandbox execution"; `local` runs agent computers on the host, so no Fly app is needed.

Value: unblocks the single-VM Hetzner deploy (and any operator running `SANDBOX_BACKEND=local` in production). General, org-agnostic. **This is the change Part A depends on; the deploy runs once it merges upstream and syncs back into the fork.**

### 6.4 host-gateway-off knob (intra-org protection)

Current: `--add-host=host.docker.internal:host-gateway` hardcoded (`src/sandbox/local-sandbox.ts:256`). Any user's agent can reach core/Postgres/secrets on the host.

Change: add `hostGateway?: boolean` to `LocalSandboxOptions` + `LocalSandboxEnv` (`LOCAL_SANDBOX_HOST_GATEWAY=0` to disable). Default keeps current behavior (dev). When disabled, omit the `--add-host` flag.

Value: stops one user's compromised agent reaching the host network and every other user's data. **Worth doing before opening sign-in to the team.**

### 6.5 per-scope disk quota (intra-org protection)

Current: no `--storage-opt`/`--device`/`tmpfs` anywhere in `local-sandbox.ts`. One user's agent can fill the host disk.

Change: add `diskGb?: number` to `LocalSandboxOptions` + `LocalSandboxEnv` (`LOCAL_SANDBOX_DISK_GB`), apply `--storage-opt size=<gb>g` in `runContainer`.

Value: stops one user's runaway agent starving the host + every other user. **Worth doing before opening sign-in to the team.**

Storage-driver constraint (operator must know): `docker --storage-opt size=` only works on quota-capable storage drivers (XFS mounted with `prquota`/`pquota`, btrfs, zfs, or devicemapper). On the stock ext4/overlay2 default of a fresh Hetzner Debian/Ubuntu VM, the flag fails and every `provision()` throws. To use `LOCAL_SANDBOX_DISK_GB`, format the Docker volume root as XFS+pquota (or btrfs/zfs); otherwise leave it unset — the disk-quota protection is simply not in force. There is no portable Docker mechanism for per-container disk quota across all storage drivers.

### 6.6 (cosmetic) OS string

Current: `profile.spec.os` hardcodes "(dev only)" (`local-sandbox.ts:324`), reaches the model system prompt via `renderComputerBlock`.

Change: derive from an option or drop the "(dev only)" suffix. Low value; can ride with §6.1/6.2.

## 7. Execution plan (two parts, two branches)

Deliverable = scaffolding + runbook (Part A) and upstream core hardening (Part B). The agent builds both; the operator runs the live deploy later. The two parts target different base branches (fork governance):

- **Part A — fork-layer scaffolding** → branch off the fork's working branch, all files under `deploy/layers/hetzner/`, PR to the fork. No core edits.
- **Part B — upstream core hardening (§6.1/6.2)** → branch off `upstream/main`, core edits in `src/sandbox/local-sandbox.ts` + tests, send upstream via `upstream-pr`. No org identifiers. Merged back later with `update-qm`.

### 7.1 Part A units (fork-layer, `deploy/layers/hetzner/`)

1. Template `qm.config.jsonc` (placeholders per §4.1)
2. `.env.example` (computed secret names, never values)
3. Caddyfile template (TLS, route to portal)
4. systemd unit templates (core/portal/auth/web-ui/admin/Postgres)
5. VM bootstrap script (Docker, Buildx, Node 24, clone, `npm ci`)
6. Postgres backup script (`pg_dump` cron + restic to Storage Box/S3)
7. Operator runbook (`deployment.md` / README) tying §4.3 together

### 7.2 Part B units (upstream core, 3 changes)

8. **Relax `requiresSandboxApp` for docker+local** — `cli/src/commands/check.ts` gate conditional on `env.core.SANDBOX_BACKEND === "local"`; test that docker+local passes `qm check` without `sandbox.app`
9. `hostGateway` knob — `LocalSandboxOptions` + `LocalSandboxEnv` field + `LOCAL_SANDBOX_HOST_GATEWAY` env, conditional `--add-host` in `runContainer` (default keeps current dev behavior)
10. `diskGb` quota — `LocalSandboxOptions` + `LocalSandboxEnv` field + `LOCAL_SANDBOX_DISK_GB` env, `--storage-opt size=<gb>g` in `runContainer`
11. Tests: config parsing of the new env vars; runContainer args conditional on the flags; docker+local check passes without `sandbox.app`

### 7.3 Skills stack

1. **brainstorming** (this spec) → operator review gate ✅
2. **thrifty** builds units 1–10 (decomposed: contract + briefs + gate + verify), small commits per unit
3. **roborev** auto-reviews each commit (post-commit hook active; agent=pi)
4. **fresh-eyes-review** final sanity gate before any merge (Part A PR to fork; Part B PR upstream)
5. Operator runs the live deploy on the VM per the runbook (§4.3), filling real values in `.env`
6. Part B merges upstream → `update-qm` syncs back into the fork

## 8. Fork-rule compliance checklist

- [ ] All org-specific files under `deploy/layers/<org>/`
- [ ] No edits to core (`src/`, `cli/`, `docs/`, `plugins/`, existing root files) for the fork-layer deploy
- [ ] Upstream changes (§6) cut from `upstream/main`, sent via `upstream-pr`, no org identifiers in diff/commits
- [ ] No upstream issue/PR referenced by number
- [ ] No comments added to repo code (zero-comments standard)
