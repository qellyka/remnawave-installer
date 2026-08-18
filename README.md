# remnawave-installer

Interactive installer for [Remnawave](https://github.com/remnawave) (panel + node) — Nginx + nftables, no Docker-based reverse proxy, no UFW.

## Quick start

```bash
curl -fsSL https://raw.githubusercontent.com/qellyka/remnawave-installer/main/remnawave-deploy.sh -o remnawave-deploy.sh
chmod +x remnawave-deploy.sh
sudo ./remnawave-deploy.sh
```

Everything from there is interactive — the script asks what it needs, when it needs it, with a short explanation before each question (e.g. "you'll need a DNS A record pointing at this server before this step").

## Repository layout

```
remnawave-deploy.sh       <- the only file you actually run
README.md
index.html                <- camouflage page served on the CDN-fronted node's root path
```

`remnawave-inbounds/` (pre-built inbound templates) isn't created yet — that
feature isn't implemented in the script either, it's reserved for later.

`remnawave-deploy.sh` is fully self-contained. It embeds three small Python helper
scripts (API provisioning, admin/token bootstrap, node listing) as heredocs and
writes them to disk itself at runtime — you never need to upload or manage those
separately. The only two things this repo needs to serve are the deploy script
itself and the decoy page.

## What it does

On launch, you pick one of three top-level modes:

### 1) Panel

Fetches the official `docker-compose-prod.yml` + `.env.sample` from
`remnawave/backend`, generates all secrets, brings up the panel containers,
issues Let's Encrypt certificates for the panel and subscription-page domains,
writes hardened Nginx configs (shared SSL/gzip snippet, `ssl_reject_handshake`
for any connection with the wrong SNI), and opens only 80/443 in nftables.

Optionally, it can register the first admin account and create a long-lived
API token entirely on its own (only works on a freshly-installed, still-empty
panel — registration closes itself after the first account exists). That
token is then used immediately to configure the subscription-page container
correctly (`REMNAWAVE_API_TOKEN`, `TRUST_PROXY`, etc.) — something that's easy
to get wrong by hand, since the official subscription-page docs require a
token there too.

### 2) Node — new server, full setup

You choose any combination of:

- **Reality + TCP** (raw)
- **Reality + gRPC**
- **Reality + XHTTP** (still Reality-secured — direct connection, not CDN-compatible)
- **Hysteria2**
- **TLS + XHTTP through a CDN** (a separate inbound from the three above — CDN-fronting is the whole point of this one, and it's the only one of the five that can sit behind a CDN, since Reality needs a direct TLS handshake with the real client and CDNs terminate TLS themselves)

The four Reality/Hysteria2 presets use fixed, sensible defaults (ports, SNI
donor) with no extra prompts — "base" means it just works. The CDN option
asks for two domains (origin + public CDN domain) and stands up its own
Nginx reverse-proxy with the `upstream {} + keepalive` pattern that keeps
XHTTP's many-small-request traffic stable — this specific detail took days
of trial and error to nail down, it's not a guess.

Reality key generation uses the official Xray-core installer (`xray x25519`)
just for the keygen utility; Hysteria2 gets a self-signed certificate.
Firewall: nftables only, scoped to exactly the ports the chosen inbounds need.

### 3) Node — apply our inbounds to an already-existing node

For nodes you don't have server/SSH access to (e.g. bought from a host that
only gives you an IP and connection details, already registered in the
panel). Everything happens through the Remnawave REST API instead:

- Give it the panel URL + an API token, it lists your existing nodes by
  name/address/connection status so you pick one — no manual UUID copying.
- Same inbound choices as above, minus "just connect" (it's already
  connected) and minus any step that would need to touch that server's
  filesystem or Docker:
  - Reality keys are still just plain values embedded in the JSON config —
    no filesystem access needed, works identically to the full-setup case.
  - Hysteria2 and the CDN inbound's TLS certificate are embedded **inline**
    in the config (`certificate`/`key` as a line-array) instead of
    referencing a file path, since there's nowhere on that server we can
    place a file. Self-signed by default; swap in a real certificate
    (e.g. exported from Yandex Certificate Manager) if you want one.
  - The CDN inbound terminates TLS itself (no Nginx — there's nothing to
    install it on), listening directly on a port you point your CDN's
    origin settings at.
- The script does **not** touch that server's firewall automatically — we
  have no idea what the hosting provider already configured there, and
  blindly flushing an unknown ruleset is a good way to lock yourself out.
  It just prints exactly which ports need to be reachable, and leaves
  applying that to you.

Under the hood, this uses `PATCH /api/nodes` (update the existing node's
config profile) instead of `POST /api/nodes` (create a new one) — verified
against Remnawave's own OpenAPI spec, not guessed.

## A few notes on how this was built

- Every generated `nftables` ruleset is validated with a real `nft -c`
  during development, not just eyeballed.
- The whole script is checked with `shellcheck` on every change.
- The embedded Python helpers are tested against mocked API responses that
  match Remnawave's actual OpenAPI schema field-for-field before being
  folded back into the bash heredocs.
