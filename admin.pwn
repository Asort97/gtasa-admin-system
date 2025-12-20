// ==========================================
// ADMIN SYSTEM для GTA SA сервера
// Используется: open.mp + SQLite (omp_database)
// ==========================================

#include <open.mp>
#include <sscanf2>

// ---- DEFINE'ы
#define ADMIN_LOG_FILE          "admin_log.txt"
#define ADMIN_MUTE_REASON_SIZE  64
#define ADMIN_LOG_TMP_FILE      "admin_log.tmp"

// Уровни администраторов
#define ADMIN_LEVEL_NONE        0
#define ADMIN_LEVEL_1           1
#define ADMIN_LEVEL_2           2
#define ADMIN_LEVEL_3           3
#define ADMIN_LEVEL_4           4
#define ADMIN_LEVEL_OWNER       5

// ---- Структура данных администратора
enum E_ADMIN_DATA
{
    AdminLevel,
    bool:IsMuted,
    MuteTime,
    MuteReason[ADMIN_MUTE_REASON_SIZE]
}
new AdminData[MAX_PLAYERS][E_ADMIN_DATA];

new bool:gAdminLevelLoaded[MAX_PLAYERS];

// ---- Структура для информации о бане
enum E_BAN_INFO
{
    BanID,
    BanName[MAX_PLAYER_NAME],
    BanReason[128],
    BanDate[32],
    BanExpire[32],
    BanAdmin[MAX_PLAYER_NAME]
}

static bool:gLogInited;

stock WriteRawBytes(File:f, const bytes[], len)
{
    for (new i = 0; i < len; i++)
    {
        fputchar(f, bytes[i] & 0xFF, false);
    }
}

stock WriteRawString(File:f, const s[])
{
    for (new i = 0; s[i]; i++)
    {
        fputchar(f, s[i] & 0xFF, false);
    }
}

stock bool:AdminLogLineEndsWithNewline(const s[])
{
    new len = strlen(s);
    if (!len) return false;

    new c = s[len - 1];
    return (c == '\n' || c == '\r');
}

stock StripUtf8BomPrefix(s[])
{
    if (!s[0] || !s[1] || !s[2]) return;

    if (((s[0] & 0xFF) == 0xEF) && ((s[1] & 0xFF) == 0xBB) && ((s[2] & 0xFF) == 0xBF))
    {
        new i = 0;
        while (s[i + 3])
        {
            s[i] = s[i + 3];
            i++;
        }
        s[i] = '\0';
    }
}

stock AdminLogInit()
{
    if (gLogInited) return;

    // Ensure the log is UTF-8 with BOM (for Windows Notepad).
    // If an old log exists without BOM (ANSI/CP1251), convert it once.
    if (!fexist(ADMIN_LOG_FILE))
    {
        new File:w = fopen(ADMIN_LOG_FILE, io_write);
        if (w)
        {
            new bom[3] = { 0xEF, 0xBB, 0xBF };
            WriteRawBytes(w, bom, 3);
            fclose(w);
        }
        gLogInited = true;
        return;
    }

    new File:r = fopen(ADMIN_LOG_FILE, io_read);
    if (!r)
    {
        gLogInited = true;
        return;
    }

    new b1 = fgetchar(r, false);
    new b2 = fgetchar(r, false);
    new b3 = fgetchar(r, false);

    if (((b1 & 0xFF) == 0xEF) && ((b2 & 0xFF) == 0xBB) && ((b3 & 0xFF) == 0xBF))
    {
        fclose(r);
        gLogInited = true;
        return;
    }

    fseek(r, 0, seek_start);

    new File:w = fopen(ADMIN_LOG_TMP_FILE, io_write);
    if (!w)
    {
        fclose(r);
        gLogInited = true;
        return;
    }

    new bom[3] = { 0xEF, 0xBB, 0xBF };
    WriteRawBytes(w, bom, 3);

    new line[700];
    new out[1000];

    while (fread(r, line, sizeof line))
    {
        StripUtf8BomPrefix(line);
        NormalizeToUtf8(line, out, sizeof out);
        WriteRawString(w, out);
        if (!AdminLogLineEndsWithNewline(out)) WriteRawString(w, "\r\n");
    }

    fclose(r);
    fclose(w);

    fremove(ADMIN_LOG_FILE);
    frename(ADMIN_LOG_TMP_FILE, ADMIN_LOG_FILE);

    gLogInited = true;
}
// 1) Признак “?…?…” в UTF-8 (double-encoded UTF-8 bytes as Latin-1)
stock bool:LooksLikeMojibake(const s[])
{
    for (new i = 0; s[i] && s[i + 1]; i++)
    {
        new a = s[i] & 0xFF;
        new b = s[i + 1] & 0xFF;

        if (a == 0xC3 && (b == 0x90 || b == 0x91)) return true; // ? / ?
        if (a == 0xC2 && (b >= 0x80 && b <= 0xBF)) return true;
    }
    return false;
}

// 2) “Размотка” mojibake: UTF-8(Latin1(bytes)) -> bytes
stock UnmangleUtf8FromLatin1(const src[], dest[], size)
{
    new i = 0, j = 0;
    while (src[i] && j < size - 1)
    {
        new a = src[i] & 0xFF;

        // C2 xx -> xx
        if (a == 0xC2 && src[i + 1])
        {
            dest[j++] = src[i + 1];
            i += 2;
            continue;
        }

        // C3 xx -> (xx + 0x40)
        if (a == 0xC3 && src[i + 1])
        {
            dest[j++] = (src[i + 1] + 0x40) & 0xFF;
            i += 2;
            continue;
        }

        dest[j++] = src[i++];
    }
    dest[j] = '\0';
}

