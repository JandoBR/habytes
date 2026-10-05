-- Categories, per-habit unit, colour and reminder, and skipped days and notes.

CREATE TABLE categories (
  id          BLOB PRIMARY KEY NOT NULL,
  user_id     BLOB NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  name        TEXT NOT NULL CHECK (length(name) BETWEEN 1 AND 60),
  position    INTEGER NOT NULL DEFAULT 0,
  collapsed   INTEGER NOT NULL DEFAULT 0 CHECK (collapsed IN (0, 1)),  -- hidden on Today and the widget
  created_at  INTEGER NOT NULL
) STRICT;
CREATE INDEX categories_by_user ON categories (user_id, position);

ALTER TABLE habits ADD COLUMN unit TEXT NOT NULL DEFAULT '';             -- "pages", "ml"; counters only
ALTER TABLE habits ADD COLUMN color TEXT NOT NULL DEFAULT 'ink';
ALTER TABLE habits ADD COLUMN category_id BLOB REFERENCES categories(id) ON DELETE SET NULL;
ALTER TABLE habits ADD COLUMN reminder_time TEXT;                        -- "HH:MM" local time, NULL = none

ALTER TABLE entries ADD COLUMN skipped INTEGER NOT NULL DEFAULT 0;       -- the day is excused
ALTER TABLE entries ADD COLUMN note TEXT NOT NULL DEFAULT '';
