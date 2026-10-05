-- Any number of reminders per habit, each at a time of day and optionally only
-- on some weekdays: a JSON list of { "time": "HH:MM", "days": [1..7] | null }.

ALTER TABLE habits ADD COLUMN reminders TEXT NOT NULL DEFAULT '[]';

UPDATE habits
SET reminders = json_array(json_object('time', reminder_time, 'days', NULL))
WHERE reminder_time IS NOT NULL;

ALTER TABLE habits DROP COLUMN reminder_time;