// 3) Признак, что строка уже похожа на UTF-8 кириллицу (D0/D1 xx)
stock bool:LooksLikeUtf8Cyr(const s[])
{
    for (new i = 0; s[i] && s[i + 1]; i++)
    {
        new a = s[i] & 0xFF;
        new b = s[i + 1] & 0xFF;

        if ((a == 0xD0 || a == 0xD1) && (b >= 0x80 && b <= 0xBF)) return true;
    }
    return false;
}

// 4) Мини-конвертер CP1251 -> UTF-8 (кириллица + Ё/ё + №)
stock Cp1251ToUtf8(const src[], dest[], size)
{
    new i = 0, j = 0;
    while (src[i] && j < size - 1)
    {
        new c = src[i] & 0xFF;

        if (c < 0x80) { dest[j++] = c; }
        else if (c == 0xA8) { dest[j++] = 0xD0; dest[j++] = 0x81; }          // Ё
        else if (c == 0xB8) { dest[j++] = 0xD1; dest[j++] = 0x91; }          // ё
        else if (c == 0xB9) { dest[j++] = 0xE2; dest[j++] = 0x84; dest[j++] = 0x96; } // №
        else if (c >= 0xC0 && c <= 0xDF) { dest[j++] = 0xD0; dest[j++] = c - 0x30; } // А..Я
        else if (c >= 0xE0 && c <= 0xEF) { dest[j++] = 0xD0; dest[j++] = c - 0x30; } // а..п
        else if (c >= 0xF0 && c <= 0xFF) { dest[j++] = 0xD1; dest[j++] = c - 0x70; } // р..я
        else { dest[j++] = '?'; }

        i++;
        if (j >= size - 4) break;
    }
    dest[j] = '\0';
}

stock NormalizeToUtf8(const src[], dest[], size)
{
    if (LooksLikeMojibake(src))
    {
        // после размотки получаем корректные UTF-8 байты
        UnmangleUtf8FromLatin1(src, dest, size);
        return;
    }

    if (LooksLikeUtf8Cyr(src))
    {
        strcopy(dest, src, size);
        return;
    }

    // иначе считаем что это CP1251
    Cp1251ToUtf8(src, dest, size);
}

stock LogAdminAction(const admin[], adminlvl, const action[])
{
    AdminLogInit();

    new h,m,s; gettime(h,m,s);

    new raw[700];
    format(raw, sizeof raw, "[%02d:%02d:%02d] LVL:%d | %s | %s\r\n", h, m, s, adminlvl, admin, action);

    new out[1000];
    NormalizeToUtf8(raw, out, sizeof out);

    new File:f = fopen(ADMIN_LOG_FILE, io_append);
    if (!f) f = fopen(ADMIN_LOG_FILE, io_write);
    if (f) { WriteRawString(f, out); fclose(f); }
}

// Проверка админ-уровня
stock bool:HasAdminLevel(playerid, requiredlevel)
{
    if (!IsPlayerConnected(playerid)) return false;
    return (AdminData[playerid][AdminLevel] >= requiredlevel);
}

// Название уровня администратора
stock GetAdminLevelName(level, out[], size)
{
    switch(level)
    {
        case ADMIN_LEVEL_NONE: format(out, size, "Обычный игрок");
        case ADMIN_LEVEL_1: format(out, size, "Администратор 1 уровня");
        case ADMIN_LEVEL_2: format(out, size, "Администратор 2 уровня");
        case ADMIN_LEVEL_3: format(out, size, "Администратор 3 уровня");
        case ADMIN_LEVEL_4: format(out, size, "Администратор 4 уровня");
        case ADMIN_LEVEL_OWNER: format(out, size, "Владелец сервера");
        default: format(out, size, "Неизвестный уровень");
    }
}

// ==========================================
// DATABASE - АДМИН УРОВНИ
// ==========================================

// Миграция базы данных (добавление поля admin)
stock AdminDB_Migrate()
{
    DB_ExecuteQuery(gDB, "ALTER TABLE accounts ADD COLUMN admin INTEGER DEFAULT 0;");
}

// Загрузить админ-уровень игрока
stock AdminDB_LoadLevel(playerid)
{
    new name[MAX_PLAYER_NAME];
    GetPlayerName(playerid, name, sizeof name);

    new ename[MAX_PLAYER_NAME * 2 + 8];
    SQLEscape(name, ename, sizeof ename);

    new q[256];
    format(q, sizeof q, "SELECT admin FROM accounts WHERE name='%s' LIMIT 1;", ename);

    new DBResult:r = DB_ExecuteQuery(gDB, q);
    if (r == DBResult:0) return 0;

    if (DB_GetRowCount(r) < 1)
    {
        DB_FreeResultSet(r);
        AdminData[playerid][AdminLevel] = ADMIN_LEVEL_NONE;
        gAdminLevelLoaded[playerid] = false;
        return 0;
    }

    new level = DB_GetFieldIntByName(r, "admin");
    DB_FreeResultSet(r);

    AdminData[playerid][AdminLevel] = level;
    gAdminLevelLoaded[playerid] = true;
    return level;
}

