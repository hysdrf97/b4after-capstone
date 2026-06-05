import http from 'k6/http';
import { check, sleep } from 'k6';
import { Trend, Counter, Rate } from 'k6/metrics';
import { randomIntBetween } from 'https://jslib.k6.io/k6-utils/1.4.0/index.js';

const getUserDuration    = new Trend('get_user_duration',        true);
const getTxDuration      = new Trend('get_transaction_duration', true);
const createTxDuration   = new Trend('create_transaction_duration', true);

const getUserCount       = new Counter('get_user_requests');
const getTxCount         = new Counter('get_transaction_requests');
const createTxCount      = new Counter('create_transaction_requests');

const getUserFailed      = new Rate('get_user_failed');
const getTxFailed        = new Rate('get_transaction_failed');
const createTxFailed     = new Rate('create_transaction_failed');

export const options = {
    summaryTrendStats: ['avg', 'min', 'med', 'max', 'p(50)', 'p(90)', 'p(95)', 'p(99)'],

    // Sama dengan baseline — apple-to-apple comparison
    stages: [
      { duration: '30s', target: 10 },
      { duration: '1m',  target: 50 },
      { duration: '2m',  target: 50 },
      { duration: '30s', target: 0  },
    ],
    thresholds: {
      http_req_duration: ['p(95)<500'],
      http_req_failed:   ['rate<0.01'],

      get_user_duration:           ['p(95)<300', 'p(99)<500'],
      get_transaction_duration:    ['p(95)<300', 'p(99)<500'],
      create_transaction_duration: ['p(95)<800', 'p(99)<1000'],

      get_user_failed:           ['rate<0.01'],
      get_transaction_failed:    ['rate<0.01'],
      create_transaction_failed: ['rate<0.01'],
    },
};

const BASE_URL = 'http://localhost:8081';

export default function () {
  const rand = Math.random();

  if (rand < 0.4) {
    const userId = randomIntBetween(1, 1000);
    const res = http.get(`${BASE_URL}/users/${userId}`, {
      tags: { endpoint: 'get_user' },
    });

    getUserDuration.add(res.timings.duration);
    getUserCount.add(1);
    getUserFailed.add(res.status !== 200);
    check(res, { '[GET /users] status 200': (r) => r.status === 200 });

  } else if (rand < 0.8) {
    const txId = randomIntBetween(1, 50000);
    const res = http.get(`${BASE_URL}/transactions/${txId}`, {
      tags: { endpoint: 'get_transaction' },
    });

    getTxDuration.add(res.timings.duration);
    getTxCount.add(1);
    getTxFailed.add(res.status !== 200);
    check(res, { '[GET /transactions] status 200': (r) => r.status === 200 });

  } else {
    const payload = JSON.stringify({
      user_id: randomIntBetween(1, 1000),
      type:    Math.random() > 0.5 ? 'credit' : 'debit',
      amount:  randomIntBetween(10000, 5000000),
    });

    const res = http.post(`${BASE_URL}/transactions`, payload, {
      headers: { 'Content-Type': 'application/json' },
      tags:    { endpoint: 'create_transaction' },
    });

    createTxDuration.add(res.timings.duration);
    createTxCount.add(1);
    createTxFailed.add(res.status !== 201);
    check(res, { '[POST /transactions] status 201': (r) => r.status === 201 });
  }

  sleep(1);
}

export function handleSummary(data) {
  const metrics = data.metrics;

  const totalReqs    = metrics.http_reqs?.values?.count ?? 0;
  const getUserReqs  = metrics.get_user_requests?.values?.count ?? 0;
  const getTxReqs    = metrics.get_transaction_requests?.values?.count ?? 0;
  const createTxReqs = metrics.create_transaction_requests?.values?.count ?? 0;

  const pct = (n) => totalReqs > 0 ? ((n / totalReqs) * 100).toFixed(1) + '%' : '0%';

  const report = {
    generated_at: new Date().toISOString(),
    phase: "FASE 2 — With Cache (Redis) + Message Queue (RabbitMQ)",

    traffic_distribution: {
      "GET /users/:id       (read-heavy)":   { requests: getUserReqs,  percentage: pct(getUserReqs)  },
      "GET /transactions/:id (read-heavy)":  { requests: getTxReqs,    percentage: pct(getTxReqs)    },
      "POST /transactions    (write-heavy)": { requests: createTxReqs, percentage: pct(createTxReqs) },
    },

    global: {
      total_requests:   totalReqs,
      duration_seconds: 240,
      tps_avg:    (totalReqs / 240).toFixed(2),
      error_rate: (metrics.http_req_failed?.values?.rate * 100).toFixed(2) + '%',
      latency: {
        avg: metrics.http_req_duration?.values?.avg?.toFixed(2)       + 'ms',
        p50: metrics.http_req_duration?.values?.med?.toFixed(2)       + 'ms',
        p95: metrics.http_req_duration?.values?.['p(95)']?.toFixed(2) + 'ms',
        p99: metrics.http_req_duration?.values?.['p(99)']?.toFixed(2) + 'ms',
        max: metrics.http_req_duration?.values?.max?.toFixed(2)       + 'ms',
      },
    },

    per_endpoint: {
      "GET /users/:id": {
        requests:   getUserReqs,
        error_rate: (metrics.get_user_failed?.values?.rate * 100).toFixed(2) + '%',
        latency: {
          p50: metrics.get_user_duration?.values?.med?.toFixed(2)       + 'ms',
          p95: metrics.get_user_duration?.values?.['p(95)']?.toFixed(2) + 'ms',
          p99: metrics.get_user_duration?.values?.['p(99)']?.toFixed(2) + 'ms',
        },
      },
      "GET /transactions/:id": {
        requests:   getTxReqs,
        error_rate: (metrics.get_transaction_failed?.values?.rate * 100).toFixed(2) + '%',
        latency: {
          p50: metrics.get_transaction_duration?.values?.med?.toFixed(2)       + 'ms',
          p95: metrics.get_transaction_duration?.values?.['p(95)']?.toFixed(2) + 'ms',
          p99: metrics.get_transaction_duration?.values?.['p(99)']?.toFixed(2) + 'ms',
        },
      },
      "POST /transactions": {
        requests:   createTxReqs,
        error_rate: (metrics.create_transaction_failed?.values?.rate * 100).toFixed(2) + '%',
        latency: {
          p50: metrics.create_transaction_duration?.values?.med?.toFixed(2)       + 'ms',
          p95: metrics.create_transaction_duration?.values?.['p(95)']?.toFixed(2) + 'ms',
          p99: metrics.create_transaction_duration?.values?.['p(99)']?.toFixed(2) + 'ms',
        },
      },
    },
  };

  const json = JSON.stringify(report, null, 2);

  console.log('\n========== CACHE + QUEUE REPORT ==========');
  console.log(json);
  console.log('==========================================\n');

  return {
    'results/cache_queue_report.json': json,
    stdout: '\n✅ Report saved to results/cache_queue_report.json\n',
  };
}
