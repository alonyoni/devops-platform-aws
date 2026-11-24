'use strict';

const request = require('supertest');
const { app, server } = require('./index');

afterAll((done) => {
  server.close(done);
});

describe('Health endpoints', () => {
  test('GET /health returns 200 and healthy status', async () => {
    const res = await request(app).get('/health');
    expect(res.status).toBe(200);
    expect(res.body.status).toBe('healthy');
    expect(res.body.timestamp).toBeDefined();
    expect(typeof res.body.uptime).toBe('number');
  });

  test('GET /ready returns 200 and ready status', async () => {
    const res = await request(app).get('/ready');
    expect(res.status).toBe(200);
    expect(res.body.status).toBe('ready');
  });
});

describe('Metrics endpoint', () => {
  test('GET /metrics returns 200 with prometheus content type', async () => {
    const res = await request(app).get('/metrics');
    expect(res.status).toBe(200);
    expect(res.headers['content-type']).toMatch(/text\/plain/);
  });

  test('/metrics response contains default Node.js metrics', async () => {
    const res = await request(app).get('/metrics');
    expect(res.text).toContain('nodejs_version_info');
    expect(res.text).toContain('http_requests_total');
  });
});

describe('Info endpoint', () => {
  test('GET /info returns application metadata', async () => {
    const res = await request(app).get('/info');
    expect(res.status).toBe(200);
    expect(res.body.name).toBeDefined();
    expect(res.body.version).toBeDefined();
    expect(res.body.environment).toBeDefined();
  });
});

describe('API endpoints', () => {
  test('GET /api/v1/items returns item list', async () => {
    const res = await request(app).get('/api/v1/items');
    expect(res.status).toBe(200);
    expect(Array.isArray(res.body.items)).toBe(true);
    expect(res.body.items.length).toBeGreaterThan(0);
    expect(res.body.total).toBe(res.body.items.length);
  });

  test('GET /api/v1/items/:id returns a single item', async () => {
    const res = await request(app).get('/api/v1/items/1');
    expect(res.status).toBe(200);
    expect(res.body.id).toBe(1);
    expect(res.body.name).toBeDefined();
  });

  test('GET /api/v1/items/:id returns 404 for missing item', async () => {
    const res = await request(app).get('/api/v1/items/999');
    expect(res.status).toBe(404);
    expect(res.body.error).toBeDefined();
  });

  test('GET /api/v1/items/:id returns 404 for non-numeric id', async () => {
    const res = await request(app).get('/api/v1/items/abc');
    expect(res.status).toBe(404);
  });
});

describe('Root route', () => {
  test('GET / returns welcome message with endpoints list', async () => {
    const res = await request(app).get('/');
    expect(res.status).toBe(200);
    expect(res.body.message).toContain('Welcome');
    expect(Array.isArray(res.body.endpoints)).toBe(true);
  });
});

describe('404 handler', () => {
  test('Unknown routes return 404', async () => {
    const res = await request(app).get('/this-does-not-exist');
    expect(res.status).toBe(404);
    expect(res.body.error).toBe('Not found');
  });
});
