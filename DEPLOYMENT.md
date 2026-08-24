# VPS deployment with Kamal

This branch prepares deployment to a Hetzner VPS where SSH is reachable publicly and the application is exposed only over WireGuard. Real host/IP values are read from environment variables or `.kamal/secrets`, not committed to git.

## Network plan

- Kamal connects over SSH to `KAMAL_SSH_HOST` as `KAMAL_SSH_USER`, defaulting to `kamal`.
- The app is not exposed on the public address: Kamal Proxy is configured for `PHX_HOST` and binds only on `KAMAL_PROXY_BIND_IP`, so the app is reachable on the VPN but not on the public interface.
- nginx already owns `0.0.0.0:80` on the VPS, and ports `8080`, `8081`, `8082`, and `1883` are reserved. Kamal Proxy therefore binds the unreserved VPN-only port `10.0.0.1:8083`, and nginx should forward `http://10.0.0.1` to it.
- If port `8083` becomes reserved later, change Kamal Proxy's `http_port` and the matching nginx `proxy_pass` target.
- PostgreSQL is a Kamal accessory. Its host port is bound to `127.0.0.1:5433` only; the app should use Docker networking via `zaimu-tomo-db:5432`.
- RustFS is a private Kamal accessory. The app reaches it through Docker DNS as
  `zaimu-tomo-rustfs:9000`; neither its S3 API nor its console is published to
  the host. PostgreSQL and self-hosted RustFS are operated with ZaimuTomo;
  Mistral remains the only third-party document-processing service.
- The legacy `zaimu_tomo_uploads` Docker named volume remains mounted during the
  migration release. It must not be removed until the Phase 5 copy,
  `verify_storage`, and restore check have completed.
- The VPS runs Watchtower. The Kamal app and PostgreSQL accessory are labelled with `com.centurylinklabs.watchtower.enable=false` so Watchtower does not restart/upgrade containers outside Kamal's deployment flow.
- The existing `deployer` SSH account can remain restricted to the forced command `/usr/local/bin/load-docker-iamge.sh`. Kamal should use a separate dedicated user, for example `kamal`, because it must run Docker commands such as network creation, login, pull/load, run, stop, rename, health checks, and container inspection.

## Dedicated Kamal user

A practical least-privilege setup is a dedicated `kamal` user with SSH key-only access and Docker access, but no sudo. Be aware that membership in the `docker` group is effectively root-equivalent on the host because Docker can mount host paths and control containers. The main security improvement is isolation from your normal/deployer account and tight SSH access, not true confinement from root.

Suggested server-side baseline:

```sh
sudo adduser --disabled-password --gecos "" kamal
sudo usermod -aG docker kamal
sudo install -d -m 700 -o kamal -g kamal /home/kamal/.ssh
sudo install -m 600 -o kamal -g kamal /path/to/kamal_authorized_keys /home/kamal/.ssh/authorized_keys
```

Recommended SSH hardening in `/etc/ssh/sshd_config.d/kamal.conf`:

```sshconfig
Match User kamal
  PasswordAuthentication no
  KbdInteractiveAuthentication no
  X11Forwarding no
  AllowTcpForwarding no
  PermitTunnel no
  PermitTTY yes
```

If you want stronger isolation from the VPS's existing Docker containers, investigate rootless Docker for the `kamal` user. That is more complex with Kamal Proxy and port 80 binding, so the current config assumes the normal Docker daemon.

## Files

- `Dockerfile` builds a Phoenix release.
- `config/deploy.yml` is the Kamal config with placeholders to replace.
- `.kamal/secrets.example` documents required secrets; copy it to `.kamal/secrets` or export variables.
- `lib/zaimu_tomo/release.ex` provides release migration commands, and `rel/overlays/bin/migrate` exposes them as a release script included at `bin/migrate`.
- `/health` is the primary unauthenticated health check for Kamal Proxy and common infrastructure conventions. `/up` is also exposed as a Kamal-compatible alias. Both are intentionally placed in a root router scope with no pipeline because they must not require sessions or authentication.
- `config/prod.exs` only enables `force_ssl` when the image is compiled with `FORCE_SSL=true`; the default fits VPN-only HTTP behind Kamal Proxy.

## First deploy

1. Install Kamal locally.
2. Set local deployment values in `.kamal/secrets` or your shell:
   ```sh
   KAMAL_SSH_HOST=<public VPS SSH IP or DNS>
   KAMAL_SSH_USER=kamal
   KAMAL_PROXY_BIND_IP=10.0.0.1
   PHX_HOST=10.0.0.1
   ```
3. Prepare secrets:
   ```sh
   cp .kamal/secrets.example .kamal/secrets
   mix phx.gen.secret
   ```
   `config/deploy.yml` uses ERB for non-committed host values, so export the secrets before running Kamal commands:
   ```sh
   set -a
   source .kamal/secrets
   set +a
   ```
4. Set `DATABASE_URL` for the Kamal-managed DB, for example:
   ```text
   postgresql://zaimu_tomo:<POSTGRES_PASSWORD>@zaimu-tomo-db:5432/zaimu_tomo_prod
   ```
5. Configure nginx on the VPS to forward the VPN HTTP endpoint to Kamal Proxy:
   ```nginx
   server {
     listen 10.0.0.1:80;
     server_name 10.0.0.1;

     location / {
       proxy_pass http://10.0.0.1:8083;
       proxy_http_version 1.1;
       proxy_set_header Host $host;
       proxy_set_header X-Forwarded-Host $host;
       proxy_set_header X-Forwarded-Proto $scheme;
       proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
       proxy_set_header X-Real-IP $remote_addr;
       proxy_set_header Upgrade $http_upgrade;
       proxy_set_header Connection "upgrade";
     }
   }
   ```
   Then test and reload nginx:
   ```sh
   sudo nginx -t
   sudo systemctl reload nginx
   ```
6. Boot the accessories and deploy:
   ```sh
   kamal accessory boot db
   kamal accessory boot rustfs
   kamal setup
   kamal app exec "bin/migrate"
   ```

7. Create `zaimu-tomo-prod` in the RustFS console with versioning and Object
   Lock enabled. Object Lock must be enabled when the bucket is created and
   cannot be retrofitted. The initial RustFS credential and the app's
   `S3_SECRET_ACCESS_KEY` intentionally have the same value; keep the app
   configuration provider-neutral through `S3_*` variables.

For later deploys, run `kamal deploy` and then run migrations when migrations are present:

```sh
kamal app exec "bin/migrate"
```

The configured aliases are invoked directly as Kamal commands, for example `kamal migrate` and `kamal db_rollback`, not through a `kamal alias ...` subcommand.

## Document storage backup and migration

Do not remove `zaimu_tomo_uploads` in this deployment. The next migration phase
copies legacy document bytes from that volume to RustFS and verifies every
database object key before a separate cleanup release removes the volume and
the image directory preparation.

For the future nightly backup job, make the object-store backup or supported
export first, then run `pg_dump`, then `mix zaimu_tomo.verify_storage`. A plain
live walk of RustFS `/data` is not assumed application-consistent: first validate
a RustFS-supported online export or crash-consistent snapshot. Until then,
briefly quiesce document writes across the object snapshot and PostgreSQL dump.