// Сохранить админ-уровень игрока
stock AdminDB_SaveLevel(playerid)
{
    if (!IsPlayerConnected(playerid)) return 0;

    // Если игрок вылетел/вышел до загрузки админ-уровня из БД,
    // не перезаписываем значение в accounts.admin на 0.
    if (!gAdminLevelLoaded[playerid]) return 0;

    new name[MAX_PLAYER_NAME];
    GetPlayerName(playerid, name, sizeof name);

    new ename[MAX_PLAYER_NAME * 2 + 8];
    SQLEscape(name, ename, sizeof ename);

    new level = AdminData[playerid][AdminLevel];

    new q[256];
    format(q, sizeof q, "UPDATE accounts SET admin=%d WHERE name='%s';", level, ename);

    new DBResult:r = DB_ExecuteQuery(gDB, q);
    if (r != DBResult:0) DB_FreeResultSet(r);

    return 1;
}

// ==========================================
// DATABASE - БАН СИСТЕМА
// ==========================================

// Создание таблицы банов
stock BanDB_CreateTable()
{
    DB_ExecuteQuery(gDB, "CREATE TABLE IF NOT EXISTS bans (id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT UNIQUE, reason TEXT, bandate TEXT, expiredate TEXT, admin TEXT);");
}

// Добавить игрока в бан-лист
stock BanDB_Add(const banname[], const reason[], days, const admin[])
{
    new ename[MAX_PLAYER_NAME * 2 + 8];
    new ereason[256];
    new eadmin[MAX_PLAYER_NAME * 2 + 8];

    SQLEscape(banname, ename, sizeof ename);
    SQLEscape(reason, ereason, sizeof ereason);
    SQLEscape(admin, eadmin, sizeof eadmin);

    new bandate[32];
    new expiredate[32];
    format(bandate, sizeof bandate, "2025-12-18");        // TODO: реальная дата
    format(expiredate, sizeof expiredate, "2025-12-%02d", 18 + days);  // TODO: расчёт даты окончания

    new q[512];
    format(q, sizeof q, "INSERT INTO bans (name, reason, bandate, expiredate, admin) VALUES('%s', '%s', '%s', '%s', '%s');", ename, ereason, bandate, expiredate, eadmin);

    new DBResult:r = DB_ExecuteQuery(gDB, q);
    if (r != DBResult:0) DB_FreeResultSet(r);

    return 1;
}

// Удалить игрока из бан-листа
stock BanDB_Remove(const banname[])
{
    new ename[MAX_PLAYER_NAME * 2 + 8];
    SQLEscape(banname, ename, sizeof ename);

    new q[256];
    format(q, sizeof q, "DELETE FROM bans WHERE name='%s';", ename);

    new DBResult:r = DB_ExecuteQuery(gDB, q);
    if (r != DBResult:0) DB_FreeResultSet(r);

    return 1;
}

// Проверить, забанен ли игрок
stock bool:BanDB_IsPlayerBanned(const name[], out_reason[], out_size)
{
    new ename[MAX_PLAYER_NAME * 2 + 8];
    SQLEscape(name, ename, sizeof ename);

    new q[256];
    format(q, sizeof q, "SELECT reason FROM bans WHERE name='%s' LIMIT 1;", ename);

    new DBResult:r = DB_ExecuteQuery(gDB, q);
    if (r == DBResult:0) return false;

    if (DB_GetRowCount(r) < 1)
    {
        DB_FreeResultSet(r);
        return false;
    }

    DB_GetFieldStringByName(r, "reason", out_reason, out_size);
    DB_FreeResultSet(r);
    return true;
}

// Количество банов (для отладочной панели)
stock BanDB_GetAll(out[], size)
{
    new q[128];
    format(q, sizeof q, "SELECT COUNT(*) as cnt FROM bans;");

    new DBResult:r = DB_ExecuteQuery(gDB, q);
    if (r == DBResult:0) return 0;

    new count = DB_GetFieldIntByName(r, "cnt");
    DB_FreeResultSet(r);

    return count;
}

// ==========================================
// ВСТАВКИ В КОЛБЭКИ
// ==========================================

stock Admin_OnPlayerConnect(playerid)
{
    AdminData[playerid][AdminLevel] = ADMIN_LEVEL_NONE;
    AdminData[playerid][IsMuted] = false;
    AdminData[playerid][MuteTime] = 0;
    AdminData[playerid][MuteReason][0] = '\0';
    gAdminLevelLoaded[playerid] = false;
    return 1;
}

stock Admin_OnPlayerSpawn(playerid)
{
    #pragma unused playerid
    return 1;
}

stock Admin_OnPlayerDisconnect(playerid, reason)
{
    #pragma unused reason
    AdminDB_SaveLevel(playerid);
    return 1;
}

stock Admin_OnPlayerText(playerid, text[])
{
    // Проверка мута
    if (AdminData[playerid][IsMuted])
    {
        new mute_msg[128];
        format(mute_msg, sizeof mute_msg, "[МУТ] Вам запрещено писать в чат. Причина: %s", AdminData[playerid][MuteReason]);
        SendClientMessage(playerid, -1, mute_msg);
        return 0;
    }

    // Админ-чат через @
    if (text[0] == '@')
    {
        if (!HasAdminLevel(playerid, ADMIN_LEVEL_1))
        {
            SendClientMessage(playerid, -1, "[ОШИБКА] У вас нет доступа к админ-чату.");
            return 0;
        }

        new name[MAX_PLAYER_NAME];
        GetPlayerName(playerid, name, sizeof name);

        new message[256];
        format(message, sizeof message, "[АДМИН] %s (LVL %d): %s", name, AdminData[playerid][AdminLevel], text[1]);

        for (new i = 0; i < MAX_PLAYERS; i++)
        {
            if (IsPlayerConnected(i) && HasAdminLevel(i, ADMIN_LEVEL_1))
            {
                SendClientMessage(i, 0x00FF00FF, message);
            }
        }

        new log_text[512];
        format(log_text, sizeof log_text, "Админ-чат: %s", message);
        LogAdminAction(name, AdminData[playerid][AdminLevel], log_text);
        return 0;
    }

    return 1;
}

