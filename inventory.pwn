// ==========================================
// Inventory System (MVP, DB-first, UI-agnostic)
// ==========================================
// Source of truth is SQLite. All operations persist immediately.
// owner_id uses accounts.id (INTEGER).

#define INV_CONTAINER_TYPE_POCKET   "player_pocket"
#define INV_CONTAINER_TYPE_EQUIP    "player_equip"
#define INV_CONTAINER_TYPE_BACKPACK "player_backpack"

#define DIALOG_INV_MAIN           (2000)
#define DIALOG_INV_ACTION         (2001)
#define DIALOG_INV_MOVE_CONTAINER (2002)
#define DIALOG_INV_MOVE_SLOT      (2003)
#define DIALOG_INV_DROP_AMOUNT    (2004)
#define DIALOG_INV_GIVE_LIST      (2005)
#define DIALOG_INV_GIVE_ID        (2006)
#define DIALOG_INV_GIVE_AMOUNT    (2007)
#define DIALOG_INV_INFO           (2008)

#define INV_LIST_MAX              (128)
#define INV_OPEN_KEY              (KEY_CTRL_BACK)

#define INV_KIND_POCKET   (0)
#define INV_KIND_EQUIP    (1)
#define INV_KIND_BACKPACK (2)

#define INV_POCKET_SIZE (20)
#define INV_EQUIP_SIZE  (2)

#define INV_EQUIP_SLOT_ARMOR    (0)
#define INV_EQUIP_SLOT_BACKPACK (1)

// Item IDs (MVP)
#define ITEM_WATER     (1)
#define ITEM_FOOD      (2)
#define ITEM_MEDKIT    (3)
#define ITEM_ARMOR     (4)
#define ITEM_BACKPACK  (5)
#define ITEM_PLATE     (6)
#define ITEM_BLUEPRINT (7)

new bool:gInvLoaded[MAX_PLAYERS];
new gInvContainerId[MAX_PLAYERS][3];
new gInvContainerSize[MAX_PLAYERS][3];
new bool:gInvOpLock[MAX_PLAYERS];
new gInvListKind[MAX_PLAYERS][INV_LIST_MAX];
new gInvListSlot[MAX_PLAYERS][INV_LIST_MAX];
new gInvListCount[MAX_PLAYERS];
new gInvSelKind[MAX_PLAYERS];
new gInvSelSlot[MAX_PLAYERS];
new gInvMoveTargetKind[MAX_PLAYERS];
new gInvGiveList[MAX_PLAYERS][MAX_PLAYERS];
new gInvGiveCount[MAX_PLAYERS];
new gInvGiveTarget[MAX_PLAYERS];

forward bool:Inv_IsPlayerReady(playerid);
forward bool:Inv_IsValidKind(kind);
forward Inv_GetKindSize(playerid, kind);
forward bool:Inv_DB_EnsureContainer(owner_id, const type[], size, &container_id);
forward bool:Inv_DB_GetSlotItem(container_id, slot, &item_id, &amount, data[], data_size);
forward bool:Inv_FindBestSlot(container_id, container_size, item_id, const data[], &out_slot);
forward bool:Inv_MoveAuto(playerid, from_kind, from_slot);
forward bool:Inv_MoveItemPlayer(playerid, from_kind, from_slot, to_kind, to_slot);
forward bool:Inv_UseSlot(playerid, kind, slot);
forward bool:Inv_GiveItem(playerid, targetid, from_kind, from_slot, amount);

stock Inv_LogLine(const text[])
{
    printf("[INV] %s", text);
    return 1;
}

stock Inv_GetItemName(item_id, out[], out_size)
{
    switch (item_id)
    {
        case ITEM_WATER: format(out, out_size, "Вода");
        case ITEM_FOOD: format(out, out_size, "Еда");
        case ITEM_MEDKIT: format(out, out_size, "Аптечка");
        case ITEM_ARMOR: format(out, out_size, "Броня");
        case ITEM_BACKPACK: format(out, out_size, "Рюкзак");
        case ITEM_PLATE: format(out, out_size, "Номер");
        case ITEM_BLUEPRINT: format(out, out_size, "Чертёж");
        default: format(out, out_size, "Неизвестно");
    }
    return 1;
}

stock Inv_ListAddItem(playerid, kind, slot, list[], list_size, const text[])
{
    if (gInvListCount[playerid] >= INV_LIST_MAX) return 0;
    if (list[0]) strcat(list, "\n", list_size);
    strcat(list, text, list_size);

    gInvListKind[playerid][gInvListCount[playerid]] = kind;
    gInvListSlot[playerid][gInvListCount[playerid]] = slot;
    gInvListCount[playerid]++;
    return 1;
}

stock bool:Inv_FindBestSlot(container_id, container_size, item_id, const data[], &out_slot)
{
    out_slot = -1;

    new bool:stackable, max_stack, bool:unique, equip_slot, bool:usable;
    Inv_ItemDef(item_id, stackable, max_stack, unique, equip_slot, usable);

    if (stackable)
    {
        for (new slot = 0; slot < container_size; slot++)
        {
            new sid, samount;
            new sdata[256];
            if (!Inv_DB_GetSlotItem(container_id, slot, sid, samount, sdata, sizeof sdata)) continue;
            if (sid != item_id) continue;
            if (strcmp(sdata, data, false) != 0) continue;
            if (samount >= max_stack) continue;
            out_slot = slot;
            return true;
        }
    }

    for (new slot = 0; slot < container_size; slot++)
    {
        new sid, samount;
        new tmp[4];
        if (Inv_DB_GetSlotItem(container_id, slot, sid, samount, tmp, sizeof tmp)) continue;
        out_slot = slot;
        return true;
    }
    return false;
}

stock bool:Inv_MoveAuto(playerid, from_kind, from_slot)
{
    if (!Inv_IsPlayerReady(playerid)) return false;
    if (!Inv_IsValidKind(from_kind)) return false;

    new from_cid = gInvContainerId[playerid][from_kind];
    if (!from_cid) return false;

    new item_id, amount;
    new data[256];
    if (!Inv_DB_GetSlotItem(from_cid, from_slot, item_id, amount, data, sizeof data)) return false;

    new target_kind = -1;
    new target_slot = -1;

    if (from_kind == INV_KIND_POCKET)
    {
        if (item_id == ITEM_ARMOR)
        {
            target_kind = INV_KIND_EQUIP;
            target_slot = INV_EQUIP_SLOT_ARMOR;
        }
        else if (item_id == ITEM_BACKPACK)
        {
            target_kind = INV_KIND_EQUIP;
            target_slot = INV_EQUIP_SLOT_BACKPACK;
        }
        else if (gInvContainerId[playerid][INV_KIND_BACKPACK])
        {
            target_kind = INV_KIND_BACKPACK;
        }
    }
    else if (from_kind == INV_KIND_BACKPACK || from_kind == INV_KIND_EQUIP)
    {
        target_kind = INV_KIND_POCKET;
    }

    if (target_kind == -1) return false;

    if (target_kind == INV_KIND_EQUIP)
    {
        return Inv_MoveItemPlayer(playerid, from_kind, from_slot, target_kind, target_slot);
    }

    new target_cid = gInvContainerId[playerid][target_kind];
    if (!target_cid) return false;
    new target_size = Inv_GetKindSize(playerid, target_kind);
    if (target_size <= 0) return false;

    if (!Inv_FindBestSlot(target_cid, target_size, item_id, data, target_slot)) return false;
    return Inv_MoveItemPlayer(playerid, from_kind, from_slot, target_kind, target_slot);
}

stock bool:Inv_Lock(playerid)
{
    if (gInvOpLock[playerid]) return false;
    gInvOpLock[playerid] = true;
    return true;
}

stock Inv_Unlock(playerid)
{
    gInvOpLock[playerid] = false;
    return 1;
}

stock bool:Inv_IsPlayerReady(playerid)
{
    if (!IsPlayerConnected(playerid)) return false;
    if (gDB == DB:0) return false;
    if (!PlayerData[playerid][Logged]) return false;
    if (!gInvLoaded[playerid]) return false;
    return true;
}

stock bool:Inv_IsValidKind(kind)
{
    return (kind == INV_KIND_POCKET || kind == INV_KIND_EQUIP || kind == INV_KIND_BACKPACK);
}

stock Inv_GetKindSize(playerid, kind)
{
    if (kind == INV_KIND_POCKET) return INV_POCKET_SIZE;
    if (kind == INV_KIND_EQUIP) return INV_EQUIP_SIZE;
    if (kind == INV_KIND_BACKPACK) return gInvContainerSize[playerid][INV_KIND_BACKPACK];
    return 0;
}

