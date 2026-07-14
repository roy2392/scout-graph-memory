# Cloud dream image — runs the agent-memory consolidation engine on a schedule.
# The memory.db + inbox/outbox live on a mounted Azure Files share (/data).
# The MiniLM embedding model is baked into the image so runtime needs no network.

FROM node:20-bookworm-slim

WORKDIR /app

# Toolchain for building native deps (better-sqlite3, sqlite-vec) if a prebuilt
# binary is unavailable for the platform. Removed after install to keep image small.
RUN apt-get update \
 && apt-get install -y --no-install-recommends python3 make g++ ca-certificates \
 && rm -rf /var/lib/apt/lists/*

# Install engine dependencies first (better layer caching).
COPY package.json ./
RUN npm install --omit=dev --no-audit --no-fund

# Engine source.
COPY config.js setup.js ./
COPY lib ./lib
COPY viz ./viz
COPY azure/entrypoint.sh /app/entrypoint.sh
RUN chmod +x /app/entrypoint.sh

# Bake the embedding model into the image (one-time download at build).
ENV MEMORY_MODEL_CACHE=/app/model-cache
RUN node -e "require('./lib/embed').embedOne('warm').then(v=>{console.log('model warmed',v.length);process.exit(0)}).catch(e=>{console.error(e);process.exit(1)})"

# Runtime data dir is the mounted Azure Files share.
ENV AGENT_MEMORY_DIR=/data \
    MEMORY_MODEL_CACHE=/app/model-cache \
    NODE_ENV=production

ENTRYPOINT ["/app/entrypoint.sh"]