// ==========================================
// КОМАНДЫ АДМИНИСТРАТОРА
// ==========================================

public OnPlayerCommandText(playerid, cmdtext[])
{
    new cmd[32], params[128];
    new pos = strfind(cmdtext, " ");
    
    if (pos == -1)
    {
        strmid(cmd, cmdtext, 1, strlen(cmdtext));
        params[0] = '\0';
    }
    else
    {
        strmid(cmd, cmdtext, 1, pos);
        strmid(params, cmdtext, pos + 1, strlen(cmdtext));
    }

    if (!strcmp(cmd, "setadmin", true)) return cmd_setadmin(playerid, params);
    if (!strcmp(cmd, "kick", true)) return cmd_kick(playerid, params);
    if (!strcmp(cmd, "mute", true)) return cmd_mute(playerid, params);
    if (!strcmp(cmd, "unmute", true)) return cmd_unmute(playerid, params);
    if (!strcmp(cmd, "goto", true)) return cmd_goto(playerid, params);
    if (!strcmp(cmd, "gethere", true)) return cmd_gethere(playerid, params);
    if (!strcmp(cmd, "ban", true)) return cmd_ban(playerid, params);
    if (!strcmp(cmd, "unban", true)) return cmd_unban(playerid, params);
    if (!strcmp(cmd, "a", true)) return cmd_a(playerid, params);
    if (!strcmp(cmd, "admin", true)) return cmd_admin(playerid, params);
    if (!strcmp(cmd, "veh", true)) return cmd_veh(playerid, params);
    if (!strcmp(cmd, "авто", true)) return cmd_veh(playerid, params);
    if (!strcmp(cmd, "fly", true)) return cmd_fly(playerid, params);
    if (!strcmp(cmd, "полет", true)) return cmd_fly(playerid, params);

    return 0;
}

// /setadmin ID LEVEL - только владелец
stock cmd_setadmin(playerid, const params[])
{
    if (!HasAdminLevel(playerid, ADMIN_LEVEL_OWNER))
    {
        SendClientMessage(playerid, -1, "[ОШИБКА] Команда доступна только владельцу.");
        return 1;
    }

    new targetid, level;
    if (sscanf(params, "ii", targetid, level) != 0)
    {
        SendClientMessage(playerid, -1, "Использование: /setadmin [ID] [уровень 0-5]");
        return 1;
    }

    if (!IsPlayerConnected(targetid))
    {
        SendClientMessage(playerid, -1, "[ОШИБКА] Игрок не подключен.");
        return 1;
    }

    if (level < ADMIN_LEVEL_NONE || level > ADMIN_LEVEL_OWNER)
    {
        SendClientMessage(playerid, -1, "[ОШИБКА] Уровень должен быть от 0 до 5.");
        return 1;
    }

    new admin_name[MAX_PLAYER_NAME];
    new target_name[MAX_PLAYER_NAME];
    GetPlayerName(playerid, admin_name, sizeof admin_name);
    GetPlayerName(targetid, target_name, sizeof target_name);

    new old_level = AdminData[targetid][AdminLevel];
    AdminData[targetid][AdminLevel] = level;
    AdminDB_SaveLevel(targetid);

    new message[256];
    new level_name[64];
    GetAdminLevelName(level, level_name, sizeof level_name);

    format(message, sizeof message, "Вам установлен уровень администратора: %s", level_name);
    SendClientMessage(targetid, 0x00FF00FF, message);

    format(message, sizeof message, "Вы выдали админку %s уровень %d", target_name, level);
    SendClientMessage(playerid, 0x00FF00FF, message);

    // Лог
    new log_text[256];
    format(log_text, sizeof log_text, "Изменил админ %s: %d -> %d", target_name, old_level, level);
    LogAdminAction(admin_name, AdminData[playerid][AdminLevel], log_text);

    return 1;
}

// /kick ID причина
stock cmd_kick(playerid, const params[])
{
    if (!HasAdminLevel(playerid, ADMIN_LEVEL_1))
    {
        SendClientMessage(playerid, -1, "[ОШИБКА] Нет доступа к этой команде.");
        return 1;
    }

    new targetid, reason[128];
    if (sscanf(params, "iS(Нарушение правил)[128]", targetid, reason) != 0)
    {
        SendClientMessage(playerid, -1, "Использование: /kick [ID] [причина]");
        return 1;
    }

    if (!IsPlayerConnected(targetid))
    {
        SendClientMessage(playerid, -1, "[ОШИБКА] Игрок не подключен.");
        return 1;
    }

    if (targetid == playerid)
    {
        SendClientMessage(playerid, -1, "[ОШИБКА] Нельзя кикнуть себя.");
        return 1;
    }

    if (AdminData[targetid][AdminLevel] > AdminData[playerid][AdminLevel])
    {
        SendClientMessage(playerid, -1, "[ОШИБКА] Игрок выше уровнем.");
        return 1;
    }

    new admin_name[MAX_PLAYER_NAME];
    new target_name[MAX_PLAYER_NAME];
    GetPlayerName(playerid, admin_name, sizeof admin_name);
    GetPlayerName(targetid, target_name, sizeof target_name);

    new message[256];
    format(message, sizeof message, "%s был кикнут. Причина: %s", target_name, reason);
    SendClientMessageToAll(-1, message);

    // Лог
    new log_text[256];
    format(log_text, sizeof log_text, "Кик %s: %s", target_name, reason);
    LogAdminAction(admin_name, AdminData[playerid][AdminLevel], log_text);

    Kick(targetid);
    return 1;
}

