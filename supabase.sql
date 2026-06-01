drop schema if exists private cascade;

create schema if not exists private;

create or replace function private.case_insensitive_equal (first text, second text) returns bool
set
    search_path = '' as $$
  select(upper(first) = upper(second));
$$ language sql security definer;

drop type if exists operation cascade;

create type operation as enum('upsert', 'delete');

insert into
    storage.buckets (id, name, public)
values
    ('attachments', 'attachments', false)
on conflict (id) do update
set
    name = 'attachments',
    public = false;

drop policy if exists "user can upload to their own folder in attachments" on storage.objects;

create policy "user can upload to their own folder in attachments" on storage.objects for insert to authenticated
with
    check (
        bucket_id = 'attachments'
        and private.case_insensitive_equal (
            (storage.foldername (name)) [1],
            (
                select
                    auth.uid ()::text
            )
        )
    );

drop policy if exists "user can select their own object in attachments" on storage.objects;

create policy "user can select their own object in attachments" on storage.objects for
select
    to authenticated using (
        bucket_id = 'attachments'
        and private.case_insensitive_equal (
            owner_id,
            (
                select
                    auth.uid ()::text
            )
        )
    );

drop policy if exists "user can update their own object in attachments" on storage.objects;

create policy "user can update their own object in attachments" on storage.objects
for update
    to authenticated using (
        bucket_id = 'attachments'
        and private.case_insensitive_equal (
            owner_id,
            (
                select
                    auth.uid ()::text
            )
        )
    )
with
    check (
        bucket_id = 'attachments'
        and private.case_insensitive_equal (
            owner_id,
            (
                select
                    auth.uid ()::text
            )
        )
    );

drop policy if exists "User can delete their own objects in attachments" on storage.objects;

create policy "User can delete their own objects in attachments" on storage.objects for delete to authenticated using (
    bucket_id = 'attachments'
    and private.case_insensitive_equal (
        owner_id,
        (
            select
                auth.uid ()::text
        )
    )
);

drop table if exists attachments cascade;

create table attachments (
    id uuid not null default gen_random_uuid() primary key,
    created_by uuid default auth.uid () not null references auth.users (id) on delete cascade,
    storage_path text not null,
    updated_at timestamp with time zone not null default now(),
    created_at timestamp with time zone not null default now(),
    operation operation not null
);

alter table attachments enable row level security;

drop table if exists todo_lists cascade;

create table todo_lists (
    id uuid not null default gen_random_uuid() primary key,
    title text not null,
    created_by uuid default auth.uid () not null references auth.users (id) on delete cascade,
    updated_at timestamp with time zone not null default now(),
    created_at timestamp with time zone not null default now(),
    operation operation not null
);

alter table todo_lists enable row level security;

drop table if exists todos cascade;

create table todos (
    id uuid not null default gen_random_uuid() primary key,
    list_id uuid not null references todo_lists (id) on delete cascade,
    title text not null,
    created_by uuid default auth.uid () not null references auth.users (id) on delete cascade,
    updated_at timestamp with time zone not null default now(),
    created_at timestamp with time zone not null default now(),
    operation operation not null,
    completed boolean not null default false,
    attachment_id uuid default null references attachments (id) on delete set null
);

alter table todos enable row level security;

-- ============================================================
-- ATTACHMENTS
-- ============================================================
create policy "user can insert their own attachment" on attachments for insert to authenticated
with
    check (
        (
            select
                auth.uid ()
        ) = created_by
    );

create policy "user can select their own attachment" on attachments for
select
    to authenticated using (
        (
            select
                auth.uid ()
        ) = created_by
    );

create policy "user can update their own attachment" on attachments
for update
    to authenticated using (
        (
            select
                auth.uid ()
        ) = created_by
    )
with
    check (
        (
            select
                auth.uid ()
        ) = created_by
    );

create policy "user can delete their own attachment" on attachments for delete to authenticated using (
    (
        select
            auth.uid ()
    ) = created_by
);

create index idx_attachments_updated_at on attachments (updated_at);

create index idx_attachments_created_by on attachments (created_by);

create index idx_attachments_created_by_updated_at on attachments (created_by, updated_at);

