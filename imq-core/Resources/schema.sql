-- IMQ Database Schema
-- SQLite database schema for Immediate Merge Queue

-- Repositories table
CREATE TABLE IF NOT EXISTS repositories (
    id TEXT PRIMARY KEY,
    owner TEXT NOT NULL,
    name TEXT NOT NULL,
    full_name TEXT NOT NULL UNIQUE,
    default_branch TEXT NOT NULL,
    created_at REAL NOT NULL
);

-- Pull Requests table
CREATE TABLE IF NOT EXISTS pull_requests (
    id TEXT PRIMARY KEY,
    repository_id TEXT NOT NULL,
    number INTEGER NOT NULL,
    title TEXT NOT NULL,
    author_login TEXT NOT NULL,
    base_branch TEXT NOT NULL,
    head_branch TEXT NOT NULL,
    head_sha TEXT NOT NULL,
    is_conflicted INTEGER DEFAULT 0,
    is_up_to_date INTEGER DEFAULT 0,
    created_at REAL NOT NULL,
    updated_at REAL NOT NULL,
    FOREIGN KEY (repository_id) REFERENCES repositories(id) ON DELETE CASCADE,
    UNIQUE(repository_id, number)
);

-- Queues table
CREATE TABLE IF NOT EXISTS queues (
    id TEXT PRIMARY KEY,
    repository_id TEXT NOT NULL,
    base_branch TEXT NOT NULL,
    created_at REAL NOT NULL,
    FOREIGN KEY (repository_id) REFERENCES repositories(id) ON DELETE CASCADE,
    UNIQUE(repository_id, base_branch)
);

-- Queue Entries table
CREATE TABLE IF NOT EXISTS queue_entries (
    id TEXT PRIMARY KEY,
    queue_id TEXT NOT NULL,
    pull_request_id TEXT NOT NULL,
    position INTEGER NOT NULL,
    status TEXT NOT NULL,
    enqueued_at REAL NOT NULL,
    started_at REAL,
    completed_at REAL,
    FOREIGN KEY (queue_id) REFERENCES queues(id) ON DELETE CASCADE,
    FOREIGN KEY (pull_request_id) REFERENCES pull_requests(id) ON DELETE CASCADE
);

-- Checks table
CREATE TABLE IF NOT EXISTS checks (
    id TEXT PRIMARY KEY,
    entry_id TEXT NOT NULL,
    name TEXT NOT NULL,
    type TEXT NOT NULL,
    type_data TEXT NOT NULL,
    status TEXT NOT NULL,
    configuration TEXT NOT NULL,
    started_at REAL,
    completed_at REAL,
    output TEXT,
    FOREIGN KEY (entry_id) REFERENCES queue_entries(id) ON DELETE CASCADE
);

-- Configuration table
CREATE TABLE IF NOT EXISTS configurations (
    id INTEGER PRIMARY KEY CHECK (id = 1),
    trigger_label TEXT NOT NULL DEFAULT 'merge-queue',
    github_mode TEXT NOT NULL DEFAULT 'polling',
    polling_interval REAL NOT NULL DEFAULT 60.0,
    webhook_secret TEXT,
    check_configurations TEXT NOT NULL DEFAULT '{}',
    notification_templates TEXT NOT NULL DEFAULT '{}',
    updated_at REAL NOT NULL
);

-- Event Poll History table (for Polling mode)
CREATE TABLE IF NOT EXISTS event_poll_history (
    repository_id TEXT PRIMARY KEY,
    last_poll_time REAL NOT NULL,
    last_event_id TEXT,
    FOREIGN KEY (repository_id) REFERENCES repositories(id) ON DELETE CASCADE
);

-- Create indices for better query performance
CREATE INDEX IF NOT EXISTS idx_pull_requests_repo ON pull_requests(repository_id);
CREATE INDEX IF NOT EXISTS idx_pull_requests_number ON pull_requests(repository_id, number);
CREATE INDEX IF NOT EXISTS idx_queue_entries_queue ON queue_entries(queue_id, position);
CREATE INDEX IF NOT EXISTS idx_queue_entries_status ON queue_entries(status);
CREATE INDEX IF NOT EXISTS idx_checks_entry ON checks(entry_id);
CREATE INDEX IF NOT EXISTS idx_checks_status ON checks(status);

-- Insert default configuration
INSERT OR IGNORE INTO configurations (id, trigger_label, github_mode, polling_interval, notification_templates, updated_at)
VALUES (
    1,
    'merge-queue',
    'polling',
    60.0,
    '{}',
    strftime('%s', 'now')
);