// /mute ID минуты причина
stock cmd_mute(playerid, const params[])
{
    if (!HasAdminLevel(playerid, ADMIN_LEVEL_2))
    {
        SendClientMessage(playerid, -1, "[ОШИБКА] Нет доступа к этой команде.");
        return 1;
    }

    new targetid, minutes;
    new reason[128];
    if (sscanf(params, "iiS(Спам)[128]", targetid, minutes, reason) != 0)
    {
        SendClientMessage(playerid, -1, "Использование: /mute [ID] [минуты] [причина]");
        return 1;
    }

    if (!IsPlayerConnected(targetid))
    {
        SendClientMessage(playerid, -1, "[ОШИБКА] Игрок не подключен.");
        return 1;
    }

    new admin_name[MAX_PLAYER_NAME];
    new target_name[MAX_PLAYER_NAME];
    GetPlayerName(playerid, admin_name, sizeof admin_name);
    GetPlayerName(targetid, target_name, sizeof target_name);

    AdminData[targetid][IsMuted] = true;
    AdminData[targetid][MuteTime] = minutes * 60;
    format(AdminData[targetid][MuteReason], ADMIN_MUTE_REASON_SIZE, "%s", reason);

    new message[256];
    format(message, sizeof message, "%s был замучен на %d минут. Причина: %s", target_name, minutes, reason);
    SendClientMessageToAll(-1, message);

    // Лог
    new log_text[256];
    format(log_text, sizeof log_text, "Мут %s на %d мин: %s", target_name, minutes, reason);
    LogAdminAction(admin_name, AdminData[playerid][AdminLevel], log_text);

    return 1;
}

// /unmute ID
stock cmd_unmute(playerid, const params[])
{
    if (!HasAdminLevel(playerid, ADMIN_LEVEL_2))
    {
        SendClientMessage(playerid, -1, "[ОШИБКА] Нет доступа к этой команде.");
        return 1;
    }

    new targetid;
    if (sscanf(params, "i", targetid) != 0)
    {
        SendClientMessage(playerid, -1, "Использование: /unmute [ID]");
        return 1;
    }

    if (!IsPlayerConnected(targetid))
    {
        SendClientMessage(playerid, -1, "[ОШИБКА] Игрок не подключен.");
        return 1;
    }

    new admin_name[MAX_PLAYER_NAME];
    new target_name[MAX_PLAYER_NAME];
    GetPlayerName(playerid, admin_name, sizeof admin_name);
    GetPlayerName(targetid, target_name, sizeof target_name);

    AdminData[targetid][IsMuted] = false;
    AdminData[targetid][MuteTime] = 0;
    AdminData[targetid][MuteReason][0] = '\0';

    new message[256];
    format(message, sizeof message, "%s был размучен.", target_name);
    SendClientMessageToAll(-1, message);

    // Лог
    new log_text[256];
    format(log_text, sizeof log_text, "Размут %s", target_name);
    LogAdminAction(admin_name, AdminData[playerid][AdminLevel], log_text);

    return 1;
}

// /goto ID - телепортация к игроку
stock cmd_goto(playerid, const params[])
{
    if (!HasAdminLevel(playerid, ADMIN_LEVEL_1))
    {
        SendClientMessage(playerid, -1, "[ОШИБКА] Нет доступа к этой команде.");
        return 1;
    }

    new targetid;
    if (sscanf(params, "i", targetid) != 0)
    {
        SendClientMessage(playerid, -1, "Использование: /goto [ID]");
        return 1;
    }

    if (!IsPlayerConnected(targetid))
    {
        SendClientMessage(playerid, -1, "[ОШИБКА] Игрок не подключен.");
        return 1;
    }

    if (targetid == playerid)
    {
        SendClientMessage(playerid, -1, "[ОШИБКА] Вы уже здесь.");
        return 1;
    }

    new Float:x, Float:y, Float:z, Float:a;
    GetPlayerPos(targetid, x, y, z);
    GetPlayerFacingAngle(targetid, a);

    new interior = GetPlayerInterior(targetid);
    new vw = GetPlayerVirtualWorld(targetid);

    SetPlayerPos(playerid, x, y, z + 2.0);
    SetPlayerFacingAngle(playerid, a);
    SetPlayerInterior(playerid, interior);
    SetPlayerVirtualWorld(playerid, vw);

    new target_name[MAX_PLAYER_NAME];
    new admin_name[MAX_PLAYER_NAME];
    GetPlayerName(playerid, admin_name, sizeof admin_name);
    GetPlayerName(targetid, target_name, sizeof target_name);

    new message[256];
    format(message, sizeof message, "Вы телепортировались к %s", target_name);
    SendClientMessage(playerid, 0x00FF00FF, message);

    // Лог
    new log_text[256];
    format(log_text, sizeof log_text, "Телепорт к %s", target_name);
    LogAdminAction(admin_name, AdminData[playerid][AdminLevel], log_text);

    return 1;
}

