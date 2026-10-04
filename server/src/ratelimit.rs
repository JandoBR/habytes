use std::{
    collections::HashMap,
    sync::Mutex,
    time::{Duration, Instant},
};

const WINDOW: Duration = Duration::from_secs(60);

/// In-memory fixed-window limiter: at most `limit` hits per key per minute.
pub struct RateLimiter {
    limit: u32,
    windows: Mutex<HashMap<String, (Instant, u32)>>,
}

impl RateLimiter {
    pub fn per_minute(limit: u32) -> Self {
        Self { limit, windows: Mutex::new(HashMap::new()) }
    }

    /// Records a hit and returns whether it is allowed.
    pub fn check(&self, key: &str) -> bool {
        let now = Instant::now();
        let mut windows = self.windows.lock().unwrap();
        let entry = windows.entry(key.to_string()).or_insert((now, 0));
        if now.duration_since(entry.0) >= WINDOW {
            *entry = (now, 0);
        }
        entry.1 += 1;
        entry.1 <= self.limit
    }

    /// Drops windows that have ended.
    pub fn prune(&self) {
        let now = Instant::now();
        self.windows.lock().unwrap().retain(|_, (start, _)| now.duration_since(*start) < WINDOW);
    }
}
