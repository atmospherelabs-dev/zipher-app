# frostd deployment

Production target: `frost.atmospherelabs.dev`

Zipher uses the Zcash Foundation `frostd` relay for FROST DKG and signing
message transport. The relay is intentionally dumb: clients authenticate to the
server, but FROST protocol messages must be end-to-end encrypted by clients.

## Install

```sh
cargo install --git https://github.com/ZcashFoundation/frost-tools.git --locked frostd
sudo useradd --system --home /var/lib/frostd --shell /usr/sbin/nologin frostd
sudo install -d -o frostd -g frostd /var/lib/frostd
sudo install -m 0644 deploy/frostd/frostd.service /etc/systemd/system/frostd.service
sudo systemctl daemon-reload
sudo systemctl enable --now frostd
```

## Caddy

Merge `deploy/frostd/Caddyfile` into the production Caddyfile and reload:

```sh
sudo caddy validate --config /etc/caddy/Caddyfile
sudo systemctl reload caddy
```

## Privacy / Safety

- Do not enable access logs for `frost.atmospherelabs.dev`.
- Do not forward client IP headers to `frostd`.
- Bind `frostd` to `127.0.0.1:2744` only.
- Use Caddy for public TLS.
- Rate limiting should be added at the edge if request volume grows.
