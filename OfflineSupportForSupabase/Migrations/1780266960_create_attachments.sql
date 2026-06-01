-- Add this if using supabase storage for files
create table if not exists attachments (
    id text primary key,
    created_by text not null,
    storage_path text not null,
    updated_at datetime not null,
    created_at datetime not null,
    local_path text,
    download_state text not null,
    sync_status text not null
);

create index if not exists idx_attachments_updated_at on attachments (updated_at);

create index if not exists idx_attachments_sync_status on attachments (sync_status);