stock bool:Inv_DB_Exec(const q[])
{
    new DBResult:r = DB_ExecuteQuery(gDB, q);
    if (r == DBResult:0) return false;
    DB_FreeResultSet(r);
    return true;
}

stock bool:Inv_DB_Begin()
{
    return Inv_DB_Exec("BEGIN IMMEDIATE;");
}

stock Inv_DB_Commit()
{
    Inv_DB_Exec("COMMIT;");
    return 1;
}

stock Inv_DB_Rollback()
{
    Inv_DB_Exec("ROLLBACK;");
    return 1;
}

stock Inv_DB_Migrate()
{
    if (gDB == DB:0) return 0;

    if (!DB_TableExists("containers"))
    {
        Inv_DB_Exec("CREATE TABLE IF NOT EXISTS containers (id INTEGER PRIMARY KEY AUTOINCREMENT, type TEXT NOT NULL, owner_id INTEGER NOT NULL, size INTEGER NOT NULL, UNIQUE(type, owner_id));");
    }
    else
    {
        new bool:needs_migrate = false;
        new DBResult:r = DB_ExecuteQuery(gDB, "SELECT type FROM pragma_table_info('containers') WHERE name='owner_id' LIMIT 1;");
        if (r != DBResult:0)
        {
            if (DB_GetRowCount(r) > 0)
            {
                new owner_type[32];
                DB_GetFieldStringByName(r, "type", owner_type, sizeof owner_type);
                if (strcmp(owner_type, "TEXT", true) == 0) needs_migrate = true;
            }
            DB_FreeResultSet(r);
        }

        if (needs_migrate)
        {
            Inv_DB_Exec("CREATE TABLE containers_new (id INTEGER PRIMARY KEY AUTOINCREMENT, type TEXT NOT NULL, owner_id INTEGER NOT NULL, size INTEGER NOT NULL, UNIQUE(type, owner_id));");
            Inv_DB_Exec("INSERT INTO containers_new (id,type,owner_id,size) SELECT c.id,c.type,a.id,c.size FROM containers c JOIN accounts a ON a.name=c.owner_id;");
            Inv_DB_Exec("DROP TABLE containers;");
            Inv_DB_Exec("ALTER TABLE containers_new RENAME TO containers;");
        }
    }

    Inv_DB_Exec("CREATE TABLE IF NOT EXISTS container_items (container_id INTEGER NOT NULL, slot INTEGER NOT NULL, item_id INTEGER NOT NULL, amount INTEGER NOT NULL, data TEXT NOT NULL, PRIMARY KEY(container_id, slot));");
    return 1;
}

stock bool:Inv_DB_GetContainerId(owner_id, const type[], &container_id)
{
    container_id = 0;
    new etype[64];
    SQLEscape(type, etype, sizeof etype);

    new q[256];
    format(q, sizeof q, "SELECT id FROM containers WHERE type='%s' AND owner_id=%d LIMIT 1;", etype, owner_id);
    new DBResult:r = DB_ExecuteQuery(gDB, q);
    if (r == DBResult:0) return false;

    if (DB_GetRowCount(r) < 1)
    {
        DB_FreeResultSet(r);
        return false;
    }
    container_id = DB_GetFieldIntByName(r, "id");
    DB_FreeResultSet(r);
    return (container_id > 0);
}

stock bool:Inv_DB_EnsureContainer(owner_id, const type[], size, &container_id)
{
    container_id = 0;
    new etype[64];
    SQLEscape(type, etype, sizeof etype);

    new q[384];
    format(q, sizeof q, "INSERT OR IGNORE INTO containers(type, owner_id, size) VALUES('%s',%d,%d);", etype, owner_id, size);
    if (!Inv_DB_Exec(q)) return false;

    if (!Inv_DB_GetContainerId(owner_id, type, container_id)) return false;

    format(q, sizeof q, "UPDATE containers SET size=%d WHERE id=%d;", size, container_id);
    Inv_DB_Exec(q);
    return true;
}

stock bool:Inv_DB_DeleteContainer(container_id)
{
    new q[256];
    format(q, sizeof q, "DELETE FROM container_items WHERE container_id=%d;", container_id);
    if (!Inv_DB_Exec(q)) return false;
    format(q, sizeof q, "DELETE FROM containers WHERE id=%d;", container_id);
    return Inv_DB_Exec(q);
}

stock bool:Inv_DB_IsContainerEmpty(container_id)
{
    new q[192];
    format(q, sizeof q, "SELECT 1 FROM container_items WHERE container_id=%d LIMIT 1;", container_id);
    new DBResult:r = DB_ExecuteQuery(gDB, q);
    if (r == DBResult:0) return true;
    new rows = DB_GetRowCount(r);
    DB_FreeResultSet(r);
    return (rows < 1);
}

stock bool:Inv_DB_GetMaxSlot(container_id, &max_slot)
{
    max_slot = -1;
    new q[192];
    format(q, sizeof q, "SELECT MAX(slot) AS max_slot FROM container_items WHERE container_id=%d;", container_id);
    new DBResult:r = DB_ExecuteQuery(gDB, q);
    if (r == DBResult:0) return false;
    if (DB_GetRowCount(r) < 1)
    {
        DB_FreeResultSet(r);
        return false;
    }
    max_slot = DB_GetFieldIntByName(r, "max_slot");
    DB_FreeResultSet(r);
    return true;
}

stock bool:Inv_DB_GetSlotItem(container_id, slot, &item_id, &amount, data[], data_size)
{
    item_id = 0;
    amount = 0;
    data[0] = '\0';

    new q[256];
    format(q, sizeof q, "SELECT item_id, amount, data FROM container_items WHERE container_id=%d AND slot=%d LIMIT 1;", container_id, slot);
    new DBResult:r = DB_ExecuteQuery(gDB, q);
    if (r == DBResult:0) return false;

    if (DB_GetRowCount(r) < 1)
    {
        DB_FreeResultSet(r);
        return false;
    }

    item_id = DB_GetFieldIntByName(r, "item_id");
    amount = DB_GetFieldIntByName(r, "amount");
    DB_GetFieldStringByName(r, "data", data, data_size);
    DB_FreeResultSet(r);
    return true;
}

stock bool:Inv_DB_SetSlotItem(container_id, slot, item_id, amount, const data[])
{
    new edata[512];
    SQLEscape(data, edata, sizeof edata);

    new q[768];
    format(q, sizeof q, "INSERT OR REPLACE INTO container_items(container_id, slot, item_id, amount, data) VALUES(%d,%d,%d,%d,'%s');",
        container_id, slot, item_id, amount, edata);
    return Inv_DB_Exec(q);
}

stock bool:Inv_DB_ClearSlot(container_id, slot)
{
    new q[256];
    format(q, sizeof q, "DELETE FROM container_items WHERE container_id=%d AND slot=%d;", container_id, slot);
    return Inv_DB_Exec(q);
}

stock Inv_ItemDef(item_id, &bool:stackable, &max_stack, &bool:unique, &equippable_slot, &bool:usable)
{
    stackable = false;
    max_stack = 1;
    unique = false;
    equippable_slot = -1;
    usable = false;

    switch (item_id)
    {
        case ITEM_WATER:   { stackable = true; max_stack = 20; usable = true; }
        case ITEM_FOOD:    { stackable = true; max_stack = 20; usable = true; }
        case ITEM_MEDKIT:  { stackable = true; max_stack = 10; usable = true; }
        case ITEM_ARMOR:   { unique = true; equippable_slot = INV_EQUIP_SLOT_ARMOR; usable = true; }
        case ITEM_BACKPACK:{ unique = true; equippable_slot = INV_EQUIP_SLOT_BACKPACK; usable = true; }
        case ITEM_PLATE:   { unique = true; usable = true; }
        case ITEM_BLUEPRINT:{ unique = true; usable = true; }
    }
    return 1;
}

stock bool:Inv_ParseJsonInt(const data[], const key[], &out_value)
{
    out_value = 0;
    if (!data[0] || !key[0]) return false;

    new needle[64];
    format(needle, sizeof needle, "\"%s\"", key);
    new pos = strfind(data, needle, true);
    if (pos == -1) return false;

    pos += strlen(needle);
    while (data[pos] && (data[pos] == ' ' || data[pos] == '\t' || data[pos] == '\r' || data[pos] == '\n' || data[pos] == ':')) pos++;
    if (!data[pos]) return false;

    if (data[pos] < '0' || data[pos] > '9') return false;

    new val = 0;
    while (data[pos] >= '0' && data[pos] <= '9')
    {
        val = val * 10 + (data[pos] - '0');
        pos++;
    }
    out_value = val;
    return true;
}

