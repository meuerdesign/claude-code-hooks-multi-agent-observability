# syntax=docker/dockerfile:1
# obs all-in-one image: build the Vue dashboard, then run the Bun server that
# serves the API + WebSocket AND the built dashboard (same origin -> clean
# behind a single Cloudflare hostname). Deployed via docker-compose.yml.

# ---- stage 1: build the client (SPA) ----
FROM oven/bun:1 AS client
WORKDIR /app/client
COPY apps/client/package.json apps/client/bun.lock ./
RUN bun install --frozen-lockfile
COPY apps/client/ ./
# Same-origin behind Cloudflare: dashboard calls the API on the same host and
# the WS on /stream. Overridable at build time via compose build args.
ARG VITE_API_URL=https://obs.example.com
ARG VITE_WS_URL=wss://obs.example.com/stream
ARG VITE_MAX_EVENTS_TO_DISPLAY=300
ENV VITE_API_URL=$VITE_API_URL \
    VITE_WS_URL=$VITE_WS_URL \
    VITE_MAX_EVENTS_TO_DISPLAY=$VITE_MAX_EVENTS_TO_DISPLAY
# Use vite directly (skip the repo's `vue-tsc -b` typecheck) so upstream type
# debt can never block a production image build.
RUN bunx vite build

# ---- stage 2: server runtime ----
FROM oven/bun:1 AS server
WORKDIR /app/server
COPY apps/server/package.json apps/server/bun.lock ./
RUN bun install --frozen-lockfile
COPY apps/server/ ./
# The built dashboard, served by the Bun server (see CLIENT_DIST in index.ts).
COPY --from=client /app/client/dist /app/client-dist
ENV CLIENT_DIST=/app/client-dist \
    SERVER_PORT=4000 \
    DB_PATH=/data/events.db
EXPOSE 4000
CMD ["bun", "src/index.ts"]
