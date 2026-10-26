# syntax=docker/dockerfile:1
# The Timekeeping service image, for the local demo only: no deploy lane uses
# it (docs/architecture/timekeeping-soa.md section 11.1).
#
# Build it from the repository root, because timekeeping/Gemfile loads the
# shared gems from ../gems:
#
#   docker build -f timekeeping/Dockerfile -t miru-timekeeping .
#
# timekeeping/Dockerfile.dockerignore replaces the root .dockerignore for this
# build. It lets in only timekeeping/ and gems/, and keeps out local Bundler
# config, env files and keys, which the root file excludes only at the root.
#
# Every key and URL the service reads (section 11.2) comes from the process
# environment when the container starts; none is set here.
FROM ruby:4.0.1-slim AS base

ENV BUNDLE_PATH="/usr/local/bundle" \
    BUNDLE_WITHOUT="development:test" \
    RAILS_ENV="production"

RUN apt-get update && apt-get install -y --no-install-recommends postgresql-client && \
    apt-get clean && rm -rf /var/lib/apt/lists/* /var/cache/apt/archives/*

# The app sits beside the shared gems, so the Gemfile's ../gems paths resolve.
WORKDIR /app/timekeeping


FROM base AS build-deps

RUN apt-get update && apt-get install -y --no-install-recommends git build-essential libpq-dev && \
    apt-get clean && rm -rf /var/lib/apt/lists/* /var/cache/apt/archives/*


FROM build-deps AS gems

# The Bundler version timekeeping/Gemfile.lock was written with.
RUN gem install bundler -v 4.0.3

COPY gems /app/gems
COPY timekeeping/Gemfile timekeeping/Gemfile.lock ./

RUN bundle install && rm -rf /usr/local/bundle/cache


FROM base

COPY --from=gems /usr/local/bundle /usr/local/bundle
COPY gems /app/gems
COPY timekeeping /app/timekeeping

# log/ and tmp/ are left out of the build context; Rails and puma write there.
RUN mkdir -p log tmp/pids

EXPOSE 3000

CMD ["bin/rails", "server", "-b", "0.0.0.0", "-p", "3000"]