create index idx_attachments_updated_at_id on attachments (updated_at, id);

create index idx_attachments_created_by_updated_at_id on attachments (created_by, updated_at, id);

-- ============================================================
-- TODO LISTS
-- ============================================================
create policy "user can insert their own todo list" on todo_lists for insert to authenticated
with
    check (
        (
            select
                auth.uid ()
        ) = created_by
    );

create policy "user can select their own todo list" on todo_lists for
select
    to authenticated using (
        (
            select
                auth.uid ()
        ) = created_by
    );

create policy "user can update their own todo list" on todo_lists
for update
    to authenticated using (
        (
            select
                auth.uid ()
        ) = created_by
    )
with
    check (
        (
            select
                auth.uid ()
        ) = created_by
    );

create policy "user can delete their own todo list" on todo_lists for delete to authenticated using (
    (
        select
            auth.uid ()
    ) = created_by
);

create index idx_todo_lists_updated_at on todo_lists (updated_at);

create index idx_todo_lists_created_by on todo_lists (created_by);

create index idx_todo_lists_created_by_updated_at on todo_lists (created_by, updated_at);

create index idx_todo_lists_updated_at_id on todo_lists (updated_at, id);

create index idx_todo_lists_created_by_updated_at_id on todo_lists (created_by, updated_at, id);

-- ============================================================
-- TODOS
-- ============================================================
create policy "user can insert their own todo" on todos for insert to authenticated
with
    check (
        (
            select
                auth.uid ()
        ) = created_by
    );

create policy "user can select their own todo" on todos for
select
    to authenticated using (
        (
            select
                auth.uid ()
        ) = created_by
    );

create policy "user can update their own todo" on todos
for update
    to authenticated using (
        (
            select
                auth.uid ()
        ) = created_by
    )
with
    check (
        (
            select
                auth.uid ()
        ) = created_by
    );

create policy "user can delete their own todo" on todos for delete to authenticated using (
    (
        select
            auth.uid ()
    ) = created_by
);

create index idx_todos_updated_at on todos (updated_at);

create index idx_todos_created_by on todos (created_by);

create index idx_todos_created_by_updated_at on todos (created_by, updated_at);

create index idx_todos_todo_list on todos (list_id);

create index idx_todos_attachment_id on todos (attachment_id);

create index idx_todos_updated_at_id on todos (updated_at, id);

create index idx_todos_created_by_updated_at_id on todos (created_by, updated_at, id);

-- ============================================================
-- (1) todo_list operation=delete → cascade to todos
-- ============================================================
create or replace function private.fn_cascade_list_delete_to_todos () returns trigger language plpgsql security definer
set
    search_path = private,
    public as $$
begin
    if new.operation = 'delete' then
        update public.todos
        set operation = 'delete'
        where list_id = new.id;
    end if;
    return new;
end;
$$;

create trigger trg_cascade_list_delete_to_todos
after
update on public.todo_lists for each row
execute function private.fn_cascade_list_delete_to_todos ();

-- ============================================================
-- (2) attachment operation=delete → null out todo.attachment_id
-- ============================================================
create or replace function private.fn_cascade_attachment_delete_to_todos () returns trigger language plpgsql security definer
set
    search_path = private,
    public as $$
begin
    if new.operation = 'delete' then
        update public.todos
        set attachment_id = null
        where attachment_id = new.id;
    end if;
    return new;
end;
$$;

create trigger trg_cascade_attachment_delete_to_todos
after
update on public.attachments for each row
execute function private.fn_cascade_attachment_delete_to_todos ();

-- ============================================================
-- (3) todo operation=delete → set attachment operation=delete
-- ============================================================
create or replace function private.fn_cascade_todo_delete_to_attachment () returns trigger language plpgsql security definer
set
    search_path = private,
    public as $$
begin
    if new.operation = 'delete' and new.attachment_id is not null then
        update public.attachments
        set operation = 'delete'
        where id = new.attachment_id;
    end if;
    return new;
end;
$$;

create trigger trg_cascade_todo_delete_to_attachment
after
update on public.todos for each row
execute function private.fn_cascade_todo_delete_to_attachment ();