stock Inv_GetBackpackSizeFromData(const data[])
{
    new size;
    if (Inv_ParseJsonInt(data, "size", size) && size > 0) return size;
    if (Inv_ParseJsonInt(data, "backpack_size", size) && size > 0) return size;
    return 20;
}

stock bool:Inv_ValidateMoveTo(playerid, to_kind, to_slot, item_id)
{
    if (to_slot < 0) return false;

    if (to_kind == INV_KIND_POCKET)
    {
        return (to_slot < INV_POCKET_SIZE);
    }
    if (to_kind == INV_KIND_EQUIP)
    {
        if (to_slot < 0 || to_slot >= INV_EQUIP_SIZE) return false;
        if (to_slot == INV_EQUIP_SLOT_ARMOR) return (item_id == ITEM_ARMOR);
        if (to_slot == INV_EQUIP_SLOT_BACKPACK) return (item_id == ITEM_BACKPACK);
        return false;
    }
    if (to_kind == INV_KIND_BACKPACK)
    {
        new cid = gInvContainerId[playerid][INV_KIND_BACKPACK];
        if (!cid) return false;
        return (to_slot < gInvContainerSize[playerid][INV_KIND_BACKPACK]);
    }
    return false;
}

stock bool:Inv_AddItem(container_id, item_id, amount, const data[])
{
    if (gDB == DB:0) return false;
    if (container_id <= 0) return false;
    if (amount <= 0) return false;

    new bool:stackable, max_stack, bool:unique, equip_slot, bool:usable;
    Inv_ItemDef(item_id, stackable, max_stack, unique, equip_slot, usable);

    new data_norm[256];
    if (!data[0]) format(data_norm, sizeof data_norm, "{}");
    else format(data_norm, sizeof data_norm, "%s", data);

    // Unique: each unit is one slot.
    if (unique && amount > 1)
    {
        for (new i = 0; i < amount; i++)
        {
            if (!Inv_AddItem(container_id, item_id, 1, data_norm)) return false;
        }
        return true;
    }
    if (unique) amount = 1;

    new q[192];
    format(q, sizeof q, "SELECT size FROM containers WHERE id=%d LIMIT 1;", container_id);
    new DBResult:r = DB_ExecuteQuery(gDB, q);
    if (r == DBResult:0) return false;
    if (DB_GetRowCount(r) < 1) { DB_FreeResultSet(r); return false; }
    new container_size = DB_GetFieldIntByName(r, "size");
    DB_FreeResultSet(r);

    if (!Inv_DB_Begin()) return false;

    // Stack into existing.
    if (stackable)
    {
        for (new slot = 0; slot < container_size; slot++)
        {
            new sid, samount;
            new sdata[256];
            if (!Inv_DB_GetSlotItem(container_id, slot, sid, samount, sdata, sizeof sdata)) continue;
            if (sid != item_id) continue;
            if (strcmp(sdata, data_norm, false) != 0) continue;
            if (samount >= max_stack) continue;

            new can_add = max_stack - samount;
            new add_now = (amount > can_add) ? can_add : amount;
            samount += add_now;
            amount -= add_now;

            if (!Inv_DB_SetSlotItem(container_id, slot, sid, samount, sdata))
            {
                Inv_DB_Rollback();
                return false;
            }
            if (amount <= 0)
            {
                Inv_DB_Commit();
                return true;
            }
        }
    }

    // Fill empty slots.
    for (new slot = 0; slot < container_size; slot++)
    {
        new sid, samount;
        new tmp[4];
        if (Inv_DB_GetSlotItem(container_id, slot, sid, samount, tmp, sizeof tmp)) continue;

        new put_amount = amount;
        if (stackable && put_amount > max_stack) put_amount = max_stack;
        if (unique) put_amount = 1;

        if (!Inv_DB_SetSlotItem(container_id, slot, item_id, put_amount, data_norm))
        {
            Inv_DB_Rollback();
            return false;
        }

        amount -= put_amount;
        if (amount <= 0)
        {
            Inv_DB_Commit();
            return true;
        }
    }

    Inv_DB_Rollback();
    return false;
}

stock bool:Inv_RemoveItem(container_id, slot, amount)
{
    if (gDB == DB:0) return false;
    if (container_id <= 0) return false;
    if (slot < 0) return false;
    if (amount <= 0) return false;

    new item_id, cur_amount;
    new data[256];
    if (!Inv_DB_GetSlotItem(container_id, slot, item_id, cur_amount, data, sizeof data)) return false;

    if (!Inv_DB_Begin()) return false;

    cur_amount -= amount;
    if (cur_amount <= 0)
    {
        if (!Inv_DB_ClearSlot(container_id, slot))
        {
            Inv_DB_Rollback();
            return false;
        }
    }
    else
    {
        if (!Inv_DB_SetSlotItem(container_id, slot, item_id, cur_amount, data))
        {
            Inv_DB_Rollback();
            return false;
        }
    }

    Inv_DB_Commit();
    return true;
}

stock bool:Inv_MoveItem(from_container, from_slot, to_container, to_slot)
{
    if (gDB == DB:0) return false;
    if (from_container <= 0 || to_container <= 0) return false;
    if (from_slot < 0 || to_slot < 0) return false;

    new src_item, src_amount;
    new src_data[256];
    if (!Inv_DB_GetSlotItem(from_container, from_slot, src_item, src_amount, src_data, sizeof src_data)) return false;

    if (!Inv_DB_Begin()) return false;

    new dst_item, dst_amount;
    new dst_data[256];
    new bool:dst_exists = Inv_DB_GetSlotItem(to_container, to_slot, dst_item, dst_amount, dst_data, sizeof dst_data);

    new bool:stackable, max_stack, bool:unique, equip_slot, bool:usable;
    Inv_ItemDef(src_item, stackable, max_stack, unique, equip_slot, usable);

    if (dst_exists && stackable && dst_item == src_item && strcmp(dst_data, src_data, false) == 0 && dst_amount < max_stack)
    {
        new can_add = max_stack - dst_amount;
        new add_now = (src_amount > can_add) ? can_add : src_amount;
        dst_amount += add_now;
        src_amount -= add_now;

        if (!Inv_DB_SetSlotItem(to_container, to_slot, dst_item, dst_amount, dst_data))
        {
            Inv_DB_Rollback();
            return false;
        }

        if (src_amount <= 0)
        {
            if (!Inv_DB_ClearSlot(from_container, from_slot))
            {
                Inv_DB_Rollback();
                return false;
            }
        }
        else
        {
            if (!Inv_DB_SetSlotItem(from_container, from_slot, src_item, src_amount, src_data))
            {
                Inv_DB_Rollback();
                return false;
            }
        }

        Inv_DB_Commit();
        return true;
    }

    if (dst_exists)
    {
        if (!Inv_DB_SetSlotItem(to_container, to_slot, src_item, src_amount, src_data))
        {
            Inv_DB_Rollback();
            return false;
        }
        if (!Inv_DB_SetSlotItem(from_container, from_slot, dst_item, dst_amount, dst_data))
        {
            Inv_DB_Rollback();
            return false;
        }
        Inv_DB_Commit();
        return true;
    }

    if (!Inv_DB_SetSlotItem(to_container, to_slot, src_item, src_amount, src_data))
    {
        Inv_DB_Rollback();
        return false;
    }
    if (!Inv_DB_ClearSlot(from_container, from_slot))
    {
        Inv_DB_Rollback();
        return false;
    }

    Inv_DB_Commit();
    return true;
}

stock Inv_FindItem(container_id, item_id, const data_filter[])
{
    if (gDB == DB:0) return -1;
    if (container_id <= 0) return -1;

    new q[192];
    format(q, sizeof q, "SELECT size FROM containers WHERE id=%d LIMIT 1;", container_id);
    new DBResult:r = DB_ExecuteQuery(gDB, q);
    if (r == DBResult:0) return -1;
    if (DB_GetRowCount(r) < 1) { DB_FreeResultSet(r); return -1; }
    new container_size = DB_GetFieldIntByName(r, "size");
    DB_FreeResultSet(r);

    for (new slot = 0; slot < container_size; slot++)
    {
        new sid, samount;
        new sdata[256];
        if (!Inv_DB_GetSlotItem(container_id, slot, sid, samount, sdata, sizeof sdata)) continue;
        if (sid != item_id) continue;
        if (data_filter[0] && strcmp(sdata, data_filter, false) != 0) continue;
        return slot;
    }
    return -1;
}

