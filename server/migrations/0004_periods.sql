-- Targets over a month, a year, or several weeks, months or years: `monthly`
-- and `yearly` schedules, and `every` periods of the schedule's kind counted
-- as one (every 2 weeks, every 3 months). And `interval`: due again `every`
-- days after it was last done.
--
-- The schedule and goal checks change, which SQLite only allows by rebuilding
-- the table. Dropping `habits` deletes its entries and applied operations
-- with it, so those are set aside first and put back after.

CREATE TABLE habits_new (
  id              BLOB PRIMARY KEY NOT NULL,
  user_id         BLOB NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  name            TEXT NOT NULL CHECK (length(name) BETWEEN 1 AND 100),
  description     TEXT NOT NULL DEFAULT '',
  kind            TEXT NOT NULL CHECK (kind IN ('boolean', 'counter')),
  schedule        TEXT NOT NULL
                  CHECK (schedule IN ('daily', 'weekdays', 'weekly', 'monthly', 'yearly',
                                      'interval')),
  every           INTEGER NOT NULL DEFAULT 1     -- a target's periods counted as one, or an
                                                 -- interval's days; 1 otherwise
                  CHECK (every >= 1
                         AND (every = 1
                              OR schedule IN ('weekly', 'monthly', 'yearly', 'interval'))),
  weekdays        INTEGER                        -- bitmask, bit 0 = Monday ... bit 6 = Sunday
                  CHECK ((schedule = 'weekdays') = (weekdays IS NOT NULL)
                         AND (weekdays IS NULL OR weekdays BETWEEN 1 AND 127)),
  goal            INTEGER NOT NULL DEFAULT 1
                  CHECK (goal >= 1 AND (kind = 'counter'
                         OR (schedule IN ('weekly', 'monthly', 'yearly') AND goal <= 366 * every)
                         OR goal = 1)),
  position        INTEGER NOT NULL DEFAULT 0,
  archived        INTEGER NOT NULL DEFAULT 0 CHECK (archived IN (0, 1)),
  webhook_secret  TEXT UNIQUE,                   -- NULL = webhook disabled
  created_at      INTEGER NOT NULL,
  updated_at      INTEGER NOT NULL,
  unit            TEXT NOT NULL DEFAULT '',      -- "pages", "ml"; counters only
  color           TEXT NOT NULL DEFAULT 'ink',
  category_id     BLOB REFERENCES categories(id) ON DELETE SET NULL,
  reminders       TEXT NOT NULL DEFAULT '[]'     -- JSON: [{ "time": "HH:MM", "days": [1..7] | null }]
) STRICT;

INSERT INTO habits_new (id, user_id, name, description, kind, schedule, weekdays, goal, position,
                        archived, webhook_secret, created_at, updated_at, unit, color,
                        category_id, reminders)
SELECT id, user_id, name, description, kind, schedule, weekdays, goal, position,
       archived, webhook_secret, created_at, updated_at, unit, color, category_id, reminders
FROM habits;

CREATE TABLE entries_kept AS SELECT * FROM entries;
CREATE TABLE applied_ops_kept AS SELECT * FROM applied_ops;

DROP TABLE habits;
ALTER TABLE habits_new RENAME TO habits;
CREATE INDEX habits_by_user ON habits (user_id, archived, position);

INSERT INTO entries (habit_id, date, value, updated_at, skipped, note)
SELECT habit_id, date, value, updated_at, skipped, note FROM entries_kept;
INSERT INTO applied_ops (op_id, habit_id, created_at)
SELECT op_id, habit_id, created_at FROM applied_ops_kept;

DROP TABLE entries_kept;
DROP TABLE applied_ops_kept;
