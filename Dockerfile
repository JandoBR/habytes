# habitd with the web app embedded.
#
# The web app is not built here: run `flutter build web --release` in app/
# first (scripts/publish-image does both), so the image does not need Flutter.

# The official Rust image, from Google's Docker Hub mirror: Docker Hub rate-limits
# anonymous pulls and public.ecr.aws throttles hard.
FROM mirror.gcr.io/library/rust:1-slim AS build
WORKDIR /src
COPY server server
COPY app/build/web app/build/web
RUN test -f app/build/web/index.html \
    || (echo "app/build/web is empty: run 'flutter build web --release' in app/ first" >&2; exit 1)
RUN cd server && cargo build --release --locked

FROM gcr.io/distroless/cc-debian12
COPY --from=build /src/server/target/release/habitd /habitd
# Everything else comes from HABITD_* variables; see server/config.example.toml.
ENV HABITD_DATABASE_PATH=/data/habits.db \
    HABITD_BIND_ADDRESS=0.0.0.0:8080
VOLUME /data
EXPOSE 8080
ENTRYPOINT ["/habitd"]
