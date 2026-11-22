-- +goose Up
SET LOCAL lock_timeout = '2s';
CREATE TABLE notes (
  id         bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  account_id bigint NOT NULL REFERENCES accounts (id),
  body       text   NOT NULL
);

-- +goose Down
-- Destructive: refuse unless the session sets fx.allow_data_down=on (DSN options=-c fx.allow_data_down=on).
-- +goose StatementBegin
DO $$
BEGIN
  IF coalesce(current_setting('fx.allow_data_down', true), '') <> 'on' THEN
    RAISE EXCEPTION 'refusing to drop notes: set fx.allow_data_down=on';
  END IF;
END $$;
-- +goose StatementEnd
SET LOCAL lock_timeout = '2s';
DROP TABLE notes;
