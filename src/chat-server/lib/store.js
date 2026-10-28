import { getPool } from './db.js';

const MESSAGE_COLUMNS = `m.id,
  r.name AS room,
  m.username,
  COALESCE(p.avatar, '') AS avatar,
  COALESCE(p.color, '') AS avatarColor,
  m.body,
  m.created_at AS createdAt`;

export async function ensureRoom(name) {
  const [result] = await getPool().query(
    'INSERT INTO rooms (name) VALUES (?) ON DUPLICATE KEY UPDATE id = LAST_INSERT_ID(id)',
    [name],
  );

  return Number(result.insertId);
}

export async function createRoom(name) {
  const id = await ensureRoom(name);
  const [rows] = await getPool().query(
    'SELECT id, name, created_at AS createdAt FROM rooms WHERE id = ?',
    [id],
  );

  return rows[0];
}

export async function listRooms() {
  const [rows] = await getPool().query(
    `SELECT r.name,
            COUNT(m.id) AS messageCount,
            MAX(m.created_at) AS lastActivity
       FROM rooms r
       LEFT JOIN messages m ON m.room_id = r.id
      GROUP BY r.id, r.name
      ORDER BY (r.name = 'general') DESC, lastActivity DESC, r.name ASC`,
  );

  return rows.map((row) => ({
    name: row.name,
    messageCount: Number(row.messageCount),
    lastActivity: row.lastActivity,
  }));
}

export async function listMessages(room, { limit, before = null }) {
  const params = [room];
  let sql = `SELECT ${MESSAGE_COLUMNS}
               FROM messages m
               JOIN rooms r ON r.id = m.room_id
               LEFT JOIN profiles p ON p.username = m.username
              WHERE r.name = ?`;

  if (before) {
    sql += ' AND m.id < ?';
    params.push(before);
  }

  sql += ' ORDER BY m.id DESC LIMIT ?';
  params.push(limit);

  const [rows] = await getPool().query(sql, params);
  return rows.reverse();
}

export async function createMessage({ room, username, body }) {
  const roomId = await ensureRoom(room);
  const [result] = await getPool().query(
    'INSERT INTO messages (room_id, username, body) VALUES (?, ?, ?)',
    [roomId, username, body],
  );

  const [rows] = await getPool().query(
    `SELECT ${MESSAGE_COLUMNS}
       FROM messages m
       JOIN rooms r ON r.id = m.room_id
       LEFT JOIN profiles p ON p.username = m.username
      WHERE m.id = ?`,
    [result.insertId],
  );

  return rows[0];
}

export async function getProfile(username) {
  const [rows] = await getPool().query(
    'SELECT username, avatar, color FROM profiles WHERE username = ?',
    [username],
  );

  return rows[0] ?? null;
}

export async function saveProfile({ username, avatar, color }) {
  await getPool().query(
    `INSERT INTO profiles (username, avatar, color)
     VALUES (?, ?, ?)
     ON DUPLICATE KEY UPDATE avatar = VALUES(avatar), color = VALUES(color)`,
    [username, avatar, color],
  );

  return { username, avatar, color };
}
