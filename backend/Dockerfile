FROM rust:1.96-slim-bookworm AS builder
WORKDIR /build

COPY Cargo.toml Cargo.lock ./
COPY src ./src
COPY tests ./tests
RUN cargo build --release --locked

FROM debian:bookworm-slim

RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates curl ffmpeg python3 \
    && curl -fsSL https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp -o /usr/local/bin/yt-dlp \
    && chmod 0755 /usr/local/bin/yt-dlp \
    && rm -rf /var/lib/apt/lists/*

COPY --from=builder /build/target/release/pullbox-backend /usr/local/bin/pullbox-backend
RUN install -d -o nobody -g nogroup -m 0700 /data

ENV PULLBOX_BIND=0.0.0.0:8787
ENV RUST_LOG=info
EXPOSE 8787

HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
  CMD curl -fsS http://127.0.0.1:8787/health || exit 1

USER nobody
ENTRYPOINT ["/usr/local/bin/pullbox-backend"]
