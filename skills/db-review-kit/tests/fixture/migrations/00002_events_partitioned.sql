-- +goose Up
SET LOCAL lock_timeout = '2s';
CREATE TABLE events (
  id         bigint      NOT NULL,
  created_at timestamptz NOT NULL,
  payload    jsonb       NOT NULL,
  PRIMARY KEY (id, created_at)
) PARTITION BY RANGE (created_at);
CREATE TABLE events_2026_11 PARTITION OF events FOR VALUES FROM ('2026-11-01') TO ('2026-12-01');
CREATE TABLE events_2026_12 PARTITION OF events FOR VALUES FROM ('2026-12-01') TO ('2027-01-01');
-- Deliberate defect for the kit self-test: this partition's ACL differs from the parent.
REVOKE ALL ON events_2026_12 FROM fx_app;

-- +goose Down
SET LOCAL lock_timeout = '2s';
DROP TABLE events;
