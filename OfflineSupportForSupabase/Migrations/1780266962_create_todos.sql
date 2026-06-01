--  NOTE:
--  **NO reference** because
--  having references will force `todos` to be synced before `todo_lists`
--  and this is not guaranteed by swift task group
create table if not exists todos (
    id text primary key,
    list_id text not null,
    attachment_id text,
    title text not null,
    completed boolean not null,
    created_by text not null,
    created_at datetime not null,
    updated_at datetime not null,
    sync_status text not null
);

create index if not exists idx_todos_updated_at on todos (updated_at);

create index if not exists idx_todos_sync_status on todos (sync_status);

create index if not exists idx_todos_list_id on todos (list_id);

create index if not exists idx_todos_attachment_id on todos (attachment_id);

--  NOTE:
--  1. None of the triggers is required. Once the parent (ex: todo list) is deleted. the deletion will penetrate to todos and files with the trigger on the server side.
--  2. triggers for [(1) todo list delete -> cascade todo delete (2) file delete -> todo set null] are recommended to avoid displaying contents that should be already deleted UI wise.
-- cascade delete todos when list is deleted
create trigger trg_cascade_list_delete_to_todos
after delete on todo_lists for each row
begin
delete from todos
where
    list_id = old.id;

end;

-- null out attachment_id when attachment is deleted
create trigger trg_cascade_attachment_delete_to_todos
after delete on attachments for each row
begin
update todos
set
    attachment_id = null,
    sync_status = 'pending',
    updated_at = current_timestamp
where
    attachment_id = old.id;

end;
