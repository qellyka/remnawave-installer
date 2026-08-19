# remnawave-installer

Interactive installer for [Remnawave](https://github.com/remnawave) — Nginx + nftables, no Docker-based reverse proxy, no UFW. Split into two independent scripts, one per job.

## Quick start

**Panel:**
```bash
curl -fsSL https://raw.githubusercontent.com/qellyka/remnawave-installer/main/remnawave-panel-deploy.sh -o remnawave-panel-deploy.sh
chmod +x remnawave-panel-deploy.sh
sudo ./remnawave-panel-deploy.sh
```

**Node:**
```bash
curl -fsSL https://raw.githubusercontent.com/qellyka/remnawave-installer/main/remnawave-node-deploy.sh -o remnawave-node-deploy.sh
chmod +x remnawave-node-deploy.sh
sudo ./remnawave-node-deploy.sh
```

Everything from there is interactive — each script asks what it needs, when it needs it, with a short explanation before each question (e.g. "you'll need a DNS A record pointing at this server before this step").

## Repository layout

```
remnawave-panel-deploy.sh   <- run this on the panel server
remnawave-node-deploy.sh    <- run this on each node server
README.md
index.html                  <- camouflage page served on the CDN-fronted node's root path
```

`remnawave-inbounds/` (pre-built inbound templates) isn't created yet — that
feature isn't implemented in the script either, it's reserved for later.

Both scripts are fully self-contained. They embed small Python helper
scripts (API calls) as heredocs and write them to disk at runtime — you
never need to upload or manage those `.py` files separately. A handful of
shared helpers (base package install, nftables, cert issuance, Reality/Hysteria2
key generation) are duplicated between the two files on purpose, so either one
works standalone with a single `curl`.

## remnawave-panel-deploy.sh

Fetches the official `docker-compose-prod.yml` + `.env.sample` from
`remnawave/backend`, generates all secrets, brings up the panel containers,
issues Let's Encrypt certificates for the panel and subscription-page domains,
writes hardened Nginx configs (shared SSL/gzip snippet, `ssl_reject_handshake`
for any connection with the wrong SNI), and opens only 80/443 in nftables.

Optionally, it can register the first admin account (only works on a
freshly-installed, still-empty panel — registration closes itself after the
first account exists) and use the resulting token to configure the
subscription-page container correctly (`REMNAWAVE_API_TOKEN`, `TRUST_PROXY`,
etc.) — something that's easy to get wrong by hand.

It can then also create a **Config Profile with the 4 base inbound presets**
(Reality+TCP, Reality+gRPC, Reality+XHTTP, Hysteria2) right away, before any
node exists — so the first time you run the node script, there's already
something to pick from its "reuse an existing profile" option instead of
generating everything from scratch. The CDN inbound isn't included here on
purpose: it's tied to a specific node's domain, which isn't known yet at
panel-install time.

## remnawave-node-deploy.sh

Asks upfront whether this is a **new server** (full setup, agent installed
from scratch) or an **existing node** you don't have shell access to (e.g.
bought from a host that only gives you an IP and connection details, already
registered in the panel — everything then happens through the Remnawave REST
API, and the script won't touch that server's firewall since it has no idea
what the host already configured there).

Either way, you choose any combination of:

- **Reality + TCP** (raw)
- **Reality + gRPC**
- **Reality + XHTTP** (still Reality-secured — direct connection, not CDN-compatible)
- **Hysteria2**
- **TLS + XHTTP through a CDN** (a separate inbound from the four above — CDN-fronting is the whole point of this one, and it's the only one that can sit behind a CDN, since Reality needs a direct TLS handshake with the real client and CDNs terminate TLS themselves)
- **Reuse an existing Config Profile from the panel** — lists profiles (and their inbounds) via the API and lets you pick which ones to activate on this node, instead of generating new keys and a new profile every time

The four Reality/Hysteria2 presets use fixed, sensible defaults (ports, SNI
donor) with no extra prompts — "base" means it just works. The CDN option
asks for two domains (origin + public CDN domain).

On a server with shell access, the CDN inbound gets its own Nginx reverse-proxy
with the `upstream {} + keepalive` pattern that keeps XHTTP's many-small-request
traffic stable — this specific detail took days of trial and error to nail
down, it's not a guess. On an existing node with no shell access, there's no
Nginx to install, so Xray terminates TLS itself, with a self-signed
certificate embedded inline in the config (swap in a real one, e.g. from
Yandex Certificate Manager, if you want).

Reality key generation uses the official Xray-core installer (`xray x25519`)
just for the keygen utility. Firewall: nftables only, scoped to exactly the
ports the chosen inbounds need — except on an existing node, where it's never
touched automatically; the script just prints which ports need to be open.

Under the hood, updating an already-existing node uses `PATCH /api/nodes`
instead of `POST /api/nodes` — verified against Remnawave's own OpenAPI spec,
not guessed.

## A few notes on how this was built

- Every generated `nftables` ruleset is validated with a real `nft -c`
  during development, not just eyeballed.
- Both scripts are checked with `shellcheck` on every change.
- The embedded Python helpers are tested against mocked API responses that
  match Remnawave's actual OpenAPI schema field-for-field before being
  folded back into the bash heredocs.
