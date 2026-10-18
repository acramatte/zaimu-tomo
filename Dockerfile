# syntax=docker/dockerfile:1

ARG ELIXIR_VERSION=1.19.4
ARG OTP_VERSION=28
ARG DEBIAN_VERSION=debian13

ARG BUILDER_IMAGE=elixir:${ELIXIR_VERSION}-otp-${OTP_VERSION}
# Standard Elixir release launcher scripts require /bin/sh. Distroless
# debug keeps the runtime much smaller than Debian slim while still providing
# BusyBox sh for bin/zaimu_tomo and rel/overlays/bin/migrate.
ARG RUNNER_IMAGE=gcr.io/distroless/cc-${DEBIAN_VERSION}:debug-nonroot
# Keep the runtime UID/GID aligned with the previous Debian nobody user.
# The persistent uploads Docker volume may already be owned by 65534 from
# earlier non-distroless deployments; distroless nonroot uses 65532 and cannot
# write that volume.
ARG APP_UID=65534
ARG APP_GID=65534

FROM ${BUILDER_IMAGE} AS builder

RUN apt-get update -y && apt-get install -y --no-install-recommends \
    build-essential git curl \
  && apt-get clean && rm -rf /var/lib/apt/lists/*

WORKDIR /app

RUN mix local.hex --force && mix local.rebar --force

ENV MIX_ENV=prod

COPY mix.exs mix.lock ./
COPY config config
RUN mix deps.get --only prod
RUN mix deps.compile

COPY priv priv
COPY lib lib
COPY assets assets
COPY rel rel

# Compile first so Phoenix LiveView can generate colocated hook modules
# imported by assets/js/app.js as phoenix-colocated/zaimu_tomo.
RUN mix compile
RUN mix assets.deploy
RUN mix release
# Keep the legacy upload path for the migration release. Phase 5 removes it only
# after legacy bytes have been copied, verified, and restore-tested in RustFS.
RUN mkdir -p /app/_build/prod/rel/zaimu_tomo/lib/zaimu_tomo-0.1.0/priv/uploads
# Staged here so it can be copied into the runner with the app's ownership:
# distroless has no mkdir/chown, and its world-writable /tmp would otherwise
# leave OCR temp files world-readable.
RUN mkdir -p /staged-tmp/zaimu-tomo && chmod 700 /staged-tmp/zaimu-tomo
RUN mkdir -p /distroless-bin && ln -s /busybox/sh /distroless-bin/sh

FROM ${RUNNER_IMAGE} AS runner

# Global ARGs declared before the first FROM aren't visible inside a stage
# until re-declared here; without this, --chown below resolves to an empty
# uid/gid and the COPY fails with "no such user".
ARG APP_UID
ARG APP_GID

ENV LANG=C.UTF-8 \
    LANGUAGE=en_US:en \
    LC_ALL=C.UTF-8 \
    ELIXIR_ERL_OPTIONS="+fnu" \
    MIX_ENV=prod \
    PHX_SERVER=true \
    PORT=4000

WORKDIR /app

# Release launcher scripts use #!/bin/sh. The distroless debug image ships
# BusyBox at /busybox/sh but intentionally does not create /bin/sh.
COPY --from=builder /distroless-bin/ /bin/
# Erlang/OTP's beam.smp links against libtinfo, which is not included in
# distroless/cc. Copy only that missing runtime library from the matching
# Debian builder image rather than installing a package manager in the final image.
COPY --from=builder /usr/lib/x86_64-linux-gnu/libtinfo.so.6* /usr/lib/x86_64-linux-gnu/
COPY --from=builder --chown=${APP_UID}:${APP_GID} /app/_build/prod/rel/zaimu_tomo ./
COPY --from=builder --chown=${APP_UID}:${APP_GID} /staged-tmp/zaimu-tomo /tmp/zaimu-tomo

USER ${APP_UID}:${APP_GID}

EXPOSE 4000

# /health is served by ZaimuTomoWeb.HealthController on the public scope
# (no auth required). Distroless has no curl; BusyBox wget (verified present
# in the distroless debug image) takes its place. The shell form runs via
# /bin/sh (symlinked to /busybox/sh above) so $PORT is expanded at runtime
# and follows the container's actual PORT env var.
HEALTHCHECK --interval=30s --timeout=5s --start-period=30s --retries=3 \
  CMD wget -q -O /dev/null "http://localhost:$PORT/health" || exit 1

CMD ["/app/bin/zaimu_tomo", "start"]
