# Swift/Supabase: Offline First Sync Layer for Postgres/Storage With GRDB

**A generic offline-first sync layer**
for iOS apps using **GRDB** (local SQLite) and **Supabase** (remote Postgres + Storage). Records sync bidirectionally with last-write-wins (LWW) conflict resolution, keyset pagination, and optional file attachment support.

For more details, please refer to my blog [Swift/Supabase: Offline Support for Postgres/Storage With GRDB + How To Design Tables/Storages](https://medium.com/@itsuki.enjoy/swift-supabase-offline-support-for-postgres-storage-with-grdb-how-to-design-tables-storages-6789a73bcdf5)

---

## Table of Contents

1. [Architecture overview](#architecture-overview)
2. [Layer interconnections](#layer-interconnections)
3. [General flow](#general-flow)
4. [Remote table design](#remote-table-design)
5. [Local table design](#local-table-design)
6. [File storage design](#file-storage-design)
7. [Implementing a SyncableRecord](#implementing-a-syncablerecord)
8. [Why no FK constraints — use triggers instead](#why-no-fk-constraints--use-triggers-instead)
9. [Overriding conflict handling](#overriding-conflict-handling)
10. [Overriding default CRUD](#overriding-default-crud)
11. [Cached user data cleanup](#cached-user-data-cleanup)
12. [Testing with mocks](#testing-with-mocks)
13. [Recommended additions](#recommended-additions)
14. [Running the demo](#running-the-demo)

---

## Architecture overview

```
SyncCoordinator (actor)
    ├── NetworkMonitor          — triggers sync on reconnect
    └── SyncEngine<SyncableRecord> ×N  — runs per model in TaskGroup
            ├── AppDependencies.shared.local  → LocalDatabaseManager → GRDB SQLite
            │                                       └── sync_metadata (table)
            └── AppDependencies.shared.remote → SupabaseClient → Supabase Postgres
                                                    └── UserAuthManager

# only if storage support is needed
FileAttachment (SyncableRecord)
    ├── overrides handleRemoteChange / handleLocalDiff
    └── FileSyncManager
            ├── local file cache (per-user folder)
            └── Supabase Storage (userId/table/fileId_name)
```

---


## Layer interconnections

### AppDependencies
Central dependency container. Subclass it in tests to inject mocks. Every layer accesses `local` and `remote` through this — never directly via `.shared`.

```swift
// production (default)
AppDependencies.shared.local   // → LocalDatabaseManager.shared
AppDependencies.shared.remote  // → SupabaseClient.shared
AppDependencies.shared.network // → NetworkMonitor.shared

// testing
AppDependencies.shared = MockAppDependencies()
```

### NetworkMonitor
Wraps NWPathMonitor and exposes isConnected and connectionType. Posts .connectivityRestored when the path transitions from unsatisfied → satisfied, which SyncCoordinator listens to for immediate re-sync.

> **Note on `isConnected`:** `isConnected` reflects whether a network interface is available, not whether requests will actually succeed. A connected interface with 100% packet loss still passes the `isConnected` check but every request fails with `NSURLErrorNetworkConnectionLost`. Catch this error in the sync loop and break out immediately — all remaining records will fail for the same reason and will be retried on the next sync cycle.


### SyncMetadata
A local-only table (`sync_metadata`) that stores per-table sync state:
- `last_sync_at` — timestamp of last clean full **pull** (Not tracking push because push is based on sync status, not timestamp)
- `last_cursor_updated_at` / `last_cursor_id` — resume point for keyset pagination

> Metadata Fetched fresh on every `pull` iteration since other syncing on the same table (due to user action) may run in parallel and may update the metadata.


### SyncableRecord
The protocol every synced model(Table) conforms to. 
- each database table is a modeled as a Syncable Record
- the only entry point for CRUD from the view / view model layer — nothing calls `SyncEngine`, `DatabaseManager`, or `SupabaseClient` directly. 
- Default implementations delegate to `SyncEngine<Self>` below so conforming types get `upsert()`, `delete()`, `fetchOne()`, `fetch()`, and `all()` for free.  Override any of them when you need extra behavior (e.g. `FileAttachment` overrides `upsert()` and `delete()` to also manage file uploads and deletions). Refer to the  [Overriding default CRUD](#overriding-default-crud) below. 
- Default to LWW when resolving conflict but can be customized as well. Refer to the [Overriding conflict handling](#overriding-conflict-handling) below.


### SyncEngine\<Record\>
The name space (class with static implementation) responsible for handling syncing per model (SyncableRecord).
- **push** — finds locally pending/deleted records, fetches the remote version, resolves with LWW, upserts or deletes remotely
- **pull** — fetches remote changes since last sync using a keyset cursor `(updated_at, id)`, merges into local DB page by page
- **CRUD helpers** — `upsert()`, `delete()`, `fetchOne()`, `fetch()` for use by the model itself

> **Table updated_at**: update updated_at **every time** right before upsert-ing to server (for example, in the sync/push/pull function) to make sure that they reflects the time pushing to the server so that other clients can pick the change up.

### SyncCoordinator
Actor that owns the sync lifecycle. It:
- Registers one `SyncEngine` per `SyncableRecord` type at app launch
- Fires sync on a periodic timer (default 5 min)
- Fires sync immediately when receive the notification from`NetworkMonitor` when the network becomes available
- Runs all engines concurrently via `TaskGroup`


### SupabaseClient
Thin wrapper over the Supabase Swift SDK. All network calls go through here. Supports cursor-based pagination for large pull windows.
- Performing Remote CRUD through the client

> **Timeouts:** Each network layer configures its own timeout independently. Postgres request timeouts are set in `SupabaseClient`, auth request timeouts in `UserAuthManager`, and file/resource request timeouts in `FileSyncManager`.

### UserAuthManager
- Manage user authentication. 
- Post UserIdDidChange upon user id changes


### LocalDatabaseManager
- Owns the GRDB `DatabasePool`. One SQLite file per user, stored in the app group container. 
- Provides generic `save`, `fetch`, `fetchOne`, `delete` over any `FetchableRecord & MutablePersistableRecord`.
- Listen to user id change to open DB pool accordingly


### FileAttachment
A `SyncableRecord` that represents a file reference. Overrides `handleRemoteChange()`, `handleLocalDiff()`, `upsert()`, and `delete()` to manage file system side effects alongside the DB record. Tracks `storagePath` (remote), `localPath`, and `downloadState` (local only — never synced to remote).

### FileSyncManager
Handles all file I/O for `FileAttachment`. Called by `FileAttachment`'s overridden hooks and CRUD methods — never directly by `SyncEngine` or the view layer.

- `hydrate()` — checks if file is already cached locally; if not, downloads from Supabase Storage in a detached background task and updates `localPath` and `downloadState` in GRDB on completion
- `pushLocal()` — uploads the local file to Supabase Storage before the DB record is upserted remotely
- `evict()` — removes the local file cache and resets `downloadState` to `.notDownloaded`
- `deleteRemote()` — removes the file from Supabase Storage bucket

---

## General flow

### Data flow

### Write (online)

    View / ViewModel
        → item.upsert()
        → SyncEngine.upsert()
            → save locally as .pending (DatabaseManager → GRDB)
            → record.updatedAt = Date()     ← bumped right before remote push
            → SupabaseClient.upsert()       → Supabase Postgres
            → save locally as .synced


### Write (offline)

    View / ViewModel
        → item.upsert()
        → SyncEngine.upsert()
            → save locally as .pending (DatabaseManager → GRDB)
            → network unavailable — return early

    later, on reconnect or timer:
    NetworkMonitor posts connectivityRestored
        → SyncCoordinator.syncIfNeeded()
        → SyncEngine.push()
            → fetch all .pending / .deleted local records
            → for each: fetch remote version
            → LWW resolve
            → record.updatedAt = Date()     ← bumped right before remote push
            → SupabaseClient.upsert()       → Supabase Postgres
            → save locally as .synced

### Read (online)

    View / ViewModel
        → TodoItem.fetch() / fetchOne()
        → SyncEngine.fetch()
            → SyncEngine.sync()             ← full sync first
            → DatabaseManager.fetch()       → GRDB
            → return records filtered by sync_status != .deleted

### Read (offline)

    View / ViewModel
        → TodoItem.fetch() / fetchOne()
        → SyncEngine.fetch()
            → network unavailable — skip sync
            → DatabaseManager.fetch()       → GRDB
            → return records filtered by sync_status != .deleted

### Pull (periodic / reconnect)

    SyncCoordinator timer or connectivityRestored
        → SyncEngine.pull()
        → loop until hasMore == false:
            → fetch metadata (cursor) fresh each page
            → SupabaseClient.fetch(cursor:)     → Supabase Postgres
            → for each remote record:
                → DatabaseManager.fetchOne()    → GRDB
                → LWW merge (mergeRemote)
                → save result locally as .synced
            → update cursor in sync_metadata
        → SyncEngine.push() runs in parallel for other record types via TaskGroup

### Delete (online)

    View / ViewModel
        → item.delete()
        → SyncEngine.delete()
            → save locally as .deleted (DatabaseManager → GRDB)
            → record.updatedAt = Date()
            → SupabaseClient.upsert(operation: .delete)     → Supabase Postgres
            → hard delete local row (DatabaseManager → GRDB)
            → local triggers cascade to related tables


### Delete (offline)

    View / ViewModel
        → item.delete()
        → SyncEngine.delete()
            → save locally as .deleted (DatabaseManager → GRDB)
            → network unavailable — return early

    later, on reconnect:
    SyncEngine.push()
        → finds .deleted record
        → record.updatedAt = Date()
        → SupabaseClient.upsert(operation: .delete)     → Supabase Postgres
        → hard delete local row
        → server triggers cascade operation = delete to related tables
        → other devices pick it up on next pull

### Launch sequence

```
DatabaseManager.init()
    ├── register migrations
    └── set up user id change handler
    
UserAuthManager.init()
    └── restore cached user id
    
SyncCoordinator.init()
    └── set up DB change handler

App.init()
    └── bootstrapSync()
            ├── 1. register sync engine for each SyncableRecord type
            │       FileAttachment, TodoList, TodoItem
            │
            ├── 2. LocalDatabaseManager.finalizeBootstrap()
            │       marks DB as ready, then calls setup()
            │       setup() opens the GRDB pool for the current userId
            │       and runs all registered migrations
            │
            └── 3. SyncCoordinator.startAutoSync(interval: 300)
                    fires an initial sync immediately
                    schedules a repeating 5-min timer
                    starts listening for .connectivityRestored
```


In code:

```swift
private func bootstrapSync() {
    let records: [any SyncableRecord.Type] = [
        FileAttachment.self, TodoList.self, TodoItem.self,
    ]
    for record in records {
        syncCoordinator.register(record)
    }
    local.finalizeBootstrap()
    syncCoordinator.startAutoSync(interval: 300)
}
```

Migrations:
- register on DatabaseManager.init()
- must be registered **before** `finalizeBootstrap()` is called — once the pool opens, GRDB runs all pending migrations in registration order. Migration order must respect FK trigger dependencies: register parent tables before child tables.

### Notification flow

Three async notification channels coordinate state changes across the system. All use `NotificationCenter.AsyncMessage` so listeners run in structured async contexts without callback hell.

#### 1. `userIdDidChange` — auth state change

**Posted by:** `UserAuthManager.session.didSet` whenever the logged-in user changes (sign-in, sign-out, or session refresh with a different user).

**Listened to by:** `LocalDatabaseManager.userChangeTask`

**Effect:** `LocalDatabaseManager` tears down the current pool and calls `setup()` for the new userId. This opens a fresh per-user SQLite file and re-runs any pending migrations for that user. If the user signed out (`userId == nil`), the pool is set to `nil` and any further DB access throws `SyncError.notAuthenticated`.

```
UserAuthManager.session changes
    → posts userIdDidChange(userId)
    → LocalDatabaseManager receives it
    → closes old pool
    → opens new pool at <AppGroup>/<newUserId>/app.db
    → runs migrations
    → posts localDBDidChange
```

#### 2. `localDBDidChange` — database ready or switched

**Posted by:** `LocalDatabaseManager.setup()` after successfully opening and migrating the pool.

**Listened to by:** `SyncCoordinator.localDBChangeTask`

**Effect:** `SyncCoordinator` calls `syncIfNeeded()` — if the network is available and a user is authenticated, a full sync fires immediately after the DB is ready. This ensures fresh data is pulled as soon as the user signs in.

```
LocalDatabaseManager opens pool
    → posts localDBDidChange
    → SyncCoordinator receives it
    → calls syncIfNeeded()
    → if connected + authenticated: runs full sync
```

#### 3. `connectivityRestored` — network came back

**Posted by:** `NetworkMonitor` when `NWPathMonitor` transitions from unsatisfied → satisfied.

**Listened to by:** `SyncCoordinator.networkChangeTask`

**Effect:** `SyncCoordinator` calls `syncIfNeeded()`. Any records that went pending while offline are pushed, and any remote changes that accumulated are pulled.

```
Device reconnects to network
    → NWPathMonitor path.status == .satisfied
    → NetworkMonitor posts connectivityRestored
    → SyncCoordinator receives it
    → calls syncIfNeeded()
```

### Full auth + sync lifecycle

```
Cold launch (user already signed in)
    App.init → bootstrapSync → finalizeBootstrap
    → LocalDatabaseManager.setup() (existing userId from session)
    → posts localDBDidChange
    → SyncCoordinator.syncIfNeeded() → full sync

Sign out
    UserAuthManager.signOut()
    → session = nil
    → posts userIdDidChange(nil)
    → LocalDatabaseManager sets pool = nil

Sign in as new user
    UserAuthManager.signIn()
    → session = newSession
    → posts userIdDidChange(newUserId)
    → LocalDatabaseManager opens new pool for newUserId
    → posts localDBDidChange
    → SyncCoordinator fires sync for new user

Go offline → come back online
    NetworkMonitor posts connectivityRestored
    → SyncCoordinator pushes pending records
    → pulls remote changes
```

---

## Remote table design

### Required columns

| Column | Type | Notes |
|--------|------|-------|
| `id` | `uuid` | Primary key, `gen_random_uuid()` default |
| `updated_at` | `timestamptz` | Updated by the client on every write |
| `operation` | `operation` enum | `upsert` or `delete` — drives sync logic |
| `created_by` | `uuid` | References `auth.users(id)` | (Only if RLS is per user)

### Recommended indexes

```sql
-- for keyset cursor pagination
create index idx_todos_updated_at_id on todos (updated_at, id);

-- for cursor + user filter (if not guarded per user, remove created_by
create index idx_todos_created_by_updated_at_id on todos (created_by, updated_at, id);

-- for FK reference lookups
create index idx_todos_list_id on todos (list_id);
create index idx_todos_attachment_id on todos (attachment_id);
```

### RLS
Every table enables RLS with policies scoped to `created_by = auth.uid()` for all four operations (select, insert, update, delete).

### Cascade triggers
Use database triggers instead of `ON DELETE CASCADE`. This lets you set `operation = 'delete'` on child rows rather than hard-deleting them, so other devices can fetch the deletion and propagate it locally.

- Non-nullable relation (one-way cascade, ex: todo referencing list), a trigger to set child(todos) operation = delete when parent(list) operation = delete. 
- For a nullable relation (ex: todo and attachment), two triggers: one on parent(todo) operation = delete → set child(attachment) operation = delete, and another one on child(attachment) when operation is set to delete → null its parents FK column (todo.attachment_id).

```sql
create or replace function private.fn_cascade_list_delete_to_todos()
returns trigger language plpgsql security definer as $$
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
after update on public.todo_lists
for each row
execute function private.fn_cascade_list_delete_to_todos();
```

**Two-way nullable cascade (nullable relation):**

```sql
-- attachment deleted → null out todo.attachment_id
create or replace function private.fn_cascade_attachment_delete_to_todos()
returns trigger language plpgsql security definer as $$
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
after update on public.attachments
for each row
execute function private.fn_cascade_attachment_delete_to_todos();

-- todo deleted → mark its attachment for deletion
create or replace function private.fn_cascade_todo_delete_to_attachment()
returns trigger language plpgsql security definer as $$
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
after update on public.todos
for each row
execute function private.fn_cascade_todo_delete_to_attachment();
```

### What NOT to add remotely
- A trigger that auto-bumps `updated_at` on every row change — the client owns `updated_at` for LWW to work correctly. However, as mentioned in the Layer interconnections / sync engine section: client **has to** update the **updated_at** **every time** right before upsert-ing to server (for example, in the sync/push/pull function) to make sure that they reflects the time pushing to the server so that other clients can pick the change up.

---

## Local table design

### Required columns

| Column | Type | Notes |
|--------|------|-------|
| `id` | `text` (UUID stored as text) | Primary key |
| `updated_at` | `datetime` | |
| `sync_status` | `text` | `synced`, `pending`, `deleted` |

### Recommended indexes

```swift
try db.create(index: "idx_todos_updated_at", on: "todos", columns: ["updated_at"])
try db.create(index: "idx_todos_sync_status", on: "todos", columns: ["sync_status"])
```

### Use triggers instead of FK constraints

See [Why no FK constraints](#why-no-fk-constraints--use-triggers-instead) below.

### What NOT to add locally
- FK reference constraints — parallel `TaskGroup` sync means insertion order is not guaranteed; a todo may arrive before its list with no error if there's no constraint

---

## Supabase File storage design

- One universal `attachments` table (A universal join point that any table can reference to associate files with records, keeping storage paths, sync state, and local cache metadata in one place instead of scattering them across individual tables). Every other table references it by `attachment_id` — never store a storage path directly on the referencing table.
- Storage path partition: `userId/tableName/fileId_fileName` — enables per-table RLS policies on the storage bucket.
- `FileAttachment` tracks both `storagePath` (remote) and `localPath` + `downloadState` (local cache only, never synced remotely).
- File downloads happen in a detached background task — pull returns immediately without blocking on file data.

### Storage cleanup options
| Option | Notes |
|--------|-------|
| Webhook → Edge Function | Immediate, requires webhook infrastructure |
| `pg_net` inside trigger | Immediate but adds latency to every delete; fails silently if function is down |
| Cron job (recommended) | Simplest — runs daily to delete storage objects where `operation = 'delete'` |


## Local Directory design

### Recommended Folder

- if data needed to be fetched from extensions, containerURL for app group (what the demo app does)
- if not, application support. However, do note that when using Application Support directory, the URL could change on every single launch (and all previous data might be lost) when running on simulator.


### Folder structure

Since the user might be signing in with different account, database (.db) and the files are partitioned by user id.

```text
<AppGroup container>/
├── <user-uuid-1>/
│   ├── app.db                          (todos · todo_lists · attachments · sync_metadata)
│   └── attachments/
│       └── <fileId>_filename.ext       (downloadState: .downloaded)
├── <user-uuid-2>/
│   ├── app.db
│   └── attachments/
└── ···                                 (cleaned up after 30 days inactive)
```


---

## Implementing a SyncableRecord

Every synced model conforms to `SyncableRecord`. The protocol requires two payload types (`RemotePayload`, `LocalPayload`) that separate remote-facing fields from local-only fields like `sync_status` and `download_state`.

### Minimal example: TodoItem

**1. Define the model**

```swift
struct TodoItem: SyncableRecord {
    static let databaseTableName = "todos"

    var id: UUID = UUID()
    var updatedAt: Date = Date()
    var syncStatus: SyncStatus = .pending
    var operation: RemoteSyncOperation = .upsert

    var title: String
    var completed: Bool = false
    var listId: UUID
    var createdBy: UUID
    var createdAt: Date = Date()
}
```

**2. RemotePayload — fields that go to Supabase**

```swift
struct RemotePayload: SyncableRemoteRecord {
    typealias Record = TodoItem
    var id: UUID
    var title: String
    var completed: Bool
    var listId: UUID
    var createdBy: UUID
    var createdAt: Date
    var updatedAt: Date
    var operation: RemoteSyncOperation

    enum CodingKeys: String, CodingKey {
        case id, title, completed, operation
        case listId = "list_id"
        case createdBy = "created_by"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }
}

var remotePayload: RemotePayload {
    RemotePayload(id: id, title: title, completed: completed,
                  listId: listId, createdBy: createdBy,
                  createdAt: createdAt, updatedAt: updatedAt, operation: operation)
}

static func fromRemote(_ p: RemotePayload) -> Self {
    Self(id: p.id, updatedAt: p.updatedAt, syncStatus: .pending,
         operation: p.operation, title: p.title, completed: p.completed,
         listId: p.listId, createdBy: p.createdBy, createdAt: p.createdAt)
}
```

**3. LocalPayload — fields that go to GRDB**

```swift
struct LocalPayload: SyncableLocalRecord {
    typealias Record = TodoItem
    var id: UUID
    var title: String
    var completed: Bool
    var listId: UUID
    var createdBy: UUID
    var createdAt: Date
    var updatedAt: Date
    var syncStatus: SyncStatus

    enum CodingKeys: String, CodingKey {
        case id, title, completed
        case listId = "list_id"
        case createdBy = "created_by"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case syncStatus = "sync_status"
    }
}

var localPayload: LocalPayload {
    LocalPayload(id: id, title: title, completed: completed,
                 listId: listId, createdBy: createdBy,
                 createdAt: createdAt, updatedAt: updatedAt, syncStatus: syncStatus)
}

static func fromLocal(_ p: LocalPayload) -> Self {
    Self(id: p.id, updatedAt: p.updatedAt, syncStatus: p.syncStatus,
         operation: .fromSyncStatus(p.syncStatus), title: p.title,
         completed: p.completed, listId: p.listId,
         createdBy: p.createdBy, createdAt: p.createdAt)
}
```

**4. Register the local migration**

- Add raw sql to `Migrations` folder. 
- File name: for core set ups that needs to be executed before other migrations, add to `000_core.sql`. Otherwise, it is recommended to start the filename with current timestamp to ensure migration order (early timestamp migrated first)


**5. Register at app launch**

```swift
// in OfflineSupportForSupabaseApp.bootstrapSync()
let records: [any SyncableRecord.Type] = [
    FileAttachment.self, TodoList.self, TodoItem.self,  // list before item
]
for record in records {
    syncCoordinator.register(record)
}
```

---

## Why no FK constraints — use triggers instead

SQLite FK constraints enforce insertion order. Since `SyncCoordinator` runs all `SyncEngine` instances concurrently in a `TaskGroup`, a `TodoItem` referencing a `todo_list` may be inserted before that list arrives. With a FK constraint this throws an error. Without it, the row lands safely and the list arrives moments later.

The `onDelete` behavior is preserved via SQLite triggers instead:

```sql
CREATE TRIGGER IF NOT EXISTS trg_cascade_list_delete_to_todos
AFTER DELETE ON todo_lists
FOR EACH ROW
BEGIN
    DELETE FROM todos WHERE list_id = OLD.id;
END;
CREATE TRIGGER IF NOT EXISTS trg_cascade_attachment_null_on_todos
AFTER DELETE ON attachments
FOR EACH ROW
BEGIN
    UPDATE todos SET attachment_id = NULL WHERE attachment_id = OLD.id;
END;
```

### Note
1. None of the triggers is required. Once the parent (ex: todo list) is deleted. the deletion will penetrate to todos and files with the trigger on the server side, for example, Todo marked `.deleted` locally -> pushed to server -> server trigger marks attachment `operation = 'delete' -> all client devices pull the deletion
2. tiggers for [(1) todo list delete -> cascade todo delete (2) file delete -> todo set null] are recommended to avoid displaying contents that should be already deleted UI wise.
3. trigger for setting attachment to delete upon todo delete is not necessary. (Or should't be added if more than one item can refer to the same attachment)


---

## Overriding conflict handling

By default `SyncEngine` uses LWW (last-write-wins) based on `updated_at`. Override `handleRemoteChange` and `handleLocalDiff` on your model when the default behavior isn't enough — for example when file system side effects are required.

Both hooks return `ChangeHandlingResult<Self>`:
- `.handled(record?)` — you took care of it, engine skips its default logic
- `.notHandled` — engine proceeds with LWW

### Example: FileAttachment

`FileAttachment` overrides both hooks to manage the local file cache alongside the DB record.

```swift
static func handleRemoteChange(
    remote: FileAttachment,
    local: FileAttachment?
) async throws -> ChangeHandlingResult<FileAttachment> {

    // no local copy yet
    guard let local else {
        switch remote.operation {
        case .upsert:
            var record = remote
            FileSyncManager.hydrate(record)   // background download, non-blocking
            record.syncStatus = .synced
            try await LocalDatabaseManager.shared.save(record: record.localPayload)
            return .handled(record)
        case .delete:
            try await FileSyncManager.evictLocalFile(remote)
            try await LocalDatabaseManager.shared.delete(id: remote.id, for: LocalPayload.self)
            return .handled(nil)
        }
    }

    return try await handleDiff(remote: remote, local: local)
}

static func handleLocalDiff(
    remote: FileAttachment?,
    local: FileAttachment
) async throws -> ChangeHandlingResult<FileAttachment> {

    guard let remote else {
        switch local.syncStatus {
        case .pending:
            try await FileSyncManager.pushLocal(local)
            var updated = local
            updated.operation = .upsert
            try await SupabaseClient.shared.upsert(into: databaseTableName, record: updated.remotePayload)
            updated.syncStatus = .synced
            try await LocalDatabaseManager.shared.save(record: updated.localPayload)
            return .handled(updated)
        case .deleted:
            return .handled(nil)
        case .synced:
            try await hardDeleteLocal(local)
            return .handled(nil)
        }
    }

    return try await handleDiff(remote: remote, local: local)
}
```

The key insight: the hooks are called *before* the engine's default merge. Return `.handled` and the engine skips LWW entirely for that record.

---

## Overriding default CRUD

`SyncableRecord` provides default implementations of `upsert()`, `delete()`, `fetchOne()`, and `fetch()` via `SyncEngine`. Override them on your model when you need extra behavior — for example `FileAttachment` handles the storage upload/download alongside the DB write.

```swift
// default — works for most models, no override needed
mutating func upsert() async throws {
    let new = try await SyncEngine<Self>.upsert(record: self)
    self = new
}

// FileAttachment override — also uploads the file
mutating func upsert() async throws {
    self.syncStatus = .pending
    self = try await Self.upsertLocal(self)
    guard NetworkMonitor.shared.isConnected else { return }

    try await FileSyncManager.pushLocal(self)
    self.operation = .upsert
    try await SupabaseClient.shared.upsert(into: Self.databaseTableName, record: self.remotePayload)
    self.syncStatus = .synced
    try await LocalDatabaseManager.shared.save(record: self.localPayload)
}

// FileAttachment delete override — also removes the storage object
mutating func delete() async throws {
    try await FileSyncManager.deleteLocal(self)
    guard NetworkMonitor.shared.isConnected else { return }

    try await FileSyncManager.deleteRemote(storagePath: self.storagePath)
    self.operation = .delete
    try await SupabaseClient.shared.upsert(into: Self.databaseTableName, record: self.remotePayload)
    try await LocalDatabaseManager.shared.delete(id: self.id, for: Self.LocalPayload.self)
}
```

---

## Cached user data cleanup

Each user gets their own SQLite file and file cache under the app group container:

```
<AppGroup>/
    <userId-A>/
        app.db
        attachments/
            <attachmentId>_filename.jpg
    <userId-B>/
        app.db
        attachments/
```

`UserLastAccess` tracks the last time each user's database was opened. On every launch, a background task runs `cleanupCachedUserData(currentUserId:)` which:

1. Reads the `user_last_access` map from `UserDefaults`
2. Skips the current user
3. Removes the entire `<userId>/` directory for any user whose last access is older than 30 days
4. Removes their entry from the map

```swift
static func cleanupCachedUserData(currentUserId: UUID) {
    let cutoff = Date().timeIntervalSince1970 - cutoffInterval  // 30 days
    for (userId, lastAccess) in accessMap {
        guard userId != currentUserId.uuidString, lastAccess < cutoff else { continue }
        try? FileManager.default.removeItem(at: URL.baseUrlForUser(UUID(uuidString: userId)!))
    }
}
```

This runs as a detached background task after the database is opened, so it never blocks launch.

---

## Testing with mocks

### 1. Subclass AppDependencies

```swift
class MockLocalDatabaseManager: LocalDatabaseManager {
    // override save, fetch, etc. to use an in-memory GRDB pool
}

class MockSupabaseClient: SupabaseClient {
    var stubbedRecords: [Any] = []
    // override fetch, upsert, delete to return stubbedRecords
}

class MockNetworkMonitor: NetworkMonitor {
    override var isConnected: Bool { false }  // simulate offline
}

class MockAppDependencies: AppDependencies {
    override var local: LocalDatabaseManager { MockLocalDatabaseManager.shared }
    override var remote: SupabaseClient { MockSupabaseClient.shared }
    override var network: NetworkMonitor { MockNetworkMonitor.shared }
}
```

### 2. Swap in setUp / tearDown

```swift
class SyncEngineTests: XCTestCase {
    override func setUp() {
        super.setUp()
        AppDependencies.shared = MockAppDependencies()
    }

    override func tearDown() {
        AppDependencies.shared = AppDependencies()
        super.tearDown()
    }
}
```

### 3. Test push behavior

```swift
func testPushUpsertsPendingRecord() async throws {
    let mockDB = AppDependencies.shared.local as! MockLocalDatabaseManager
    let mockRemote = AppDependencies.shared.remote as! MockSupabaseClient

    // seed a pending record locally
    var item = TodoItem(title: "Buy milk", createdBy: UUID(), listId: UUID())
    item.syncStatus = .pending
    try await mockDB.save(record: item.localPayload)

    // run push
    let result = try await SyncEngine<TodoItem>.push()

    XCTAssertEqual(result.pushed, 1)
    XCTAssertTrue(mockRemote.upsertedRecords.contains(where: { $0.id == item.id }))
}
```

### 4. Test offline behavior

```swift
func testUpsertStaysPendingWhenOffline() async throws {
    // MockNetworkMonitor returns isConnected = false
    var item = TodoItem(title: "Offline item", createdBy: UUID(), listId: UUID())
    try await item.upsert()

    let saved: TodoItem.LocalPayload? = try await AppDependencies.shared.local.fetchOne(id: item.id)
    XCTAssertEqual(saved?.syncStatus, .pending)
}
```

> **Note on parallel tests:** `AppDependencies.shared` is global state. Run sync-related tests serially (mark the test class with `@MainActor` or use a serial test queue) to avoid one test's mock stomping another's.

---

## Recommended additions

### Retry back-off for persistently failing records
A record that the server consistently rejects (e.g. constraint violation) will be retried every 5 minutes forever. Add `fail_count` and `next_retry_at` columns to `sync_metadata` or directly to local payloads, and skip records in `pendingSyncedRecords()` whose `next_retry_at` is in the future.

### Pull order respecting FK dependencies
`SyncCoordinator` runs all engines concurrently. A pulled `TodoItem` may try to insert before its `TodoList` has landed (no FK error locally, but logically orphaned until the next sync). Consider a dependency-ordered pull phase: run `TodoList` pull to completion before starting `TodoItem` pull. Push can remain fully concurrent.

### Conflict visibility
LWW silently discards the losing write. For fields where silent loss is unacceptable (e.g. a `notes` field edited on two devices), surface conflicts to the UI. `SyncResult.conflicts` is already counted — wire it to a notification or badge so the user knows something was overwritten.


---

## Running the demo

### 1. Supabase set up

#### Run SQL
In your Supabase dashboard → SQL Editor, run `supabase.sql`. This creates:

**Tables:** `attachments`, `todo_lists`, `todos`

**Indexes:**
- `idx_attachments_updated_at_id`, `idx_attachments_created_by_updated_at_id`, `idx_attachments_created_by`
- `idx_todo_lists_updated_at_id`, `idx_todo_lists_created_by_updated_at_id`, `idx_todo_lists_created_by`
- `idx_todos_updated_at_id`, `idx_todos_created_by_updated_at_id`, `idx_todos_created_by`, `idx_todos_list_id`, `idx_todos_attachment_id`

**Triggers:**
- `trg_cascade_list_delete_to_todos` — when a list `operation` is set to `delete`, propagates `operation = delete` to all its todos
- `trg_cascade_attachment_delete_to_todos` — when an attachment `operation` is set to `delete`, nulls out `attachment_id` on referencing todos
- `trg_cascade_todo_delete_to_attachment` — when a todo `operation` is set to `delete`, propagates `operation = delete` to its attachment

**Storage:** Creates the `attachments` bucket with RLS policies scoped to `userId` folder.

#### Create dummy user

- Create a user from supabase console

### 2. (Optional) Set up the storage directory

The app uses an app group container by default. If you don't have an app group configured, change `appBaseURL` in `OfflineSupportForSupabaseApp.swift` to use the application support directory instead:

```swift
static var appBaseURL: URL {
    let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}
```

### 3. Configure credentials

In `OfflineSupportForSupabaseApp.swift`, set:

```swift
let userEmail = "example@gmail.com"
let password = "123456"
let appGroupId = "group.your.app"  // or remove if using application support directory for local database
let supabaseURL = "https://your-project.supabase.co"
let anonKey = "your-anon-key"
```

### 4. Start the app

Build and run in Xcode. On first launch:
1. Database register all migrations
2. `bootstrapSync()` 
    - registers sync engine 
    - open the GRDB pool if there is an existing user
    - startAutoSync
3. `SyncCoordinator.startAutoSync()` fires an initial sync
4. Sign in via the auth UI if not signed in yet — `UserAuthManager` posts `userIdDidChange` , the DB re-opens for that user, and a full sync runs


### Demo

![](./demo.gif)
