/**
 * Local development database launcher (embedded PostgreSQL).
 *
 * Provides a zero-install Postgres for development when Docker/Postgres
 * are not available on the machine. Data is persisted under `.local/pg`.
 *
 * Usage:
 *   pnpm db:dev:start   — boot the database (stays in the foreground)
 *   pnpm db:dev:stop    — stop the database (kills via postmaster.pid)
 *
 * The default connection matches `.env`:
 *   postgresql://covia:covia_dev_password@localhost:5433/covia
 */

import { spawnSync } from 'node:child_process';
import fs from 'node:fs';
import path from 'node:path';
import EmbeddedPostgres from 'embedded-postgres';

const DB_HOST = 'localhost';
const DB_PORT = Number(process.env.DB_PORT ?? 5433);
const DB_USER = process.env.DB_USER ?? 'covia';
const DB_PASSWORD = process.env.DB_PASSWORD ?? 'covia_dev_password';
const DB_NAME = process.env.DB_NAME ?? 'covia';
const CLUSTER_DIR = path.resolve('.local/pg');

const pg = new EmbeddedPostgres({
  databaseDir: CLUSTER_DIR,
  user: DB_USER,
  password: DB_PASSWORD,
  port: DB_PORT,
  persistent: true,
});

const command = process.argv[2] ?? 'start';

async function start() {
  if (!fs.existsSync(path.join(CLUSTER_DIR, 'PG_VERSION'))) {
    await pg.initialise();
  }
  await pg.start();
  try {
    await pg.createDatabase(DB_NAME);
  } catch (error) {
    // Database already exists — that's fine.
    if (!(error instanceof Error) || !error.message.includes('already exists')) {
      throw error;
    }
  }
  console.log(
    `[dev-db] PostgreSQL running: ${DB_HOST}:${DB_PORT}/${DB_NAME} (user: ${DB_USER})`,
  );
  console.log('[dev-db] Press Ctrl+C to stop.');
  // Keep the process alive: the library shuts the cluster down on exit.
  await new Promise(() => {});
}

function stop() {
  const pidFile = path.join(CLUSTER_DIR, 'postmaster.pid');
  if (!fs.existsSync(pidFile)) {
    console.log('[dev-db] PostgreSQL is not running.');
    return;
  }
  const pid = fs.readFileSync(pidFile, 'utf8').split(/\r?\n/)[0].trim();
  const result = spawnSync('taskkill', ['/pid', pid, '/f', '/t'], {
    stdio: 'inherit',
    shell: false,
  });
  if (result.status === 0) {
    console.log(`[dev-db] PostgreSQL (pid ${pid}) stopped.`);
  } else {
    console.error('[dev-db] Failed to stop PostgreSQL.');
    process.exitCode = 1;
  }
}

if (command === 'stop') {
  stop();
} else {
  void start();
}
