-- The day a habit's schedule was set. Periods of several weeks are counted in
-- blocks from the week it is in, so that the first one is a whole one. Habits
-- from before have none and keep counting from a fixed week.

ALTER TABLE habits ADD COLUMN anchor TEXT;
