# VPS deployment with Kamal

This branch prepares deployment to a Hetzner VPS where SSH is reachable publicly and the application is exposed only over WireGuard. Real host/IP values are read from environment variables or `.kamal/secrets`, not committed to git.

## Network plan

- Kamal connects over SSH to `KAMAL_SSH_HOST` as `KAMAL_SSH_USER`, defaulting to `kamal`.
- The app is not exposed on the public address: Kamal Proxy is configured for `PHX_HOST` and binds only on `KAMAL_PROXY_BIND_IP`, so the app is reachable on the VPN but not on the public interface.
- nginx already owns `0.0.0.0:80` on the VPS, and ports `8080`, `8081`, `8082`, and `1883` are reserved. Kamal Proxy therefore binds the unreserved VPN-only port `10.0.0.1:8083`, and nginx should forward `http://10.0.0.1` to it.
- If port `8083` becomes reserved later, change Kamal Proxy's `http_port` and the matching nginx `proxy_pass` target.
- PostgreSQL is a Kamal accessory. Its host port is bound to `127.0.0.1:5433` only; the app should use Docker networking via `zaimu-tomo-db:5432`.
- Uploaded documents use the Docker named volume `zaimu_tomo_uploads`, so the `kamal` user does not need sudo access to create host directories. The application runs as UID/GID `65534` so it can keep writing an existing upload volume created by the previous Debian/nobody-based image.
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

- `Dockerfile` builds a Phoenix release and runs it on `gcr.io/distroless/cc-debian13:debug-nonroot` to reduce runtime image size while keeping the `/bin/sh` support required by Elixir release scripts. The final image still uses a non-root numeric user, but pins it to UID/GID `65534` to match the existing uploads volume ownership from the earlier Debian `nobody` runtime.
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
6. Boot the accessory and deploy:
   ```sh
   kamal accessory boot db
   kamal setup
   kamal app exec "bin/migrate"
   ```

For later deploys, run `kamal deploy` and then run migrations when migrations are present:

```sh
kamal app exec "bin/migrate"
```

The configured aliases are invoked directly as Kamal commands, for example `kamal migrate` and `kamal db_rollback`, not through a `kamal alias ...` subcommand.
