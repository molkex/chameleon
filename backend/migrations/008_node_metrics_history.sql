-- Node metrics history for dashboard charts
CREATE TABLE IF NOT EXISTS node_metrics_history (
    id SERIAL PRIMARY KEY,
    node_key VARCHAR(64) NOT NULL,
    cpu REAL,
    ram_used REAL,
    ram_total REAL,
    disk REAL,
    traffic_up BIGINT DEFAULT 0,
    traffic_down BIGINT DEFAULT 0,
    online_users INTEGER DEFAULT 0,
    recorded_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX idx_node_metrics_time ON node_metrics_history(node_key, recorded_at);
