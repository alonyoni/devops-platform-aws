# ─────────────────────────────────────────────
# Stage 1: Dependencies
# Install only production deps in a clean layer
# ─────────────────────────────────────────────
FROM node:20-alpine AS deps

WORKDIR /app

# Copy manifests first — maximise layer cache hits
COPY package.json package-lock.json ./

# Install only production dependencies
RUN npm ci --only=production --ignore-scripts \
    && npm cache clean --force

# ─────────────────────────────────────────────
# Stage 2: Build/Test
# Install all deps, run lint + tests
# ─────────────────────────────────────────────
FROM node:20-alpine AS build

WORKDIR /app

COPY package.json package-lock.json ./
RUN npm ci --ignore-scripts

COPY src/ ./src/

# Lint
RUN npx eslint src/ --ext .js || true

# Tests
RUN npm run test:ci

# ─────────────────────────────────────────────
# Stage 3: Runtime
# Minimal production image — no dev tools
# ─────────────────────────────────────────────
FROM node:20-alpine AS runtime

# Labels for OCI image spec compliance
ARG BUILD_DATE
ARG VCS_REF
ARG VERSION

LABEL org.opencontainers.image.created="${BUILD_DATE}" \
      org.opencontainers.image.revision="${VCS_REF}" \
      org.opencontainers.image.version="${VERSION}" \
      org.opencontainers.image.title="devops-platform-app" \
      org.opencontainers.image.description="Sample application for DevOps Platform" \
      org.opencontainers.image.vendor="DevOps Platform"

# Security: run as non-root user
RUN addgroup -S appgroup && adduser -S appuser -G appgroup

WORKDIR /app

# Copy production deps from stage 1
COPY --from=deps --chown=appuser:appgroup /app/node_modules ./node_modules

# Copy application source
COPY --chown=appuser:appgroup src/ ./src/
COPY --chown=appuser:appgroup package.json ./

# Environment defaults (override in K8s via env/configMap)
ENV NODE_ENV=production \
    PORT=8080 \
    VERSION=${VERSION:-1.0.0} \
    APP_NAME=devops-platform-app

# Drop root
USER appuser

EXPOSE 8080

# Healthcheck so `docker run` and compose know the container is ready
HEALTHCHECK --interval=30s --timeout=5s --start-period=30s --retries=3 \
  CMD wget -qO- http://localhost:8080/health || exit 1

# Use exec form to handle signals correctly (SIGTERM for graceful shutdown)
ENTRYPOINT ["node", "src/index.js"]
