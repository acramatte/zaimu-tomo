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

## Document storage migration and backup

Do not remove `zaimu_tomo_uploads` in the migration release. The legacy volume
is the source for the copy to RustFS and remains mounted until the copy,
verification, and restore check have all passed.

### Migration release

Use a maintenance window: drain document-processing work and pause new document
uploads before the copy, then keep them paused until verification is complete.
The application provides both local Mix tasks and release scripts. Both return a
non-zero status after reporting every missing source, failed upload, missing
object, or failed HEAD request.

For a local or development copy, run:

```sh
mix zaimu_tomo.migrate_to_s3 --source-dir priv/uploads
mix zaimu_tomo.verify_storage
```

The deployed release has the same operations without requiring Mix in the
runtime image:

```sh
kamal app exec "bin/migrate_to_s3 /app/lib/zaimu_tomo-0.1.0/priv/uploads"
kamal app exec "bin/verify_storage"
```

`migrate_to_s3` derives each legacy filename from the persisted object key,
HEADs the destination first, and only uploads a missing object. It never changes
a database row, overwrites an existing object, or deletes a legacy file. Re-run
the command once after a successful copy: the second run must report only
`skipped-existing`. `verify_storage` must then report zero missing and zero
failed checks.

Before publishing the separate cleanup release, perform and record a restore
check on a scratch environment: restore the object export first, restore the
PostgreSQL dump second, and run `bin/verify_storage`. Only then remove the
legacy volume mount and the Dockerfile's legacy uploads directory.

### RustFS-safe object export

The backup path uses RustFS's supported S3 API through rclone rather than a
live filesystem walk of `/data`. RustFS documents rclone with an S3 `Other`
remote and `force_path_style = true`; use the production `eu-central-1` region.
This approach was validated locally on 2026-08-24 against the pinned RustFS
`1.0.0-beta.12` image with `rclone/rclone:1.71.1@sha256:d5971950c2b370fb04dd3292541b5bda6d9103143fd7e345aeb435a399388afc`:
an S3 object was exported with `rclone copy --checksum`, verified with
`rclone check --checksum`, restored into a fresh RustFS bucket, and checked
again.

Configure a `rustfs` rclone remote using a restricted read credential and a
separate off-host `storagebox` destination remote. Keep those credentials out
of the repository. A production backup uses a new, date-stamped destination on
every run so it cannot overwrite a prior snapshot:

```ini
[rustfs]
type = s3
provider = Other
access_key_id = <backup-read-access-key>
secret_access_key = <backup-read-secret>
endpoint = http://zaimu-tomo-rustfs:9000
region = eu-central-1
force_path_style = true
```

Nightly backup order is deliberate. While document writes are quiesced, export
and verify objects first, dump PostgreSQL second, then verify the application's
object keys:

```sh
rclone copy --checksum --immutable rustfs:zaimu-tomo-prod \
  storagebox:zaimu-tomo/rustfs/$(date -u +%F)/
rclone check --checksum rustfs:zaimu-tomo-prod \
  storagebox:zaimu-tomo/rustfs/$(date -u +%F)/
pg_dump "$DATABASE_URL" > /backups/zaimu-tomo/zaimu-tomo-$(date -u +%F).sql
kamal app exec "bin/verify_storage"
```

The object export precedes the database dump because object creation precedes
row insertion and row deletion precedes object deletion. A completed export may
therefore include harmless orphan objects, but it must not be newer than the
database dump. Do not replace this with `restic /data` against a live RustFS
server unless an equivalent crash-consistent snapshot method has been validated.