// /gethere ID - телепортация игрока к администратору
stock cmd_gethere(playerid, const params[])
{
    if (!HasAdminLevel(playerid, ADMIN_LEVEL_1))
    {
        SendClientMessage(playerid, -1, "[ОШИБКА] Нет доступа к этой команде.");
        return 1;
    }

    new targetid;
    if (sscanf(params, "i", targetid) != 0)
    {
        SendClientMessage(playerid, -1, "Использование: /gethere [ID]");
        return 1;
    }

    if (!IsPlayerConnected(targetid))
    {
        SendClientMessage(playerid, -1, "[ОШИБКА] Игрок не подключен.");
        return 1;
    }

    if (targetid == playerid)
    {
        SendClientMessage(playerid, -1, "[ОШИБКА] Нельзя телепортировать себя.");
        return 1;
    }

    new Float:x, Float:y, Float:z, Float:a;
    GetPlayerPos(playerid, x, y, z);
    GetPlayerFacingAngle(playerid, a);

    new interior = GetPlayerInterior(playerid);
    new vw = GetPlayerVirtualWorld(playerid);

    SetPlayerPos(targetid, x, y, z + 2.0);
    SetPlayerFacingAngle(targetid, a);
    SetPlayerInterior(targetid, interior);
    SetPlayerVirtualWorld(targetid, vw);

    new target_name[MAX_PLAYER_NAME];
    new admin_name[MAX_PLAYER_NAME];
    GetPlayerName(playerid, admin_name, sizeof admin_name);
    GetPlayerName(targetid, target_name, sizeof target_name);

    new message[256];
    format(message, sizeof message, "Вас телепортировали к администратору %s", admin_name);
    SendClientMessage(targetid, 0x00FF00FF, message);

    format(message, sizeof message, "Вы телепортировали %s к себе", target_name);
    SendClientMessage(playerid, 0x00FF00FF, message);

    // Лог
    new log_text[256];
    format(log_text, sizeof log_text, "Телепорт к себе %s", target_name);
    LogAdminAction(admin_name, AdminData[playerid][AdminLevel], log_text);

    return 1;
}

// /ban ID дни причина
stock cmd_ban(playerid, const params[])
{
    if (!HasAdminLevel(playerid, ADMIN_LEVEL_4))
    {
        SendClientMessage(playerid, -1, "[ОШИБКА] Нет доступа к этой команде.");
        return 1;
    }

    new targetid, days;
    new reason[128];
    if (sscanf(params, "iiS(Нарушение правил)[128]", targetid, days, reason) != 0)
    {
        SendClientMessage(playerid, -1, "Использование: /ban [ID] [дни] [причина]");
        return 1;
    }

    if (!IsPlayerConnected(targetid))
    {
        SendClientMessage(playerid, -1, "[ОШИБКА] Игрок не подключен.");
        return 1;
    }

    new admin_name[MAX_PLAYER_NAME];
    new target_name[MAX_PLAYER_NAME];
    GetPlayerName(playerid, admin_name, sizeof admin_name);
    GetPlayerName(targetid, target_name, sizeof target_name);

    BanDB_Add(target_name, reason, days, admin_name);

    new message[256];
    format(message, sizeof message, "%s был забанен на %d дней. Причина: %s", target_name, days, reason);
    SendClientMessageToAll(-1, message);

    // Лог
    new log_text[256];
    format(log_text, sizeof log_text, "Бан %s на %d дн: %s", target_name, days, reason);
    LogAdminAction(admin_name, AdminData[playerid][AdminLevel], log_text);

    Kick(targetid);
    return 1;
}

// /unban имя
stock cmd_unban(playerid, const params[])
{
    if (!HasAdminLevel(playerid, ADMIN_LEVEL_4))
    {
        SendClientMessage(playerid, -1, "[ОШИБКА] Нет доступа к этой команде.");
        return 1;
    }

    new banname[MAX_PLAYER_NAME];
    if (sscanf(params, "s[24]", banname) != 0)
    {
        SendClientMessage(playerid, -1, "Использование: /unban [имя]");
        return 1;
    }

    new admin_name[MAX_PLAYER_NAME];
    GetPlayerName(playerid, admin_name, sizeof admin_name);

    BanDB_Remove(banname);

    new message[256];
    format(message, sizeof message, "%s был разбанен.", banname);
    SendClientMessage(playerid, 0x00FF00FF, message);

    // Лог
    new log_text[256];
    format(log_text, sizeof log_text, "Разбан %s", banname);
    LogAdminAction(admin_name, AdminData[playerid][AdminLevel], log_text);

    return 1;
}

// /a текст - админ-чат
stock cmd_a(playerid, const params[])
{
    if (!HasAdminLevel(playerid, ADMIN_LEVEL_1))
    {
        SendClientMessage(playerid, -1, "[ОШИБКА] У вас нет доступа к админ-чату.");
        return 1;
    }

    if (strlen(params) < 1)
    {
        SendClientMessage(playerid, -1, "Использование: /a [сообщение]");
        return 1;
    }

    new name[MAX_PLAYER_NAME];
    GetPlayerName(playerid, name, sizeof name);

    new message[256];
    format(message, sizeof message, "[АДМИН] %s (LVL %d): %s", name, AdminData[playerid][AdminLevel], params);

    for (new i = 0; i < MAX_PLAYERS; i++)
    {
        if (IsPlayerConnected(i) && HasAdminLevel(i, ADMIN_LEVEL_1))
        {
            SendClientMessage(i, 0x00FF00FF, message);
        }
    }

    // Лог
    new log_text[512];
    format(log_text, sizeof log_text, "Админ-чат: %s", message);
    LogAdminAction(name, AdminData[playerid][AdminLevel], log_text);

    return 1;
}

