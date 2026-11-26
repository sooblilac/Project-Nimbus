CREATE TABLE IF NOT EXISTS towns (
  town_code TEXT PRIMARY KEY,
  update_json TEXT,
  updated_at TEXT
);

CREATE TABLE IF NOT EXISTS lgu_users (
  username TEXT PRIMARY KEY,
  password_hash TEXT NOT NULL,
  town_codes TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS pagasa_state (
  id INTEGER PRIMARY KEY CHECK (id = 1),
  state_json TEXT NOT NULL,
  updated_at TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS sessions (
  access_token TEXT PRIMARY KEY,
  username TEXT NOT NULL,
  expires_at TEXT NOT NULL
);