stock Inv_RefreshPlayerEquip(playerid)
{
    if (!IsPlayerConnected(playerid)) return 0;
    if (!gInvLoaded[playerid]) return 0;
    if (PlayerData[playerid][AccountId] <= 0) return 0;

    new equip_cid = gInvContainerId[playerid][INV_KIND_EQUIP];
    if (!equip_cid) return 0;

    // Armour effect
    new item_id, amount;
    new data[256];
    if (Inv_DB_GetSlotItem(equip_cid, INV_EQUIP_SLOT_ARMOR, item_id, amount, data, sizeof data) && item_id == ITEM_ARMOR)
        SetPlayerArmour(playerid, 100.0);
    else
        SetPlayerArmour(playerid, 0.0);

    // Backpack activation
    if (Inv_DB_GetSlotItem(equip_cid, INV_EQUIP_SLOT_BACKPACK, item_id, amount, data, sizeof data) && item_id == ITEM_BACKPACK)
    {
        new size = Inv_GetBackpackSizeFromData(data);
        gInvContainerSize[playerid][INV_KIND_BACKPACK] = size;

        new backpack_cid;
        if (Inv_DB_EnsureContainer(PlayerData[playerid][AccountId], INV_CONTAINER_TYPE_BACKPACK, size, backpack_cid))
        {
            gInvContainerId[playerid][INV_KIND_BACKPACK] = backpack_cid;
        }
    }
    else
    {
        // If there is no backpack equipped, remove empty backpack container.
        new backpack_cid;
        if (Inv_DB_GetContainerId(PlayerData[playerid][AccountId], INV_CONTAINER_TYPE_BACKPACK, backpack_cid))
        {
            if (Inv_DB_IsContainerEmpty(backpack_cid))
            {
                Inv_DB_DeleteContainer(backpack_cid);
            }
        }

        gInvContainerId[playerid][INV_KIND_BACKPACK] = 0;
        gInvContainerSize[playerid][INV_KIND_BACKPACK] = 0;
    }
    return 1;
}

stock bool:Inv_LoadPlayer(playerid)
{
    if (gDB == DB:0) return false;
    if (PlayerData[playerid][AccountId] <= 0) return false;

    gInvLoaded[playerid] = false;
    gInvContainerId[playerid][INV_KIND_POCKET] = 0;
    gInvContainerId[playerid][INV_KIND_EQUIP] = 0;
    gInvContainerId[playerid][INV_KIND_BACKPACK] = 0;

    gInvContainerSize[playerid][INV_KIND_POCKET] = INV_POCKET_SIZE;
    gInvContainerSize[playerid][INV_KIND_EQUIP] = INV_EQUIP_SIZE;
    gInvContainerSize[playerid][INV_KIND_BACKPACK] = 0;

    if (!Inv_DB_EnsureContainer(PlayerData[playerid][AccountId], INV_CONTAINER_TYPE_POCKET, INV_POCKET_SIZE, gInvContainerId[playerid][INV_KIND_POCKET])) return false;
    if (!Inv_DB_EnsureContainer(PlayerData[playerid][AccountId], INV_CONTAINER_TYPE_EQUIP, INV_EQUIP_SIZE, gInvContainerId[playerid][INV_KIND_EQUIP])) return false;

    gInvLoaded[playerid] = true;
    Inv_RefreshPlayerEquip(playerid);
    return true;
}

stock Inv_SavePlayer(playerid)
{
    #pragma unused playerid
    return 1;
}

stock Inv_UnloadPlayer(playerid)
{
    gInvLoaded[playerid] = false;
    gInvOpLock[playerid] = false;
    gInvContainerId[playerid][INV_KIND_POCKET] = 0;
    gInvContainerId[playerid][INV_KIND_EQUIP] = 0;
    gInvContainerId[playerid][INV_KIND_BACKPACK] = 0;
    gInvContainerSize[playerid][INV_KIND_BACKPACK] = 0;
    gInvListCount[playerid] = 0;
    gInvSelKind[playerid] = -1;
    gInvSelSlot[playerid] = -1;
    gInvMoveTargetKind[playerid] = -1;
    gInvGiveCount[playerid] = 0;
    gInvGiveTarget[playerid] = INVALID_PLAYER_ID;
    return 1;
}

stock bool:Inv_MoveItemPlayer(playerid, from_kind, from_slot, to_kind, to_slot)
{
    if (!Inv_IsPlayerReady(playerid)) return false;
    if (!Inv_IsValidKind(from_kind) || !Inv_IsValidKind(to_kind)) return false;
    if (from_slot < 0 || to_slot < 0) return false;

    new from_size = Inv_GetKindSize(playerid, from_kind);
    new to_size = Inv_GetKindSize(playerid, to_kind);
    if (from_size <= 0 || to_size <= 0) return false;
    if (from_slot >= from_size || to_slot >= to_size) return false;

    if (!Inv_Lock(playerid)) return false;

    new from_cid = gInvContainerId[playerid][from_kind];
    new to_cid = gInvContainerId[playerid][to_kind];
    if (!from_cid || !to_cid)
    {
        Inv_Unlock(playerid);
        return false;
    }

    new src_item, src_amount;
    new src_data[256];
    if (!Inv_DB_GetSlotItem(from_cid, from_slot, src_item, src_amount, src_data, sizeof src_data))
    {
        Inv_Unlock(playerid);
        return false;
    }

    if (!Inv_ValidateMoveTo(playerid, to_kind, to_slot, src_item))
    {
        Inv_Unlock(playerid);
        return false;
    }

    // If swapping, ensure the destination item can go into the source slot.
    new dst_item, dst_amount;
    new dst_data[256];
    new bool:dst_exists = Inv_DB_GetSlotItem(to_cid, to_slot, dst_item, dst_amount, dst_data, sizeof dst_data);
    if (dst_exists && !Inv_ValidateMoveTo(playerid, from_kind, from_slot, dst_item))
    {
        Inv_Unlock(playerid);
        return false;
    }

    // Prevent swapping out equipped backpack if backpack container isn't empty.
    if (dst_exists && to_kind == INV_KIND_EQUIP && to_slot == INV_EQUIP_SLOT_BACKPACK && dst_item == ITEM_BACKPACK)
    {
        new backpack_cid = gInvContainerId[playerid][INV_KIND_BACKPACK];
        if (backpack_cid && !Inv_DB_IsContainerEmpty(backpack_cid))
        {
            Inv_Unlock(playerid);
            return false;
        }
    }

    // If equipping backpack, ensure existing backpack container fits (no item loss).
    if (to_kind == INV_KIND_EQUIP && to_slot == INV_EQUIP_SLOT_BACKPACK && src_item == ITEM_BACKPACK)
    {
        new new_size = Inv_GetBackpackSizeFromData(src_data);
        new backpack_cid = gInvContainerId[playerid][INV_KIND_BACKPACK];
        if (backpack_cid && !Inv_DB_IsContainerEmpty(backpack_cid))
        {
            new max_slot;
            if (Inv_DB_GetMaxSlot(backpack_cid, max_slot))
            {
                if (max_slot >= new_size)
                {
                    Inv_Unlock(playerid);
                    return false;
                }
            }
        }
    }

    // Cannot unequip backpack if backpack container isn't empty.
    if (from_kind == INV_KIND_EQUIP && from_slot == INV_EQUIP_SLOT_BACKPACK && src_item == ITEM_BACKPACK)
    {
        new backpack_cid = gInvContainerId[playerid][INV_KIND_BACKPACK];
        if (backpack_cid && !Inv_DB_IsContainerEmpty(backpack_cid))
        {
            Inv_Unlock(playerid);
            return false;
        }
    }

    new ok = Inv_MoveItem(from_cid, from_slot, to_cid, to_slot);
    Inv_Unlock(playerid);
    if (!ok) return false;

    // If backpack unequipped, delete container row (must be empty).
    if (from_kind == INV_KIND_EQUIP && from_slot == INV_EQUIP_SLOT_BACKPACK && src_item == ITEM_BACKPACK)
    {
        new backpack_cid = gInvContainerId[playerid][INV_KIND_BACKPACK];
        if (backpack_cid && Inv_DB_IsContainerEmpty(backpack_cid))
        {
            Inv_DB_DeleteContainer(backpack_cid);
        }
    }

    Inv_RefreshPlayerEquip(playerid);
    // Log unique moves (equip/unequip, swap, etc.).
    new bool:stackable, max_stack, bool:unique, equip_slot, bool:usable;
    Inv_ItemDef(src_item, stackable, max_stack, unique, equip_slot, usable);
    if (unique)
    {
        new logline[128];
        format(logline, sizeof logline, "move unique item=%d from_kind=%d slot=%d to_kind=%d slot=%d", src_item, from_kind, from_slot, to_kind, to_slot);
        Inv_LogLine(logline);
    }
    return true;
}