// /admin - информация об админ-системе
stock cmd_admin(playerid, const params[])
{
    #pragma unused params
    new level_name[64];
    GetAdminLevelName(AdminData[playerid][AdminLevel], level_name, sizeof level_name);

    SendClientMessage(playerid, -1, "=== ИНФОРМАЦИЯ О ПРОФИЛЕ ===");
    new level_msg[96];
    format(level_msg, sizeof level_msg, "Уровень: %s (%d)", level_name, AdminData[playerid][AdminLevel]);
    SendClientMessage(playerid, -1, level_msg);
    SendClientMessage(playerid, -1, "=== ДОСТУПНЫЕ КОМАНДЫ ===");

    if (AdminData[playerid][AdminLevel] >= ADMIN_LEVEL_1)
    {
        SendClientMessage(playerid, -1, "/a [текст] - админ-чат");
        SendClientMessage(playerid, -1, "/kick [ID] [причина] - кикнуть игрока");
        SendClientMessage(playerid, -1, "/goto [ID] - телепортироваться к игроку");
        SendClientMessage(playerid, -1, "/gethere [ID] - телепортировать игрока");
    }

    if (AdminData[playerid][AdminLevel] >= ADMIN_LEVEL_2)
    {
        SendClientMessage(playerid, -1, "/mute [ID] [минуты] [причина] - замутить игрока");
        SendClientMessage(playerid, -1, "/unmute [ID] - размутить игрока");
    }

    if (AdminData[playerid][AdminLevel] >= ADMIN_LEVEL_3)
    {
        SendClientMessage(playerid, -1, "/fly - включить/выключить полёт");
        SendClientMessage(playerid, -1, "/veh [ID] - заспавнить транспорт");
    }

    if (AdminData[playerid][AdminLevel] >= ADMIN_LEVEL_4)
    {
        SendClientMessage(playerid, -1, "/ban [ID] [дни] [причина] - забанить игрока");
        SendClientMessage(playerid, -1, "/unban [имя] - разбанить игрока");
    }

    if (AdminData[playerid][AdminLevel] >= ADMIN_LEVEL_OWNER)
    {
        SendClientMessage(playerid, -1, "/setadmin [ID] [уровень] - установить админ-уровень");
    }

    return 1;
}

// ==========================================
// TEST COMMANDS
// ==========================================

// /veh ID - spawn vehicle
stock cmd_veh(playerid, const params[])
{
    if (!HasAdminLevel(playerid, ADMIN_LEVEL_3))
    {
        SendClientMessage(playerid, -1, "[ОШИБКА] Нет доступа к этой команде.");
        return 1;
    }

    new vehicleid;
    if (sscanf(params, "i", vehicleid) != 0)
    {
        SendClientMessage(playerid, -1, "Использование: /veh [ID транспорта 400-611]");
        return 1;
    }

    if (vehicleid < 400 || vehicleid > 611)
    {
        SendClientMessage(playerid, -1, "[ОШИБКА] ID транспорта должен быть 400-611.");
        return 1;
    }

    new Float:x, Float:y, Float:z, Float:a;
    GetPlayerPos(playerid, x, y, z);
    GetPlayerFacingAngle(playerid, a);

    // Spawn the vehicle in front of the player (not inside the player).
    new Float:spawn_dist = 5.0;
    new Float:spawn_x = x + floatsin(a, degrees) * spawn_dist;
    new Float:spawn_y = y + floatcos(a, degrees) * spawn_dist;

    // Face the player ("напротив игрока").
    new Float:veh_a = a + 180.0;
    if (veh_a >= 360.0) veh_a -= 360.0;

    new veh = CreateVehicle(vehicleid, spawn_x, spawn_y, z + 1.0, veh_a, -1, -1, -1);
    
    if (veh == INVALID_VEHICLE_ID)
    {
        SendClientMessage(playerid, -1, "[ОШИБКА] Не удалось создать транспорт.");
        return 1;
    }

    new admin_name[MAX_PLAYER_NAME];
    GetPlayerName(playerid, admin_name, sizeof admin_name);

    new message[128];
    format(message, sizeof message, "Транспорт создан: ID %d", vehicleid);
    SendClientMessage(playerid, 0x00FF00FF, message);

    new log_text[256];
    format(log_text, sizeof log_text, "Спавн транспорта: %d", vehicleid);
    LogAdminAction(admin_name, AdminData[playerid][AdminLevel], log_text);

    return 1;
}

// Fly mode toggle
new bool:gPlayerFlying[MAX_PLAYERS];
new bool:gFlyCamObjectCreated[MAX_PLAYERS];
new gFlyCamObject[MAX_PLAYERS];

