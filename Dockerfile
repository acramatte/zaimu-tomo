# syntax=docker/dockerfile:1

ARG ELIXIR_VERSION=1.19.4
ARG OTP_VERSION=28
ARG DEBIAN_VERSION=trixie-slim

ARG BUILDER_IMAGE=elixir:${ELIXIR_VERSION}-otp-${OTP_VERSION}
ARG RUNNER_IMAGE=debian:${DEBIAN_VERSION}

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

FROM ${RUNNER_IMAGE} AS runner

RUN apt-get update -y && apt-get install -y --no-install-recommends \
    ca-certificates curl libstdc++6 openssl libncurses6 locales \
  && apt-get clean && rm -rf /var/lib/apt/lists/*

RUN sed -i '/en_US.UTF-8/s/^# //g' /etc/locale.gen && locale-gen

ENV LANG=en_US.UTF-8 \
    LANGUAGE=en_US:en \
    LC_ALL=en_US.UTF-8 \
    MIX_ENV=prod \
    PHX_SERVER=true \
    PORT=4000

WORKDIR /app
RUN chown nobody /app
RUN mkdir -p /tmp/zaimu-tomo && chown nobody:root /tmp/zaimu-tomo && chmod 700 /tmp/zaimu-tomo

COPY --from=builder --chown=nobody:root /app/_build/prod/rel/zaimu_tomo ./
RUN mkdir -p /app/lib/zaimu_tomo-0.1.0/priv/uploads && chown -R nobody:root /app/lib/zaimu_tomo-0.1.0/priv/uploads

USER nobody

EXPOSE 4000

# /health is served by ZaimuTomoWeb.HealthController on the public scope
# (no auth required). HEALTHCHECK does not do build-time variable
# substitution, so $PORT is expanded by the runtime shell and follows the
# container's actual PORT env var.
HEALTHCHECK --interval=30s --timeout=5s --start-period=30s --retries=3 \
  CMD curl -fsS "http://localhost:$PORT/health" > /dev/null || exit 1

CMD ["/app/bin/zaimu_tomo", "start"]