stock bool:Inv_UseSlot(playerid, kind, slot)
{
    if (!Inv_IsPlayerReady(playerid)) return false;
    if (!Inv_IsValidKind(kind)) return false;

    new kind_size = Inv_GetKindSize(playerid, kind);
    if (slot < 0 || slot >= kind_size) return false;

    if (!Inv_Lock(playerid)) return false;

    new cid = gInvContainerId[playerid][kind];
    if (!cid) { Inv_Unlock(playerid); return false; }

    new item_id, amount;
    new data[256];
    if (!Inv_DB_GetSlotItem(cid, slot, item_id, amount, data, sizeof data))
    {
        Inv_Unlock(playerid);
        return false;
    }

    new bool:stackable, max_stack, bool:unique, equip_slot, bool:usable;
    Inv_ItemDef(item_id, stackable, max_stack, unique, equip_slot, usable);
    if (!usable)
    {
        Inv_Unlock(playerid);
        return false;
    }

    if (item_id == ITEM_WATER || item_id == ITEM_FOOD)
    {
        new Float:hp;
        GetPlayerHealth(playerid, hp);
        hp += 10.0;
        if (hp > 100.0) hp = 100.0;
        SetPlayerHealth(playerid, hp);
        Inv_Unlock(playerid);
        new logline[192];
        format(logline, sizeof logline, "use player=%d item=%d amount=1", playerid, item_id);
        Inv_LogLine(logline);
        return Inv_RemoveItem(cid, slot, 1);
    }

    if (item_id == ITEM_MEDKIT)
    {
        SetPlayerHealth(playerid, 100.0);
        Inv_Unlock(playerid);
        new logline[192];
        format(logline, sizeof logline, "use player=%d item=%d amount=1", playerid, item_id);
        Inv_LogLine(logline);
        return Inv_RemoveItem(cid, slot, 1);
    }

    if (item_id == ITEM_ARMOR)
    {
        Inv_Unlock(playerid);
        return Inv_MoveItemPlayer(playerid, kind, slot, INV_KIND_EQUIP, INV_EQUIP_SLOT_ARMOR);
    }

    if (item_id == ITEM_BACKPACK)
    {
        Inv_Unlock(playerid);
        return Inv_MoveItemPlayer(playerid, kind, slot, INV_KIND_EQUIP, INV_EQUIP_SLOT_BACKPACK);
    }

    if (item_id == ITEM_PLATE)
    {
        Inv_Unlock(playerid);
        SendClientMessage(playerid, -1, "[INV] Номерной знак: заглушка (логика будет позже).");
        return true;
    }

    if (item_id == ITEM_BLUEPRINT)
    {
        Inv_Unlock(playerid);
        SendClientMessage(playerid, -1, "[INV] Чертёж: заглушка (логика будет позже).");
        return true;
    }

    Inv_Unlock(playerid);
    return false;
}

stock Inv_DebugPrintContainer(playerid, kind)
{
    if (!Inv_IsPlayerReady(playerid)) return 0;

    new cid = gInvContainerId[playerid][kind];
    if (!cid)
    {
        SendClientMessage(playerid, -1, "[INV] Контейнер недоступен.");
        return 1;
    }

    new size = gInvContainerSize[playerid][kind];
    new header[96];
    switch (kind)
    {
        case INV_KIND_POCKET: format(header, sizeof header, "[INV] Карман (%d слотов)", size);
        case INV_KIND_EQUIP: format(header, sizeof header, "[INV] Экипировка (%d слотов)", size);
        case INV_KIND_BACKPACK: format(header, sizeof header, "[INV] Рюкзак (%d слотов)", size);
    }
    SendClientMessage(playerid, -1, header);

    new msg[192];
    for (new slot = 0; slot < size; slot++)
    {
        new item_id, amount;
        new data[256];
        if (!Inv_DB_GetSlotItem(cid, slot, item_id, amount, data, sizeof data)) continue;
        format(msg, sizeof msg, "[INV] Слот %d: предмет=%d кол-во=%d данные=%s", slot, item_id, amount, data);
        SendClientMessage(playerid, -1, msg);
    }
    return 1;
}

stock Inv_OpenMainDialog(playerid)
{
    if (!Inv_IsPlayerReady(playerid)) return 0;

    gInvListCount[playerid] = 0;

    new list[2048];
    list[0] = '\0';

    Inv_ListAddItem(playerid, -1, -1, list, sizeof list, "== Карман ==");
    for (new slot = 0; slot < INV_POCKET_SIZE; slot++)
    {
        new item_id, amount;
        new data[256];
        if (Inv_DB_GetSlotItem(gInvContainerId[playerid][INV_KIND_POCKET], slot, item_id, amount, data, sizeof data))
        {
            new name[32];
            Inv_GetItemName(item_id, name, sizeof name);
            format(data, sizeof data, "Слот %d: %s x%d", slot, name, amount);
            Inv_ListAddItem(playerid, INV_KIND_POCKET, slot, list, sizeof list, data);
        }
        else
        {
            new line[64];
            format(line, sizeof line, "Слот %d: пусто", slot);
            Inv_ListAddItem(playerid, INV_KIND_POCKET, slot, list, sizeof list, line);
        }
    }

    Inv_ListAddItem(playerid, -1, -1, list, sizeof list, "== Экипировка ==");
    for (new slot = 0; slot < INV_EQUIP_SIZE; slot++)
    {
        new item_id, amount;
        new data[256];
        new slot_name[16];
        if (slot == INV_EQUIP_SLOT_ARMOR) format(slot_name, sizeof slot_name, "Броня");
        else format(slot_name, sizeof slot_name, "Рюкзак");

        if (Inv_DB_GetSlotItem(gInvContainerId[playerid][INV_KIND_EQUIP], slot, item_id, amount, data, sizeof data))
        {
            new name[32];
            Inv_GetItemName(item_id, name, sizeof name);
            format(data, sizeof data, "Слот %d (%s): %s x%d", slot, slot_name, name, amount);
            Inv_ListAddItem(playerid, INV_KIND_EQUIP, slot, list, sizeof list, data);
        }
        else
        {
            new line[80];
            format(line, sizeof line, "Слот %d (%s): пусто", slot, slot_name);
            Inv_ListAddItem(playerid, INV_KIND_EQUIP, slot, list, sizeof list, line);
        }
    }

    if (gInvContainerId[playerid][INV_KIND_BACKPACK])
    {
        new size = gInvContainerSize[playerid][INV_KIND_BACKPACK];
        Inv_ListAddItem(playerid, -1, -1, list, sizeof list, "== Рюкзак ==");
        for (new slot = 0; slot < size; slot++)
        {
            new item_id, amount;
            new data[256];
            if (Inv_DB_GetSlotItem(gInvContainerId[playerid][INV_KIND_BACKPACK], slot, item_id, amount, data, sizeof data))
            {
                new name[32];
                Inv_GetItemName(item_id, name, sizeof name);
                format(data, sizeof data, "Слот %d: %s x%d", slot, name, amount);
                Inv_ListAddItem(playerid, INV_KIND_BACKPACK, slot, list, sizeof list, data);
            }
            else
            {
                new line[64];
                format(line, sizeof line, "Слот %d: пусто", slot);
                Inv_ListAddItem(playerid, INV_KIND_BACKPACK, slot, list, sizeof list, line);
            }
        }
    }

    ShowPlayerDialog(playerid, DIALOG_INV_MAIN, DIALOG_STYLE_LIST, "Инвентарь", list, "Выбрать", "Закрыть");
    return 1;
}

stock Inv_OpenActionDialog(playerid)
{
    new list[256];
    format(list, sizeof list, "Использовать\nПереместить (авто)\nПереместить в...\nВыбросить\nПередать\nИнфо\nНазад");
    ShowPlayerDialog(playerid, DIALOG_INV_ACTION, DIALOG_STYLE_LIST, "Действия", list, "Выбрать", "Назад");
    return 1;
}

