create table if not exists sync_metadata (
    table_name text primary key,
    last_sync_at datetime,
    last_cursor_updated_at datetime,
    last_cursor_id text
);
