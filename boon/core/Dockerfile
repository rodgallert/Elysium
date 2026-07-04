# syntax=docker/dockerfile:1
# check=error=true

# Single Dockerfile, development only — this app doesn't ship to production (yet).
# If that changes, split into separate dev/production Dockerfiles instead of branching this one.
#
# Build context is the MONOREPO ROOT (not ./core) — core/Gemfile depends on the "domain" gem via
# `path: "domain"`, and checkout/worker need that same core/domain via `path: "../core/domain"`.
# Docker can't COPY from outside its build context, so every Ruby service's image is built from
# the repo root and mirrors the host's relative layout under /workspace, both at build time and
# via the docker-compose bind mount — otherwise Bundler's relative paths break.

ARG RUBY_VERSION=3.4.10
FROM docker.io/library/ruby:$RUBY_VERSION-slim

WORKDIR /workspace/core

# build-essential/libpq-dev stay in the image (not a throw-away build stage) so `bundle install`
# can compile native extensions again later, after a Gemfile change, without rebuilding from base.
RUN apt-get update -qq && \
    apt-get install --no-install-recommends -y \
      build-essential curl git libjemalloc2 libpq-dev libvips libyaml-dev pkg-config postgresql-client && \
    ln -s /usr/lib/$(uname -m)-linux-gnu/libjemalloc.so.2 /usr/local/lib/libjemalloc.so && \
    rm -rf /var/lib/apt/lists /var/cache/apt/archives

ENV RAILS_ENV="development" \
    BUNDLE_PATH="/usr/local/bundle" \
    LD_PRELOAD="/usr/local/lib/libjemalloc.so"

# Match the host user (uid/gid 1000) so files created via the bind mount stay editable outside
# the container, and so `bin/docker-entrypoint` isn't running as root for no reason.
RUN groupadd --system --gid 1000 rails && \
    useradd rails --uid 1000 --gid 1000 --create-home --shell /bin/bash
USER 1000:1000

COPY --chown=rails:rails core /workspace/core
RUN bundle install

ENTRYPOINT ["./bin/docker-entrypoint"]

EXPOSE 3000
CMD ["./bin/rails", "server"]