stock Inv_OpenMoveContainerDialog(playerid)
{
    new list[256];
    format(list, sizeof list, "Карман\nЭкипировка\nРюкзак");
    ShowPlayerDialog(playerid, DIALOG_INV_MOVE_CONTAINER, DIALOG_STYLE_LIST, "Куда переместить", list, "Выбрать", "Назад");
    return 1;
}

stock Inv_OpenMoveSlotDialog(playerid, kind)
{
    new list[512];
    list[0] = '\0';

    if (kind == INV_KIND_POCKET)
    {
        for (new slot = 0; slot < INV_POCKET_SIZE; slot++)
        {
            new line[64];
            format(line, sizeof line, "Слот %d", slot);
            if (list[0]) strcat(list, "\n", sizeof list);
            strcat(list, line, sizeof list);
        }
    }
    else if (kind == INV_KIND_EQUIP)
    {
        format(list, sizeof list, "Слот 0 (Броня)\nСлот 1 (Рюкзак)");
    }
    else if (kind == INV_KIND_BACKPACK)
    {
        new size = gInvContainerSize[playerid][INV_KIND_BACKPACK];
        for (new slot = 0; slot < size; slot++)
        {
            new line[64];
            format(line, sizeof line, "Слот %d", slot);
            if (list[0]) strcat(list, "\n", sizeof list);
            strcat(list, line, sizeof list);
        }
    }

    ShowPlayerDialog(playerid, DIALOG_INV_MOVE_SLOT, DIALOG_STYLE_LIST, "Выбор слота", list, "Выбрать", "Назад");
    return 1;
}

stock Inv_OpenDropAmountDialog(playerid)
{
    ShowPlayerDialog(playerid, DIALOG_INV_DROP_AMOUNT, DIALOG_STYLE_INPUT, "Удаление", "Введите количество:", "Ок", "Назад");
    return 1;
}

stock Inv_BuildGiveList(playerid)
{
    gInvGiveCount[playerid] = 0;
    new list[512];
    list[0] = '\0';

    new Float:x1, Float:y1, Float:z1;
    GetPlayerPos(playerid, x1, y1, z1);

    for (new i = 0; i < MAX_PLAYERS; i++)
    {
        if (!IsPlayerConnected(i)) continue;
        if (i == playerid) continue;

        new Float:x2, Float:y2, Float:z2;
        GetPlayerPos(i, x2, y2, z2);
        new Float:dx = x1 - x2;
        new Float:dy = y1 - y2;
        new Float:dz = z1 - z2;
        if ((dx * dx + dy * dy + dz * dz) > 9.0) continue;

        new name[MAX_PLAYER_NAME];
        GetPlayerName(i, name, sizeof name);
        if (list[0]) strcat(list, "\n", sizeof list);
        strcat(list, name, sizeof list);
        gInvGiveList[playerid][gInvGiveCount[playerid]] = i;
        gInvGiveCount[playerid]++;
        if (gInvGiveCount[playerid] >= MAX_PLAYERS) break;
    }

    if (list[0]) strcat(list, "\n", sizeof list);
    strcat(list, "Ввести ID", sizeof list);
    gInvGiveList[playerid][gInvGiveCount[playerid]] = INVALID_PLAYER_ID;
    gInvGiveCount[playerid]++;

    ShowPlayerDialog(playerid, DIALOG_INV_GIVE_LIST, DIALOG_STYLE_LIST, "Кому передать", list, "Выбрать", "Назад");
    return 1;
}

stock Inv_OpenGiveIdDialog(playerid)
{
    ShowPlayerDialog(playerid, DIALOG_INV_GIVE_ID, DIALOG_STYLE_INPUT, "Передача", "Введите ID игрока:", "Ок", "Назад");
    return 1;
}

stock Inv_OpenGiveAmountDialog(playerid)
{
    ShowPlayerDialog(playerid, DIALOG_INV_GIVE_AMOUNT, DIALOG_STYLE_INPUT, "Передача", "Введите количество:", "Ок", "Назад");
    return 1;
}

stock Inv_OpenInfoDialog(playerid)
{
    new kind = gInvSelKind[playerid];
    new slot = gInvSelSlot[playerid];

    new cid = gInvContainerId[playerid][kind];
    if (!cid) return 0;

    new item_id, amount;
    new data[256];
    if (!Inv_DB_GetSlotItem(cid, slot, item_id, amount, data, sizeof data)) return 0;

    new name[32];
    Inv_GetItemName(item_id, name, sizeof name);

    new kind_name[16];
    if (kind == INV_KIND_POCKET) format(kind_name, sizeof kind_name, "Карман");
    else if (kind == INV_KIND_EQUIP) format(kind_name, sizeof kind_name, "Экипировка");
    else format(kind_name, sizeof kind_name, "Рюкзак");

    new msg[256];
    format(msg, sizeof msg, "Предмет: %s\nID: %d\nКол-во: %d\nКонтейнер: %s\nСлот: %d\nДанные: %s",
        name, item_id, amount, kind_name, slot, data);
    ShowPlayerDialog(playerid, DIALOG_INV_INFO, DIALOG_STYLE_MSGBOX, "Информация", msg, "Ок", "");
    return 1;
}

stock bool:Inv_DB_AddItemToContainerTx(container_id, container_size, item_id, &amount, const data[])
{
    new bool:stackable, max_stack, bool:unique, equip_slot, bool:usable;
    Inv_ItemDef(item_id, stackable, max_stack, unique, equip_slot, usable);

    if (unique) amount = 1;
    if (amount <= 0) return false;

    if (stackable)
    {
        for (new slot = 0; slot < container_size; slot++)
        {
            new sid, samount;
            new sdata[256];
            if (!Inv_DB_GetSlotItem(container_id, slot, sid, samount, sdata, sizeof sdata)) continue;
            if (sid != item_id) continue;
            if (strcmp(sdata, data, false) != 0) continue;
            if (samount >= max_stack) continue;

            new can_add = max_stack - samount;
            new add_now = (amount > can_add) ? can_add : amount;
            samount += add_now;
            amount -= add_now;

            if (!Inv_DB_SetSlotItem(container_id, slot, sid, samount, sdata)) return false;
            if (amount <= 0) return true;
        }
    }

    for (new slot = 0; slot < container_size; slot++)
    {
        new sid, samount;
        new tmp[4];
        if (Inv_DB_GetSlotItem(container_id, slot, sid, samount, tmp, sizeof tmp)) continue;

        new put_amount = amount;
        if (stackable && put_amount > max_stack) put_amount = max_stack;
        if (unique) put_amount = 1;

        if (!Inv_DB_SetSlotItem(container_id, slot, item_id, put_amount, data)) return false;
        amount -= put_amount;
        if (amount <= 0) return true;
    }

    return false;
}

stock bool:Inv_GiveItem(playerid, targetid, from_kind, from_slot, amount)
{
    if (!Inv_IsPlayerReady(playerid)) return false;
    if (!Inv_IsPlayerReady(targetid)) return false;
    if (playerid == targetid) return false;
    if (!Inv_IsValidKind(from_kind)) return false;
    if (from_slot < 0) return false;
    if (from_slot >= Inv_GetKindSize(playerid, from_kind)) return false;

    new Float:x1, Float:y1, Float:z1;
    new Float:x2, Float:y2, Float:z2;
    GetPlayerPos(playerid, x1, y1, z1);
    GetPlayerPos(targetid, x2, y2, z2);
    new Float:dx = x1 - x2;
    new Float:dy = y1 - y2;
    new Float:dz = z1 - z2;
    if ((dx * dx + dy * dy + dz * dz) > 9.0) return false;

    new first = (playerid < targetid) ? playerid : targetid;
    new second = (playerid < targetid) ? targetid : playerid;
    if (!Inv_Lock(first)) return false;
    if (!Inv_Lock(second)) { Inv_Unlock(first); return false; }

    new from_cid = gInvContainerId[playerid][from_kind];
    new to_cid = gInvContainerId[targetid][INV_KIND_POCKET];
    if (!from_cid || !to_cid)
    {
        Inv_Unlock(second);
        Inv_Unlock(first);
        return false;
    }

    new item_id, cur_amount;
    new data[256];
    if (!Inv_DB_GetSlotItem(from_cid, from_slot, item_id, cur_amount, data, sizeof data))
    {
        Inv_Unlock(second);
        Inv_Unlock(first);
        return false;
    }

    new bool:stackable, max_stack, bool:unique, equip_slot, bool:usable;
    Inv_ItemDef(item_id, stackable, max_stack, unique, equip_slot, usable);

    if (unique) amount = 1;
    if (amount <= 0) amount = 1;
    if (amount > cur_amount) amount = cur_amount;

    if (!Inv_DB_Begin())
    {
        Inv_Unlock(second);
        Inv_Unlock(first);
        return false;
    }

    new give_amount = amount;
    if (!Inv_DB_AddItemToContainerTx(to_cid, INV_POCKET_SIZE, item_id, give_amount, data))
    {
        Inv_DB_Rollback();
        Inv_Unlock(second);
        Inv_Unlock(first);
        return false;
    }

    new left = cur_amount - amount;
    if (left <= 0)
    {
        if (!Inv_DB_ClearSlot(from_cid, from_slot))
        {
            Inv_DB_Rollback();
            Inv_Unlock(second);
            Inv_Unlock(first);
            return false;
        }
    }
    else
    {
        if (!Inv_DB_SetSlotItem(from_cid, from_slot, item_id, left, data))
        {
            Inv_DB_Rollback();
            Inv_Unlock(second);
            Inv_Unlock(first);
            return false;
        }
    }

    Inv_DB_Commit();

    Inv_Unlock(second);
    Inv_Unlock(first);

    Inv_RefreshPlayerEquip(playerid);
    Inv_RefreshPlayerEquip(targetid);

    new logline[192];
    if (unique)
        format(logline, sizeof logline, "give unique %d -> %d item=%d amount=%d data=%s", playerid, targetid, item_id, amount, data);
    else
        format(logline, sizeof logline, "give %d -> %d item=%d amount=%d", playerid, targetid, item_id, amount);
    Inv_LogLine(logline);
    return true;
}

