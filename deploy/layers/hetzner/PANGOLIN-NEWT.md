# Pangolin + Newt ingress for a Docker-target qm deploy

qm's portal publishes on a host port (default `8081` — `QM_BASE_PORT` 8080 +
portal offset 1). When the public ingress is Pangolin with a Newt tunnel, the
**Newt deployment shape decides what address the Pangolin route targets**.
The common 502 ("Bad Gateway") is almost always the wrong address for a
Newt running as a Docker container.

## The one rule

Newt resolves the Pangolin route target **from inside its own process**.
If Newt is a Docker container, `http://localhost:8081` and `http://127.0.0.1:8081`
point at Newt's *own* loopback — nothing is listening there, so Pangolin gets
a 502. The target must be an address that reaches the *host* where qm's
portal is published.

| Newt shape | Pangolin route target | Why |
|---|---|---|
| Host binary (systemd, bare) | `http://127.0.0.1:8081` | Newt shares the host loopback |
| Docker container (default bridge) | `http://172.17.0.1:8081` | Newt reaches the host via the Docker bridge gateway |
| Docker container (with `--add-host=host.docker.internal:host-gateway`) | `http://host.docker.internal:8081` | Newt reaches the host via the documented alias |

Portal binds `0.0.0.0:8081` (the docker target publishes with no IP prefix), so
any host-reachable address works; the question is only what Newt's process
can resolve to the host.

## Find the right address (run on the qm host)

```bash
# 1. Confirm portal is up on the host (expect 401 — the front door rejecting
#    an unauthenticated probe is healthy)
curl -sI http://localhost:8081 | head -3

# 2. Is Newt a container or a host binary?
docker ps --format '{{.Names}}\t{{.Image}}' | grep -i newt || echo "Newt is a host binary"

# 3. If Newt is a container, does it have a host-gateway mapping?
docker inspect $(docker ps -q --filter "name=newt") \
  --format '{{range .HostConfig.ExtraHosts}}{{println .}}{{end}}' | grep -i gateway \
  || echo "no host-gateway mapping"

# 4. The Docker bridge gateway (the reliable default for a container Newt)
docker network inspect bridge --format '{{range .IPAM.Config}}{{.Gateway}}{{end}}'
#   -> usually 172.17.0.1
```

- Step 3 prints a host-gateway line → use `http://host.docker.internal:8081`
- Step 3 says "no host-gateway mapping" → use the step-4 gateway,
  `http://172.17.0.1:8081`

## Configure the Pangolin route

In Pangolin, create a route for the qm domain (e.g. `qm.example.com`)
targeting the address chosen above:

- **Target:** `http://172.17.0.1:8081` (container Newt, no host-gateway) — the
  common case
- **Method:** GET (portal serves the web UI; Pangolin passes HTTP through)
- **TLS:** Pangolin terminates it at the tunnel edge; do not configure TLS on
  the qm host (no Caddy, no Let's Encrypt)

Set `publicUrl` in `qm.config.jsonc` to the Pangolin domain
(`https://qm.example.com`), not a direct host address.

## Verify

```bash
# from the host
curl -sI -H "Host: qm.example.com" http://localhost:8081 | head -3
# from a browser
#   https://qm.example.com  -> sign-in page
```

A `401`/`200` from curl and the sign-in page in a browser mean the path is
correct end to end. A `502 Bad Gateway` means the route target is wrong —
re-run the diagnose steps; the most common fix is switching `localhost` /
`127.0.0.1` to `172.17.0.1`.

## Notes

- Newt and qm share the Docker daemon but **not a network**: Newt is on its
  own `pangolin-newt_default` network; qm's services are on `qm-net-<org>`.
  The bridge gateway is the shared path between them.
- If `QM_BASE_PORT` is overridden (so portal is not on 8081), use
  `QM_BASE_PORT + 1` in the target.
- This guide assumes the built-in auth broker (the `auth` service). For
  external OIDC, the same ingress applies; only the portal's sign-in flow
  differs.