// /fly - flight mode
stock cmd_fly(playerid, const params[])
{
    #pragma unused params
    
    if (!HasAdminLevel(playerid, ADMIN_LEVEL_3))
    {
        SendClientMessage(playerid, -1, "[ОШИБКА] Нет доступа к этой команде.");
        return 1;
    }

    gPlayerFlying[playerid] = !gPlayerFlying[playerid];

    new admin_name[MAX_PLAYER_NAME];
    GetPlayerName(playerid, admin_name, sizeof admin_name);

    if (gPlayerFlying[playerid])
    {
        new Float:x, Float:y, Float:z;
        GetPlayerPos(playerid, x, y, z);

        if (!gFlyCamObjectCreated[playerid])
        {
            // Attach the camera to a player-object so the player can rotate it with the mouse.
            gFlyCamObject[playerid] = CreatePlayerObject(playerid, 19300, x, y, z + 0.7, 0.0, 0.0, 0.0, 0.0);
            if (gFlyCamObject[playerid] == INVALID_OBJECT_ID)
            {
                gPlayerFlying[playerid] = false;
                SendClientMessage(playerid, -1, "[ОШИБКА] Не удалось создать объект камеры для /fly.");
                return 1;
            }
            gFlyCamObjectCreated[playerid] = true;
        }

        SetPlayerObjectPos(playerid, gFlyCamObject[playerid], x, y, z + 0.7);
        AttachCameraToPlayerObject(playerid, gFlyCamObject[playerid]);

        SendClientMessage(playerid, 0x00FF00FF, "Режим полёта: ВКЛ. Управление: W/S/A/D/Shift/C. Для быстрого отклика направления удерживай ПКМ (прицел).");
        // LogAdminAction(admin_name, AdminData[playerid][AdminLevel], "Включён режим полёта");

        new log_text[256];
        format(log_text, sizeof log_text, "Включён режим полёта");
        LogAdminAction(admin_name, AdminData[playerid][AdminLevel], log_text);
    }
    else
    {
        SendClientMessage(playerid, 0x00FF00FF, "Режим полёта: ВЫКЛ.");
        SetCameraBehindPlayer(playerid);

        if (gFlyCamObjectCreated[playerid])
        {
            DestroyPlayerObject(playerid, gFlyCamObject[playerid]);
            gFlyCamObjectCreated[playerid] = false;
        }

        LogAdminAction(admin_name, AdminData[playerid][AdminLevel], "Выключен режим полёта");

        new log_text[256];
        format(log_text, sizeof log_text, "Выключен режим полёта");
        LogAdminAction(admin_name, AdminData[playerid][AdminLevel], log_text);
    }

    return 1;
}

// (giveitem command removed: inventory system not implemented yet)

// Fly mode handler
public OnPlayerUpdate(playerid)
{
    if (gPlayerFlying[playerid])
    {
        new KEY:keys, ud, lr;
        GetPlayerKeys(playerid, keys, ud, lr);

        new Float:x, Float:y, Float:z;
        GetPlayerPos(playerid, x, y, z);

        // Noclip-like movement relative to camera direction (full 3D, incl. pitch).
        new Float:aim_fx, Float:aim_fy, Float:aim_fz;
        GetPlayerCameraFrontVector(playerid, aim_fx, aim_fy, aim_fz);

        // Forward (camera direction, normalized).
        new Float:forward_x = aim_fx;
        new Float:forward_y = aim_fy;
        new Float:forward_z = aim_fz;
        new Float:forward_len = floatsqroot(forward_x * forward_x + forward_y * forward_y + forward_z * forward_z);
        if (forward_len < 0.0001)
        {
            forward_x = 0.0;
            forward_y = 1.0;
            forward_z = 0.0;
            forward_len = 1.0;
        }
        forward_x /= forward_len;
        forward_y /= forward_len;
        forward_z /= forward_len;

        // Right = normalize(Up x Forward), Up = (0,0,1).
        new Float:right_x = -forward_y;
        new Float:right_y =  forward_x;
        new Float:right_z =  0.0;
        new Float:right_len = floatsqroot(right_x * right_x + right_y * right_y);
        if (right_len < 0.0001)
        {
            right_x = 1.0;
            right_y = 0.0;
            right_z = 0.0;
            right_len = 1.0;
        }
        right_x /= right_len;
        right_y /= right_len;

        // UpCam = Forward x Right (keeps vertical movement aligned with camera pitch).
        new Float:up_x = forward_y * right_z - forward_z * right_y;
        new Float:up_y = forward_z * right_x - forward_x * right_z;
        new Float:up_z = forward_x * right_y - forward_y * right_x;
        new Float:up_len = floatsqroot(up_x * up_x + up_y * up_y + up_z * up_z);
        if (up_len < 0.0001) up_len = 1.0;
        up_x /= up_len;
        up_y /= up_len;
        up_z /= up_len;

        new Float:speed = 2.0;
        if (keys & KEY_SPRINT) speed = 5.0;

        // Forward/backward (W/S) - move along camera forward (includes pitch).
        if (ud < 0) { x += forward_x * speed; y += forward_y * speed; z += forward_z * speed; }
        else if (ud > 0) { x -= forward_x * speed; y -= forward_y * speed; z -= forward_z * speed; }

        // Strafe (A/D) - relative to camera yaw (A=left, D=right).
        if (lr > 0) { x -= right_x * speed; y -= right_y * speed; }
        else if (lr < 0) { x += right_x * speed; y += right_y * speed; }

        // Vertical (Space/C) - relative to camera (UpCam).
        if (keys & KEY_JUMP) { x += up_x * speed; y += up_y * speed; z += up_z * speed; }
        if (keys & KEY_CROUCH) { x -= up_x * speed; y -= up_y * speed; z -= up_z * speed; }

        SetPlayerPos(playerid, x, y, z);
        SetPlayerVelocity(playerid, 0.0, 0.0, 0.0);

        if (gFlyCamObjectCreated[playerid])
        {
            SetPlayerObjectPos(playerid, gFlyCamObject[playerid], x, y, z + 0.7);
        }
    }

    return 1;
}