// -------------------- MVP commands --------------------
stock Inv_SendHelp(playerid)
{
    SendClientMessage(playerid, -1, "-------- Инвентарь: помощь --------");
    SendClientMessage(playerid, -1, "/inv - показать инвентарь");
    SendClientMessage(playerid, -1, "/inv help - список команд");
    SendClientMessage(playerid, -1, "/invadd [id_предмета] [кол-во] [JSON-данные опц.]");
    SendClientMessage(playerid, -1, "/invmv [контейнер 0/1/2] [слот] [контейнер 0/1/2] [слот]");
    SendClientMessage(playerid, -1, "/invuse [контейнер 0/1/2] [слот] (если без контейнера, то карман)");
    SendClientMessage(playerid, -1, "/invdrop [контейнер 0/1/2] [слот] [кол-во опц.] (если без контейнера, то карман)");
    SendClientMessage(playerid, -1, "/invgive [id_игрока] [контейнер 0/1/2] [слот] [кол-во опц.]");
    SendClientMessage(playerid, -1, "--------------------");
    return 1;
}

stock bool:Inv_OnDialogResponse(playerid, dialogid, response, listitem, const inputtext[])
{
    if (!Inv_IsPlayerReady(playerid)) return false;

    if (dialogid == DIALOG_INV_MAIN)
    {
        if (!response) return true;
        if (listitem < 0 || listitem >= gInvListCount[playerid]) return true;

        new kind = gInvListKind[playerid][listitem];
        new slot = gInvListSlot[playerid][listitem];
        if (kind < 0)
        {
            Inv_OpenMainDialog(playerid);
            return true;
        }

        new cid = gInvContainerId[playerid][kind];
        if (!cid)
        {
            SendClientMessage(playerid, -1, "[INV] Контейнер недоступен.");
            return true;
        }

        new item_id, amount;
        new data[256];
        if (!Inv_DB_GetSlotItem(cid, slot, item_id, amount, data, sizeof data))
        {
            SendClientMessage(playerid, -1, "[INV] Слот пуст.");
            return true;
        }

        gInvSelKind[playerid] = kind;
        gInvSelSlot[playerid] = slot;
        Inv_OpenActionDialog(playerid);
        return true;
    }

    if (dialogid == DIALOG_INV_ACTION)
    {
        if (!response)
        {
            Inv_OpenMainDialog(playerid);
            return true;
        }

        switch (listitem)
        {
            case 0:
            {
                if (!Inv_UseSlot(playerid, gInvSelKind[playerid], gInvSelSlot[playerid]))
                    SendClientMessage(playerid, -1, "[INV] Нельзя использовать.");
                Inv_OpenMainDialog(playerid);
            }
            case 1:
            {
                if (!Inv_MoveAuto(playerid, gInvSelKind[playerid], gInvSelSlot[playerid]))
                    SendClientMessage(playerid, -1, "[INV] Нельзя переместить.");
                Inv_OpenMainDialog(playerid);
            }
            case 2:
            {
                Inv_OpenMoveContainerDialog(playerid);
            }
            case 3:
            {
                Inv_OpenDropAmountDialog(playerid);
            }
            case 4:
            {
                Inv_BuildGiveList(playerid);
            }
            case 5:
            {
                Inv_OpenInfoDialog(playerid);
            }
            default:
            {
                Inv_OpenMainDialog(playerid);
            }
        }
        return true;
    }

    if (dialogid == DIALOG_INV_MOVE_CONTAINER)
    {
        if (!response) { Inv_OpenActionDialog(playerid); return true; }

        new target_kind = listitem;
        if (target_kind == INV_KIND_BACKPACK && !gInvContainerId[playerid][INV_KIND_BACKPACK])
        {
            SendClientMessage(playerid, -1, "[INV] Рюкзак недоступен.");
            Inv_OpenActionDialog(playerid);
            return true;
        }
        gInvMoveTargetKind[playerid] = target_kind;
        Inv_OpenMoveSlotDialog(playerid, target_kind);
        return true;
    }

    if (dialogid == DIALOG_INV_MOVE_SLOT)
    {
        if (!response) { Inv_OpenActionDialog(playerid); return true; }

        new target_kind = gInvMoveTargetKind[playerid];
        if (!Inv_IsValidKind(target_kind)) { Inv_OpenActionDialog(playerid); return true; }

        if (!Inv_MoveItemPlayer(playerid, gInvSelKind[playerid], gInvSelSlot[playerid], target_kind, listitem))
        {
            SendClientMessage(playerid, -1, "[INV] Нельзя переместить.");
        }
        Inv_OpenMainDialog(playerid);
        return true;
    }

    if (dialogid == DIALOG_INV_DROP_AMOUNT)
    {
        if (!response) { Inv_OpenActionDialog(playerid); return true; }

        new amount = 1;
        if (inputtext[0]) amount = strval(inputtext);
        if (amount <= 0) amount = 1;

        new kind = gInvSelKind[playerid];
        new slot = gInvSelSlot[playerid];
        new cid = gInvContainerId[playerid][kind];
        if (!cid) { SendClientMessage(playerid, -1, "[INV] Нельзя удалить."); return true; }

        new item_id, cur_amount;
        new data[256];
        if (!Inv_DB_GetSlotItem(cid, slot, item_id, cur_amount, data, sizeof data))
        {
            SendClientMessage(playerid, -1, "[INV] Нельзя удалить.");
            return true;
        }
        if (kind == INV_KIND_EQUIP && slot == INV_EQUIP_SLOT_BACKPACK && item_id == ITEM_BACKPACK)
        {
            new backpack_cid = gInvContainerId[playerid][INV_KIND_BACKPACK];
            if (backpack_cid && !Inv_DB_IsContainerEmpty(backpack_cid))
            {
                SendClientMessage(playerid, -1, "[INV] Рюкзак не пуст.");
                return true;
            }
        }

        if (!Inv_RemoveItem(cid, slot, amount))
        {
            SendClientMessage(playerid, -1, "[INV] Нельзя удалить.");
            return true;
        }
        if (kind == INV_KIND_EQUIP) Inv_RefreshPlayerEquip(playerid);
        SendClientMessage(playerid, -1, "[INV] Удалено.");
        Inv_OpenMainDialog(playerid);
        return true;
    }

    if (dialogid == DIALOG_INV_GIVE_LIST)
    {
        if (!response) { Inv_OpenActionDialog(playerid); return true; }

        if (listitem < 0 || listitem >= gInvGiveCount[playerid]) { Inv_OpenActionDialog(playerid); return true; }
        new targetid = gInvGiveList[playerid][listitem];
        if (targetid == INVALID_PLAYER_ID)
        {
            Inv_OpenGiveIdDialog(playerid);
            return true;
        }
        gInvGiveTarget[playerid] = targetid;
        Inv_OpenGiveAmountDialog(playerid);
        return true;
    }

    if (dialogid == DIALOG_INV_GIVE_ID)
    {
        if (!response) { Inv_OpenActionDialog(playerid); return true; }
        new targetid = strval(inputtext);
        if (!IsPlayerConnected(targetid))
        {
            SendClientMessage(playerid, -1, "[INV] Игрок не найден.");
            return true;
        }
        gInvGiveTarget[playerid] = targetid;
        Inv_OpenGiveAmountDialog(playerid);
        return true;
    }

    if (dialogid == DIALOG_INV_GIVE_AMOUNT)
    {
        if (!response) { Inv_OpenActionDialog(playerid); return true; }
        new amount = 1;
        if (inputtext[0]) amount = strval(inputtext);
        if (amount <= 0) amount = 1;

        if (!Inv_GiveItem(playerid, gInvGiveTarget[playerid], gInvSelKind[playerid], gInvSelSlot[playerid], amount))
        {
            SendClientMessage(playerid, -1, "[INV] Нельзя передать (дистанция/место/ошибка).");
            return true;
        }
        SendClientMessage(playerid, -1, "[INV] Передано.");
        Inv_OpenMainDialog(playerid);
        return true;
    }

    if (dialogid == DIALOG_INV_INFO)
    {
        Inv_OpenActionDialog(playerid);
        return true;
    }

    return false;
}

