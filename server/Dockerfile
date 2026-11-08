# Build context is the repository root (the server depends on
# packages/echopin_protocol):  docker build -f server/Dockerfile .
FROM dart:3.12 AS build
WORKDIR /src
COPY packages/echopin_protocol packages/echopin_protocol
COPY server/pubspec.yaml server/pubspec.lock* server/
RUN cd server && dart pub get
COPY server server
RUN mkdir -p /out && cd server && dart pub get --offline \
 && dart compile exe bin/server.dart -o /out/echopin-server \
 && dart compile exe bin/echopin_admin.dart -o /out/echopin_admin

# The PostgreSQL image gives us pg_dump / pg_restore that match the
# database major version, which backups require.
FROM postgres:17-bookworm
RUN useradd --system --uid 10001 --home /data echopin \
 && mkdir -p /data/keys /data/backups && chown -R echopin /data
COPY --from=build /out/echopin-server /out/echopin_admin /usr/local/bin/
USER echopin
WORKDIR /data
# Keys come from ECHOPIN_KEYS (hosted) or KEYS_DIR on a mounted volume
# (docker-compose). Deliberately no default: a container must never create
# keys on its throwaway disk.
ENV PORT=8080
EXPOSE 8080
HEALTHCHECK --interval=30s --timeout=5s CMD ["bash", "-c", "exec 3<>/dev/tcp/127.0.0.1/${PORT:-8080}"]
ENTRYPOINT ["/usr/local/bin/echopin-server"]
