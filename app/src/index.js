'use strict';

const express = require('express');
const promClient = require('prom-client');

// -------------------------------------------------------------------
// Prometheus metrics setup
// -------------------------------------------------------------------
const register = new promClient.Registry();
promClient.collectDefaultMetrics({ register });

const httpRequestsTotal = new promClient.Counter({
  name: 'http_requests_total',
  help: 'Total HTTP requests',
  labelNames: ['method', 'route', 'status'],
  registers: [register],
});

const httpRequestDuration = new promClient.Histogram({
  name: 'http_request_duration_seconds',
  help: 'HTTP request duration in seconds',
  labelNames: ['method', 'route', 'status'],
  buckets: [0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1, 2.5, 5],
  registers: [register],
});

const activeRequests = new promClient.Gauge({
  name: 'http_active_requests',
  help: 'Number of active HTTP requests',
  registers: [register],
});

// -------------------------------------------------------------------
// Application setup
// -------------------------------------------------------------------
const app = express();
const PORT = process.env.PORT || 8080;
const VERSION = process.env.VERSION || '1.0.0';
const ENVIRONMENT = process.env.NODE_ENV || 'development';
const APP_NAME = process.env.APP_NAME || 'devops-platform-app';

app.use(express.json());

// -------------------------------------------------------------------
// Middleware: instrument all requests
// -------------------------------------------------------------------
app.use((req, res, next) => {
  const start = Date.now();
  activeRequests.inc();

  res.on('finish', () => {
    const duration = (Date.now() - start) / 1000;
    const route = req.route ? req.route.path : req.path;

    httpRequestsTotal.inc({
      method: req.method,
      route,
      status: res.statusCode,
    });

    httpRequestDuration.observe(
      { method: req.method, route, status: res.statusCode },
      duration
    );

    activeRequests.dec();
  });

  next();
});

// -------------------------------------------------------------------
// Routes
// -------------------------------------------------------------------

// Health check — used by Kubernetes liveness probe
app.get('/health', (req, res) => {
  res.json({
    status: 'healthy',
    timestamp: new Date().toISOString(),
    uptime: process.uptime(),
  });
});

// Readiness check — used by Kubernetes readiness probe
app.get('/ready', (req, res) => {
  // Add real dependency checks here (DB, cache, etc.)
  res.json({
    status: 'ready',
    timestamp: new Date().toISOString(),
  });
});

// Prometheus metrics endpoint
app.get('/metrics', async (req, res) => {
  res.set('Content-Type', register.contentType);
  res.end(await register.metrics());
});

// Application info
app.get('/info', (req, res) => {
  res.json({
    name: APP_NAME,
    version: VERSION,
    environment: ENVIRONMENT,
    nodeVersion: process.version,
    timestamp: new Date().toISOString(),
  });
});

// Main API
app.get('/api/v1/items', (req, res) => {
  const items = [
    { id: 1, name: 'Item Alpha', description: 'First item', created: '2024-01-01' },
    { id: 2, name: 'Item Beta',  description: 'Second item', created: '2024-01-02' },
    { id: 3, name: 'Item Gamma', description: 'Third item', created: '2024-01-03' },
  ];
  res.json({ items, total: items.length });
});

app.get('/api/v1/items/:id', (req, res) => {
  const id = parseInt(req.params.id, 10);
  if (isNaN(id) || id < 1 || id > 3) {
    return res.status(404).json({ error: 'Item not found', id: req.params.id });
  }
  res.json({ id, name: `Item ${id}`, description: `Description for item ${id}` });
});

// Root
app.get('/', (req, res) => {
  res.json({
    message: `Welcome to ${APP_NAME}`,
    version: VERSION,
    environment: ENVIRONMENT,
    endpoints: ['/health', '/ready', '/metrics', '/info', '/api/v1/items'],
  });
});

// 404 handler
app.use((req, res) => {
  httpRequestsTotal.inc({ method: req.method, route: 'unknown', status: 404 });
  res.status(404).json({ error: 'Not found', path: req.path });
});

// Error handler
app.use((err, req, res, _next) => {
  console.error('Unhandled error:', err);
  httpRequestsTotal.inc({ method: req.method, route: req.path, status: 500 });
  res.status(500).json({ error: 'Internal server error' });
});

// -------------------------------------------------------------------
// Start
// -------------------------------------------------------------------
const server = app.listen(PORT, () => {
  console.log(JSON.stringify({
    level: 'info',
    message: `${APP_NAME} v${VERSION} started`,
    port: PORT,
    environment: ENVIRONMENT,
    timestamp: new Date().toISOString(),
  }));
});

// Graceful shutdown — give Kubernetes time to drain connections
const shutdown = (signal) => {
  console.log(JSON.stringify({ level: 'info', message: `Received ${signal}, shutting down gracefully` }));
  server.close(() => {
    console.log(JSON.stringify({ level: 'info', message: 'HTTP server closed' }));
    process.exit(0);
  });

  // Force exit after 30s if graceful shutdown hangs
  setTimeout(() => {
    console.error('Forced shutdown after timeout');
    process.exit(1);
  }, 30000);
};

process.on('SIGTERM', () => shutdown('SIGTERM'));
process.on('SIGINT',  () => shutdown('SIGINT'));

module.exports = { app, server };
