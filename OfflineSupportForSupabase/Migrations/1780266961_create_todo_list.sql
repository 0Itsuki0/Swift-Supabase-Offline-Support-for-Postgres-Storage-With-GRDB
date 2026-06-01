create table if not exists todo_lists (
    id text primary key,
    title text,
    created_by text not null,
    created_at datetime not null,
    updated_at datetime not null,
    sync_status text not null
);

create index if not exists idx_todo_lists_updated_at on todo_lists (updated_at);

create index if not exists idx_todo_lists_sync_status on todo_lists (sync_status);