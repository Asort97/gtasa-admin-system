// ==========================================
// Inventory System (MVP, DB-first, UI-agnostic)
// ==========================================
// Source of truth is SQLite. All operations persist immediately.
// owner_id uses accounts.id (INTEGER).

#define INV_CONTAINER_TYPE_POCKET   "player_pocket"
#define INV_CONTAINER_TYPE_EQUIP    "player_equip"
#define INV_CONTAINER_TYPE_BACKPACK "player_backpack"

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

stock Inv_LogLine(const text[])
{
    printf("[INV] %s", text);
    return 1;
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
        SendClientMessage(playerid, -1, "[INV] container not available");
        return 1;
    }

    new size = gInvContainerSize[playerid][kind];
    new header[96];
    switch (kind)
    {
        case INV_KIND_POCKET: format(header, sizeof header, "[INV] pocket (%d slots)", size);
        case INV_KIND_EQUIP: format(header, sizeof header, "[INV] equip (%d slots)", size);
        case INV_KIND_BACKPACK: format(header, sizeof header, "[INV] backpack (%d slots)", size);
    }
    SendClientMessage(playerid, -1, header);

    new msg[192];
    for (new slot = 0; slot < size; slot++)
    {
        new item_id, amount;
        new data[256];
        if (!Inv_DB_GetSlotItem(cid, slot, item_id, amount, data, sizeof data)) continue;
        format(msg, sizeof msg, "[INV] slot %d: item=%d amt=%d data=%s", slot, item_id, amount, data);
        SendClientMessage(playerid, -1, msg);
    }
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
stock cmd_inv(playerid, const params[])
{
    #pragma unused params
    if (!Inv_IsPlayerReady(playerid)) { SendClientMessage(playerid, -1, "[INV] Доступно после логина."); return 1; }
    Inv_DebugPrintContainer(playerid, INV_KIND_POCKET);
    Inv_DebugPrintContainer(playerid, INV_KIND_EQUIP);
    if (gInvContainerId[playerid][INV_KIND_BACKPACK]) Inv_DebugPrintContainer(playerid, INV_KIND_BACKPACK);
    return 1;
}

stock cmd_invadd(playerid, const params[])
{
    if (!Inv_IsPlayerReady(playerid)) { SendClientMessage(playerid, -1, "[INV] Доступно после логина."); return 1; }

    new item_id, amount;
    new data[256];
    data[0] = '\0';

    if (sscanf(params, "iiS()[256]", item_id, amount, data) != 0)
    {
        SendClientMessage(playerid, -1, "Использование: /invadd [item_id] [amount] [data JSON опц.]");
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
        SendClientMessage(playerid, -1, "Использование: /invmv [from_kind 0/1/2] [from_slot] [to_kind 0/1/2] [to_slot]");
        return 1;
    }
    if (!Inv_MoveItemPlayer(playerid, from_kind, from_slot, to_kind, to_slot))
    {
        SendClientMessage(playerid, -1, "[INV] Нельзя переместить.");
        return 1;
    }
    SendClientMessage(playerid, -1, "[INV] OK.");
    return 1;
}

stock cmd_invuse(playerid, const params[])
{
    if (!Inv_IsPlayerReady(playerid)) { SendClientMessage(playerid, -1, "[INV] not available."); return 1; }
    new kind, slot;
    if (sscanf(params, "ii", kind, slot) != 0)
    {
        if (sscanf(params, "i", slot) != 0)
        {
            SendClientMessage(playerid, -1, "Usage: /invuse [kind 0/1/2] [slot]");
            return 1;
        }
        kind = INV_KIND_POCKET;
    }
    if (!Inv_IsValidKind(kind))
    {
        SendClientMessage(playerid, -1, "[INV] invalid container.");
        return 1;
    }
    if (!Inv_UseSlot(playerid, kind, slot))
    {
        SendClientMessage(playerid, -1, "[INV] cannot use item.");
        return 1;
    }
    SendClientMessage(playerid, -1, "[INV] used.");
    return 1;
}

stock cmd_invdrop(playerid, const params[])
{
    if (!Inv_IsPlayerReady(playerid)) { SendClientMessage(playerid, -1, "[INV] not available."); return 1; }
    new kind, slot, amount = 1;
    if (sscanf(params, "iiI(1)", kind, slot, amount) != 0)
    {
        if (sscanf(params, "iI(1)", slot, amount) != 0)
        {
            SendClientMessage(playerid, -1, "Usage: /invdrop [kind 0/1/2] [slot] [amount opt.]");
            return 1;
        }
        kind = INV_KIND_POCKET;
    }
    if (!Inv_IsValidKind(kind))
    {
        SendClientMessage(playerid, -1, "[INV] invalid container.");
        return 1;
    }
    new size = Inv_GetKindSize(playerid, kind);
    if (slot < 0 || slot >= size)
    {
        SendClientMessage(playerid, -1, "[INV] invalid slot.");
        return 1;
    }
    new cid = gInvContainerId[playerid][kind];
    if (!cid) { SendClientMessage(playerid, -1, "[INV] cannot drop."); return 1; }

    new item_id, cur_amount;
    new data[256];
    if (!Inv_DB_GetSlotItem(cid, slot, item_id, cur_amount, data, sizeof data))
    {
        SendClientMessage(playerid, -1, "[INV] cannot drop.");
        return 1;
    }
    if (kind == INV_KIND_EQUIP && slot == INV_EQUIP_SLOT_BACKPACK && item_id == ITEM_BACKPACK)
    {
        new backpack_cid = gInvContainerId[playerid][INV_KIND_BACKPACK];
        if (backpack_cid && !Inv_DB_IsContainerEmpty(backpack_cid))
        {
            SendClientMessage(playerid, -1, "[INV] backpack is not empty.");
            return 1;
        }
    }

    if (!Inv_RemoveItem(cid, slot, amount))
    {
        SendClientMessage(playerid, -1, "[INV] cannot drop.");
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
    SendClientMessage(playerid, -1, "[INV] dropped.");
    return 1;
}

stock cmd_invgive(playerid, const params[])
{
    if (!Inv_IsPlayerReady(playerid)) { SendClientMessage(playerid, -1, "[INV] Доступно после логина."); return 1; }
    new targetid, kind, slot, amount = 1;
    if (sscanf(params, "iiiI(1)", targetid, kind, slot, amount) != 0)
    {
        SendClientMessage(playerid, -1, "Использование: /invgive [playerid] [kind 0/1/2] [slot] [amount опц.]");
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