stock cmd_inv(playerid, const params[])
{
    if (!Inv_IsPlayerReady(playerid)) { SendClientMessage(playerid, -1, "[INV] Доступно после логина."); return 1; }
    if (params[0])
    {
        if (!strcmp(params, "help", true) || !strcmp(params, "?", true))
        {
            return Inv_SendHelp(playerid);
        }
    }
    return Inv_OpenMainDialog(playerid);
}

stock cmd_invadd(playerid, const params[])
{
    if (!Inv_IsPlayerReady(playerid)) { SendClientMessage(playerid, -1, "[INV] Доступно после логина."); return 1; }

    new item_id, amount;
    new data[256];
    data[0] = '\0';

    if (sscanf(params, "iiS()[256]", item_id, amount, data) != 0)
    {
        SendClientMessage(playerid, -1, "Использование: /invadd [id_предмета] [кол-во] [JSON-данные опц.]");
        return 1;
    }

    if (!data[0])
    {
        if (item_id == ITEM_BACKPACK) format(data, sizeof data, "{\"size\":20}");
        else format(data, sizeof data, "{}");
    }

    if (!Inv_AddItem(gInvContainerId[playerid][INV_KIND_POCKET], item_id, amount, data))
    {
        SendClientMessage(playerid, -1, "[INV] Нет места/ошибка.");
        return 1;
    }

    SendClientMessage(playerid, -1, "[INV] Добавлено.");
    return 1;
}

stock cmd_invmv(playerid, const params[])
{
    if (!Inv_IsPlayerReady(playerid)) { SendClientMessage(playerid, -1, "[INV] Доступно после логина."); return 1; }
    new from_kind, from_slot, to_kind, to_slot;
    if (sscanf(params, "iiii", from_kind, from_slot, to_kind, to_slot) != 0)
    {
        SendClientMessage(playerid, -1, "Использование: /invmv [контейнер 0/1/2] [слот] [контейнер 0/1/2] [слот]");
        return 1;
    }
    if (!Inv_MoveItemPlayer(playerid, from_kind, from_slot, to_kind, to_slot))
    {
        SendClientMessage(playerid, -1, "[INV] Нельзя переместить.");
        return 1;
    }
    SendClientMessage(playerid, -1, "[INV] Готово.");
    return 1;
}

stock cmd_invuse(playerid, const params[])
{
    if (!Inv_IsPlayerReady(playerid)) { SendClientMessage(playerid, -1, "[INV] Доступно после логина."); return 1; }
    new kind, slot;
    if (sscanf(params, "ii", kind, slot) != 0)
    {
        if (sscanf(params, "i", slot) != 0)
        {
            SendClientMessage(playerid, -1, "Использование: /invuse [контейнер 0/1/2] [слот]");
            return 1;
        }
        kind = INV_KIND_POCKET;
    }
    if (!Inv_IsValidKind(kind))
    {
        SendClientMessage(playerid, -1, "[INV] Неверный контейнер.");
        return 1;
    }
    if (!Inv_UseSlot(playerid, kind, slot))
    {
        SendClientMessage(playerid, -1, "[INV] Нельзя использовать.");
        return 1;
    }
    SendClientMessage(playerid, -1, "[INV] Использовано.");
    return 1;
}

stock cmd_invdrop(playerid, const params[])
{
    if (!Inv_IsPlayerReady(playerid)) { SendClientMessage(playerid, -1, "[INV] Доступно после логина."); return 1; }
    new kind, slot, amount = 1;
    if (sscanf(params, "iiI(1)", kind, slot, amount) != 0)
    {
        if (sscanf(params, "iI(1)", slot, amount) != 0)
        {
            SendClientMessage(playerid, -1, "Использование: /invdrop [контейнер 0/1/2] [слот] [кол-во опц.]");
            return 1;
        }
        kind = INV_KIND_POCKET;
    }
    if (!Inv_IsValidKind(kind))
    {
        SendClientMessage(playerid, -1, "[INV] Неверный контейнер.");
        return 1;
    }
    new size = Inv_GetKindSize(playerid, kind);
    if (slot < 0 || slot >= size)
    {
        SendClientMessage(playerid, -1, "[INV] Неверный слот.");
        return 1;
    }
    new cid = gInvContainerId[playerid][kind];
    if (!cid) { SendClientMessage(playerid, -1, "[INV] Нельзя удалить."); return 1; }

    new item_id, cur_amount;
    new data[256];
    if (!Inv_DB_GetSlotItem(cid, slot, item_id, cur_amount, data, sizeof data))
    {
        SendClientMessage(playerid, -1, "[INV] Нельзя удалить.");
        return 1;
    }
    if (kind == INV_KIND_EQUIP && slot == INV_EQUIP_SLOT_BACKPACK && item_id == ITEM_BACKPACK)
    {
        new backpack_cid = gInvContainerId[playerid][INV_KIND_BACKPACK];
        if (backpack_cid && !Inv_DB_IsContainerEmpty(backpack_cid))
        {
            SendClientMessage(playerid, -1, "[INV] Рюкзак не пуст.");
            return 1;
        }
    }

    if (!Inv_RemoveItem(cid, slot, amount))
    {
        SendClientMessage(playerid, -1, "[INV] Нельзя удалить.");
        return 1;
    }
    new bool:stackable, max_stack, bool:unique, equip_slot, bool:usable;
    Inv_ItemDef(item_id, stackable, max_stack, unique, equip_slot, usable);

    new logline[192];
    if (unique)
        format(logline, sizeof logline, "drop unique player=%d item=%d amount=%d data=%s", playerid, item_id, amount, data);
    else
        format(logline, sizeof logline, "drop player=%d kind=%d slot=%d amount=%d", playerid, kind, slot, amount);
    Inv_LogLine(logline);
    if (kind == INV_KIND_EQUIP) Inv_RefreshPlayerEquip(playerid);
    SendClientMessage(playerid, -1, "[INV] Удалено.");
    return 1;
}

stock cmd_invhelp(playerid, const params[])
{
    #pragma unused params
    if (!Inv_IsPlayerReady(playerid)) { SendClientMessage(playerid, -1, "[INV] Доступно после логина."); return 1; }
    return Inv_SendHelp(playerid);
}

stock cmd_invgive(playerid, const params[])
{
    if (!Inv_IsPlayerReady(playerid)) { SendClientMessage(playerid, -1, "[INV] Доступно после логина."); return 1; }
    new targetid, kind, slot, amount = 1;
    if (sscanf(params, "iiiI(1)", targetid, kind, slot, amount) != 0)
    {
        SendClientMessage(playerid, -1, "Использование: /invgive [id_игрока] [контейнер 0/1/2] [слот] [кол-во опц.]");
        return 1;
    }
    if (!IsPlayerConnected(targetid))
    {
        SendClientMessage(playerid, -1, "[INV] Игрок не найден.");
        return 1;
    }
    if (!Inv_GiveItem(playerid, targetid, kind, slot, amount))
    {
        SendClientMessage(playerid, -1, "[INV] Нельзя передать (дистанция/место/ошибка).");
        return 1;
    }
    SendClientMessage(playerid, -1, "[INV] Передано.");
    return 1;
}
