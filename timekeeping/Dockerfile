# syntax=docker/dockerfile:1
# check=error=true

# The Timekeeping service image. Build it from the repository root, because
# the service's Gemfile loads gems/timekeeping_rules by a relative path:
#   docker build -f timekeeping/Dockerfile -t timekeeping .
# timekeeping/Dockerfile.dockerignore limits what the build can see to the
# service and that gem.
#
# The settings come only from the process environment at run time:
# TIMEKEEPING_DATABASE_URL, TIMEKEEPING_TOKEN_PUBLIC_KEY,
# TIMEKEEPING_SERVICE_TOKEN and MONOLITH_REFERENCE_URL. None is baked in.

# Make sure RUBY_VERSION matches the ruby line in timekeeping/Gemfile
ARG RUBY_VERSION=4.0.1
FROM ruby:$RUBY_VERSION-slim AS base

# The service lives in /app/timekeeping, beside /app/gems/timekeeping_rules,
# so the Gemfile's "../gems/timekeeping_rules" path resolves as in the
# repository.
WORKDIR /app/timekeeping

RUN gem update --system --no-document && \
    gem install -N bundler

# libpq5 is the runtime library the pg gem links against.
RUN apt-get update -qq && \
    apt-get install --no-install-recommends -y libpq5 && \
    rm -rf /var/lib/apt/lists /var/cache/apt/archives

ENV BUNDLE_DEPLOYMENT="1" \
    BUNDLE_PATH="/usr/local/bundle" \
    BUNDLE_WITHOUT="development:test" \
    RAILS_ENV="production"


# Throw-away stage that compiles the gems' native extensions
FROM base AS gems

RUN apt-get update -qq && \
    apt-get install --no-install-recommends -y build-essential git libffi-dev libpq-dev libyaml-dev pkg-config && \
    rm -rf /var/lib/apt/lists /var/cache/apt/archives

COPY gems/timekeeping_rules /app/gems/timekeeping_rules
COPY timekeeping/Gemfile timekeeping/Gemfile.lock ./
RUN bundle install --jobs 4 --retry 3 && \
    rm -rf ~/.bundle/ /root/.cache/gem "${BUNDLE_PATH}"/ruby/*/cache "${BUNDLE_PATH}"/ruby/*/bundler/gems/*/.git


# Final stage: the gems and the application code, without build tools
FROM base

COPY --from=gems "${BUNDLE_PATH}" "${BUNDLE_PATH}"
COPY gems/timekeeping_rules /app/gems/timekeeping_rules
COPY timekeeping ./

# Run as a non-root user that owns only the directories Rails writes to.
RUN mkdir -p log tmp/pids && \
    groupadd --system --gid 1000 timekeeping && \
    useradd timekeeping --uid 1000 --gid 1000 --create-home --shell /bin/bash && \
    chown -R 1000:1000 log tmp
USER 1000:1000

EXPOSE 3000
CMD ["bin/rails", "server", "-b", "0.0.0.0", "-p", "3000"]
