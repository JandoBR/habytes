CREATE TABLE users (
  id          BLOB PRIMARY KEY NOT NULL,
  oidc_sub    TEXT NOT NULL UNIQUE,
  username    TEXT NOT NULL,
  timezone    TEXT NOT NULL DEFAULT 'UTC',      -- IANA name
  week_start  INTEGER NOT NULL DEFAULT 1        -- 1 = Monday ... 7 = Sunday
              CHECK (week_start BETWEEN 1 AND 7),
  created_at  INTEGER NOT NULL
) STRICT;

CREATE TABLE habits (
  id              BLOB PRIMARY KEY NOT NULL,
  user_id         BLOB NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  name            TEXT NOT NULL CHECK (length(name) BETWEEN 1 AND 100),
  description     TEXT NOT NULL DEFAULT '',
  kind            TEXT NOT NULL CHECK (kind IN ('boolean', 'counter')),
  schedule        TEXT NOT NULL CHECK (schedule IN ('daily', 'weekdays', 'weekly')),
  weekdays        INTEGER                        -- bitmask, bit 0 = Monday ... bit 6 = Sunday
                  CHECK ((schedule = 'weekdays') = (weekdays IS NOT NULL)
                         AND (weekdays IS NULL OR weekdays BETWEEN 1 AND 127)),
  goal            INTEGER NOT NULL DEFAULT 1
                  CHECK (goal >= 1 AND (kind = 'counter'
                         OR (schedule = 'weekly' AND goal <= 7)
                         OR goal = 1)),
  position        INTEGER NOT NULL DEFAULT 0,
  archived        INTEGER NOT NULL DEFAULT 0 CHECK (archived IN (0, 1)),
  webhook_secret  TEXT UNIQUE,                   -- NULL = webhook disabled
  created_at      INTEGER NOT NULL,
  updated_at      INTEGER NOT NULL
) STRICT;
CREATE INDEX habits_by_user ON habits (user_id, archived, position);

CREATE TABLE entries (
  habit_id    BLOB NOT NULL REFERENCES habits(id) ON DELETE CASCADE,
  date        TEXT NOT NULL,
  value       INTEGER NOT NULL CHECK (value >= 0),
  updated_at  INTEGER NOT NULL,
  PRIMARY KEY (habit_id, date)
) STRICT, WITHOUT ROWID;

CREATE TABLE applied_ops (
  op_id       BLOB PRIMARY KEY NOT NULL,
  habit_id    BLOB NOT NULL REFERENCES habits(id) ON DELETE CASCADE,
  created_at  INTEGER NOT NULL
) STRICT, WITHOUT ROWID;

CREATE TABLE tokens (
  id            BLOB PRIMARY KEY NOT NULL,
  user_id       BLOB NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  kind          TEXT NOT NULL CHECK (kind IN ('session', 'device', 'api')),
  name          TEXT NOT NULL,
  token_hash    BLOB NOT NULL UNIQUE,            -- SHA-256 of the token
  created_at    INTEGER NOT NULL,
  last_used_at  INTEGER,
  expires_at    INTEGER                          -- NULL = never
) STRICT;
CREATE INDEX tokens_by_user ON tokens (user_id);

CREATE TABLE login_flows (
  state           TEXT PRIMARY KEY NOT NULL,
  nonce           TEXT NOT NULL,
  pkce_verifier   TEXT NOT NULL,                 -- for the OIDC provider
  client          TEXT NOT NULL CHECK (client IN ('web', 'app')),
  redirect_path   TEXT,                          -- web only
  app_challenge   TEXT,                          -- app only, S256
  app_code_hash   BLOB UNIQUE,                   -- app only, set after callback
  user_id         BLOB REFERENCES users(id) ON DELETE CASCADE,
  expires_at      INTEGER NOT NULL
) STRICT;
