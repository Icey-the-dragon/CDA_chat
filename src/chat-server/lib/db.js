import mysql from 'mysql2/promise';
import { config } from './config.js';

// Fallback schema creation for local development and for databases that were
// not created by the Kubernetes init script (kubernetes/cluster-manifests.yaml,
// ConfigMap `mariadb-init`). Keep both definitions in sync: the ConfigMap runs
// only on MariaDB's first boot with an empty data directory.
const SCHEMA = [
  `CREATE TABLE IF NOT EXISTS rooms (
    id INT UNSIGNED NOT NULL AUTO_INCREMENT,
    name VARCHAR(64) NOT NULL,
    created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (id),
    UNIQUE KEY uq_rooms_name (name)
  ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci`,

  `CREATE TABLE IF NOT EXISTS messages (
    id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    room_id INT UNSIGNED NOT NULL,
    username VARCHAR(64) NOT NULL,
    body TEXT NOT NULL,
    created_at TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
    PRIMARY KEY (id),
    KEY idx_messages_room_id (room_id, id),
    CONSTRAINT fk_messages_room FOREIGN KEY (room_id) REFERENCES rooms (id) ON DELETE CASCADE
  ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci`,
];

let pool = null;
let schemaReady = false;
let lastError = null;
let stopped = false;

export function getPool() {
  if (!pool) {
    pool = mysql.createPool({
      ...config.db,
      waitForConnections: true,
      queueLimit: 0,
      charset: 'utf8mb4',
      timezone: 'Z',
      enableKeepAlive: true,
      keepAliveInitialDelay: 10_000,
      decimalNumbers: true,
    });

    // Keep timestamps consistent no matter what timezone the MariaDB host uses.
    pool.on('connection', (connection) => {
      connection.query("SET time_zone = '+00:00'");
    });
  }

  return pool;
}

async function migrate() {
  const connection = await getPool().getConnection();
  try {
    for (const statement of SCHEMA) {
      await connection.query(statement);
    }
    await connection.query(
      "INSERT INTO rooms (name) VALUES ('general') ON DUPLICATE KEY UPDATE name = name",
    );
    schemaReady = true;
    lastError = null;
  } finally {
    connection.release();
  }
}

function delay(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

/**
 * Creates the schema and keeps retrying until MariaDB is reachable.
 * The HTTP server starts listening before this resolves, so the API can
 * report a degraded state while the database is still booting.
 */
export async function startDatabase() {
  let attempt = 0;

  while (!stopped) {
    try {
      await migrate();
      if (stopped) return;
      console.log(`[db] connected to ${config.db.user}@${config.db.host}:${config.db.port}/${config.db.database}`);
      return;
    } catch (error) {
      lastError = error;
      attempt += 1;

      if (attempt === 1 || attempt % 10 === 0) {
        console.error(`[db] connection attempt ${attempt} failed: ${error.message} (retrying every ${config.dbRetryMs}ms)`);
      }

      await delay(config.dbRetryMs);
    }
  }
}

export async function pingDatabase() {
  if (stopped) return false;

  try {
    await getPool().query('SELECT 1');
    lastError = null;
    return true;
  } catch (error) {
    lastError = error;
    return false;
  }
}

export function dbHealth() {
  return {
    ready: schemaReady,
    error: lastError ? lastError.message : null,
  };
}

export async function stopDatabase() {
  stopped = true;
  const current = pool;
  pool = null;

  if (current) {
    await current.end().catch(() => {});
  }
}
