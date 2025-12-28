#include <open.mp>
#include <omp_database>

#define DB_FILE "server.db"
#define INVALID_RESULT (DBResult:0)

// ---- диалоги
#define DIALOG_AUTH_CHOICE     1000
#define DIALOG_AUTH_LOGIN      1001
#define DIALOG_AUTH_REG_1      1002
#define DIALOG_AUTH_REG_2      1003

// ---- настройки авторизации
#define AUTH_TIMEOUT_MS        30000
#define AUTH_MAX_ATTEMPTS      3

new DB:gDB;

enum E_PLAYER_DATA
{
    bool:Logged,
    bool:Loaded,
    AccountId,

    Money,

    Float:PX,
    Float:PY,
    Float:PZ,
    Float:PA,

    Float:Health,
    Float:Armour,

    Skin,
    Interior,
    VW
}
new PlayerData[MAX_PLAYERS][E_PLAYER_DATA];

// данные авторизации
new bool:gAwaitAuth[MAX_PLAYERS];
new gAuthAttempts[MAX_PLAYERS];
new gAuthTimer[MAX_PLAYERS];
new gRegPass[MAX_PLAYERS][64];

forward FixInput(playerid);
forward AuthTimeout(playerid);

// -------------------- utils --------------------
stock SQLEscape(const input[], output[], out_size)
{
    output[0] = '\0';
    new j = 0;

    for (new i = 0; input[i] != '\0' && j < out_size - 1; i++)
    {
        if (input[i] == '\'')
        {
            if (j < out_size - 2)
            {
                output[j++] = '\'';
                output[j++] = '\'';
            }
            else output[j++] = '\'';
        }
        else output[j++] = input[i];
    }
    output[j] = '\0';
}

stock bool:DB_TableExists(const table[])
{
    new etable[128];
    SQLEscape(table, etable, sizeof etable);

    new q[256];
    format(q, sizeof q, "SELECT name FROM sqlite_master WHERE type='table' AND name='%s' LIMIT 1;", etable);
    new DBResult:r = DB_ExecuteQuery(gDB, q);
    if (r == INVALID_RESULT) return false;
    new rows = DB_GetRowCount(r);
    DB_FreeResultSet(r);
    return (rows > 0);
}

stock bool:DB_ColumnExists(const table[], const column[])
{
    new etable[128];
    new ecolumn[128];
    SQLEscape(table, etable, sizeof etable);
    SQLEscape(column, ecolumn, sizeof ecolumn);

    new q[256];
    format(q, sizeof q, "SELECT 1 FROM pragma_table_info('%s') WHERE name='%s' LIMIT 1;", etable, ecolumn);
    new DBResult:r = DB_ExecuteQuery(gDB, q);
    if (r == INVALID_RESULT) return false;
    new rows = DB_GetRowCount(r);
    DB_FreeResultSet(r);
    return (rows > 0);
}

#include <sscanf2>
#include "inventory.pwn"
#include "admin.pwn"

// -------------------- DB миграция (смена ключа на id аккаунта) --------------------
stock DB_MigrateAccounts()
{
    if (gDB == DB:0) return 0;

    if (!DB_TableExists("accounts"))
    {
        DB_ExecuteQuery(gDB, "CREATE TABLE accounts (id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT UNIQUE, pass TEXT, money INTEGER, x REAL, y REAL, z REAL, a REAL, hp REAL, arm REAL, skin INTEGER, interior INTEGER, vw INTEGER, admin INTEGER DEFAULT 0);");
        return 1;
    }

    if (!DB_ColumnExists("accounts", "id"))
    {
        new bool:has_admin = DB_ColumnExists("accounts", "admin");

        DB_ExecuteQuery(gDB, "CREATE TABLE accounts_new (id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT UNIQUE, pass TEXT, money INTEGER, x REAL, y REAL, z REAL, a REAL, hp REAL, arm REAL, skin INTEGER, interior INTEGER, vw INTEGER, admin INTEGER DEFAULT 0);");

        if (has_admin)
        {
            DB_ExecuteQuery(gDB, "INSERT INTO accounts_new (name,pass,money,x,y,z,a,hp,arm,skin,interior,vw,admin) SELECT name,pass,money,x,y,z,a,hp,arm,skin,interior,vw,admin FROM accounts;");
        }
        else
        {
            DB_ExecuteQuery(gDB, "INSERT INTO accounts_new (name,pass,money,x,y,z,a,hp,arm,skin,interior,vw) SELECT name,pass,money,x,y,z,a,hp,arm,skin,interior,vw FROM accounts;");
        }

        DB_ExecuteQuery(gDB, "DROP TABLE accounts;");
        DB_ExecuteQuery(gDB, "ALTER TABLE accounts_new RENAME TO accounts;");
    }

    if (!DB_ColumnExists("accounts", "a")) DB_ExecuteQuery(gDB, "ALTER TABLE accounts ADD COLUMN a REAL;");
    if (!DB_ColumnExists("accounts", "hp")) DB_ExecuteQuery(gDB, "ALTER TABLE accounts ADD COLUMN hp REAL;");
    if (!DB_ColumnExists("accounts", "arm")) DB_ExecuteQuery(gDB, "ALTER TABLE accounts ADD COLUMN arm REAL;");
    if (!DB_ColumnExists("accounts", "skin")) DB_ExecuteQuery(gDB, "ALTER TABLE accounts ADD COLUMN skin INTEGER;");
    if (!DB_ColumnExists("accounts", "interior")) DB_ExecuteQuery(gDB, "ALTER TABLE accounts ADD COLUMN interior INTEGER;");
    if (!DB_ColumnExists("accounts", "vw")) DB_ExecuteQuery(gDB, "ALTER TABLE accounts ADD COLUMN vw INTEGER;");
    if (!DB_ColumnExists("accounts", "admin")) DB_ExecuteQuery(gDB, "ALTER TABLE accounts ADD COLUMN admin INTEGER DEFAULT 0;");
    return 1;
}

// -------------------- DB helpers --------------------
stock bool:AccountExists(const name[])
{
    new ename[MAX_PLAYER_NAME * 2 + 8];
    SQLEscape(name, ename, sizeof ename);

    new q[256];
    format(q, sizeof q, "SELECT name FROM accounts WHERE name='%s' LIMIT 1;", ename);

    new DBResult:r = DB_ExecuteQuery(gDB, q);
    if (r == INVALID_RESULT) return false;

    new rows = DB_GetRowCount(r);
    DB_FreeResultSet(r);
    return (rows > 0);
}

stock bool:GetAccountPass(const name[], out_pass[], out_size)
{
    new ename[MAX_PLAYER_NAME * 2 + 8];
    SQLEscape(name, ename, sizeof ename);

    new q[256];
    format(q, sizeof q, "SELECT pass FROM accounts WHERE name='%s' LIMIT 1;", ename);

    new DBResult:r = DB_ExecuteQuery(gDB, q);
    if (r == INVALID_RESULT) return false;

    if (DB_GetRowCount(r) < 1)
    {
        DB_FreeResultSet(r);
        return false;
    }

    DB_GetFieldStringByName(r, "pass", out_pass, out_size);
    DB_FreeResultSet(r);
    return true;
}

stock bool:LoadAccount(playerid, const name[])
{
    new ename[MAX_PLAYER_NAME * 2 + 8];
    SQLEscape(name, ename, sizeof ename);

    new q[512];
    format(q, sizeof q, "SELECT id,money,x,y,z,a,hp,arm,skin,interior,vw FROM accounts WHERE name='%s' LIMIT 1;", ename);

    new DBResult:r = DB_ExecuteQuery(gDB, q);
    if (r == INVALID_RESULT) return false;

    if (DB_GetRowCount(r) < 1)
    {
        DB_FreeResultSet(r);
        return false;
    }

    PlayerData[playerid][AccountId] = DB_GetFieldIntByName(r, "id");
    PlayerData[playerid][Money]     = DB_GetFieldIntByName(r, "money");
    PlayerData[playerid][PX]       = DB_GetFieldFloatByName(r, "x");
    PlayerData[playerid][PY]       = DB_GetFieldFloatByName(r, "y");
    PlayerData[playerid][PZ]       = DB_GetFieldFloatByName(r, "z");
    PlayerData[playerid][PA]       = DB_GetFieldFloatByName(r, "a");
    PlayerData[playerid][Health]   = DB_GetFieldFloatByName(r, "hp");
    PlayerData[playerid][Armour]   = DB_GetFieldFloatByName(r, "arm");
    PlayerData[playerid][Skin]     = DB_GetFieldIntByName(r, "skin");
    PlayerData[playerid][Interior] = DB_GetFieldIntByName(r, "interior");
    PlayerData[playerid][VW]       = DB_GetFieldIntByName(r, "vw");

    DB_FreeResultSet(r);

    // Значения по умолчанию, если в БД нули
    if (PlayerData[playerid][Health] <= 0.0) PlayerData[playerid][Health] = 100.0;
    if (PlayerData[playerid][Skin] <= 0) PlayerData[playerid][Skin] = 0;

    return true;
}

stock bool:CreateAccount(const name[], const pass[])
{
    new ename[MAX_PLAYER_NAME * 2 + 8];
    new epass[128];
    SQLEscape(name, ename, sizeof ename);
    SQLEscape(pass, epass, sizeof epass);

    // Создание аккаунта
    new q[768];
    format(q, sizeof q,
    "INSERT INTO accounts (name,pass,money,x,y,z,a,hp,arm,skin,interior,vw) VALUES('%s','%s',5000,1958.3783,1343.1572,15.3746,270.0,100.0,0.0,0,0,0);",
    ename, epass
);

    new DBResult:r = DB_ExecuteQuery(gDB, q);
    if (r == INVALID_RESULT) return false;

    DB_FreeResultSet(r);
    return true;
}

stock SaveAccount(playerid)
{
    if (!PlayerData[playerid][Logged]) return 1;
    if (gDB == DB:0) return 1;
    if (PlayerData[playerid][AccountId] <= 0) return 1;

    new Float:x, Float:y, Float:z, Float:a;
    GetPlayerPos(playerid, x, y, z);
    GetPlayerFacingAngle(playerid, a);

    new Float:hp, Float:arm;
    GetPlayerHealth(playerid, hp);
    GetPlayerArmour(playerid, arm);

    new money = GetPlayerMoney(playerid);
    new skin = GetPlayerSkin(playerid);
    new interior = GetPlayerInterior(playerid);
    new vw = GetPlayerVirtualWorld(playerid);

    new q[768];
    format(q, sizeof q,
        "UPDATE accounts SET money=%d, x=%f, y=%f, z=%f, a=%f, hp=%f, arm=%f, skin=%d, interior=%d, vw=%d WHERE id=%d;",
        money, x, y, z, a, hp, arm, skin, interior, vw, PlayerData[playerid][AccountId]
    );

    new DBResult:r = DB_ExecuteQuery(gDB, q);
    if (r != INVALID_RESULT) DB_FreeResultSet(r);

    return 1;
}

// -------------------- auth flow helpers --------------------
stock StartAuth(playerid)
{
    gAwaitAuth[playerid] = true;
    gAuthAttempts[playerid] = 0;
    gRegPass[playerid][0] = '\0';

    TogglePlayerControllable(playerid, false);

    if (gAuthTimer[playerid] != 0)
    {
        KillTimer(gAuthTimer[playerid]);
        gAuthTimer[playerid] = 0;
    }
    gAuthTimer[playerid] = SetTimerEx("AuthTimeout", AUTH_TIMEOUT_MS, false, "i", playerid);

    ShowPlayerDialog(
        playerid,
        DIALOG_AUTH_CHOICE,
        DIALOG_STYLE_LIST,
        "Авторизация",
        "Вход\nРегистрация",
        "Выбрать",
        "Выход"
    );
    return 1;
}

stock FinishAuth(playerid)
{
    gAwaitAuth[playerid] = false;

    if (gAuthTimer[playerid] != 0)
    {
        KillTimer(gAuthTimer[playerid]);
        gAuthTimer[playerid] = 0;
    }

    TogglePlayerControllable(playerid, true);
    return 1;
}

public AuthTimeout(playerid)
{
    if (!IsPlayerConnected(playerid)) return 0;
    if (gAwaitAuth[playerid])
    {
        SendClientMessage(playerid, -1, "Вы не успели авторизоваться.");
        Kick(playerid);
    }
    return 1;
}

// -------------------- GM --------------------
public OnGameModeInit()
{
    gDB = DB_Open(DB_FILE);
    if (gDB == DB:0)
    {
        print("[DB] ERROR: cannot open database");
    }
    else
    {
        print("[DB] OK: database opened");
        DB_MigrateAccounts();
        AdminDB_Migrate();
        BanDB_CreateTable();
        Inv_DB_Migrate();
    }

    SetGameModeText("DEV MODE");

    AddPlayerClass(
        0,
        1958.3783, 1343.1572, 15.3746,
        270.0,
        WEAPON_FIST, 0,
        WEAPON_FIST, 0,
        WEAPON_FIST, 0
    );

    return 1;
}

public OnGameModeExit()
{
    if (gDB != DB:0)
    {
        DB_Close(gDB);
        gDB = DB:0;
        print("[DB] Closed");
    }
    return 1;
}

// -------------------- player --------------------
public OnPlayerConnect(playerid)
{
    PlayerData[playerid][Logged] = false;
    PlayerData[playerid][Loaded] = false;
    PlayerData[playerid][AccountId] = 0;

    Admin_OnPlayerConnect(playerid);

    if (gDB == DB:0)
    {
        SendClientMessage(playerid, -1, "Ошибка базы данных. Сервер временно недоступен.");
        Kick(playerid);
        return 1;
    }
    // Проверка бана при подключении
    new name[MAX_PLAYER_NAME];
    GetPlayerName(playerid, name, sizeof name);

    new ban_reason[128];
    if (BanDB_IsPlayerBanned(name, ban_reason, sizeof ban_reason))
    {
        new ban_msg[160];
        format(ban_msg, sizeof ban_msg, "Вы забанены. Причина: %s", ban_reason);
        SendClientMessage(playerid, -1, ban_msg);
        Kick(playerid);
        return 1;
    }
    StartAuth(playerid);
    return 1;
}
public OnPlayerDisconnect(playerid, reason)
{
    Inv_UnloadPlayer(playerid);
    SaveAccount(playerid);

    if (gAuthTimer[playerid] != 0)
    {
        KillTimer(gAuthTimer[playerid]);
        gAuthTimer[playerid] = 0;
    }

    gAwaitAuth[playerid] = false;
    gAuthAttempts[playerid] = 0;
    gRegPass[playerid][0] = '\0';

    PlayerData[playerid][Logged] = false;
    PlayerData[playerid][Loaded] = false;
    PlayerData[playerid][AccountId] = 0;

    Admin_OnPlayerDisconnect(playerid, reason);
    return 1;
}

public OnPlayerSpawn(playerid)
{
    SetCameraBehindPlayer(playerid);
    TogglePlayerControllable(playerid, true);

    Admin_OnPlayerSpawn(playerid);

    if (PlayerData[playerid][Logged] && PlayerData[playerid][Loaded])
    {
        // VW/Interior по данным (нужно после логина)
        SetPlayerVirtualWorld(playerid, PlayerData[playerid][VW]);
        SetPlayerInterior(playerid, PlayerData[playerid][Interior]);

        SetPlayerPos(playerid, PlayerData[playerid][PX], PlayerData[playerid][PY], PlayerData[playerid][PZ]);
        SetPlayerFacingAngle(playerid, PlayerData[playerid][PA]);

        SetPlayerHealth(playerid, PlayerData[playerid][Health]);
        SetPlayerArmour(playerid, PlayerData[playerid][Armour]);

        SetPlayerSkin(playerid, PlayerData[playerid][Skin]);

        ResetPlayerMoney(playerid);
        GivePlayerMoney(playerid, PlayerData[playerid][Money]);

        // Apply equip effects (armour/backpack) after spawn.
        Inv_RefreshPlayerEquip(playerid);
    }
    else
    {
        SetPlayerHealth(playerid, 100.0);
        SetPlayerArmour(playerid, 0.0);

        ResetPlayerMoney(playerid);
        GivePlayerMoney(playerid, 5000);
    }

    SetTimerEx("FixInput", 200, false, "i", playerid);
    return 1;
}

public OnPlayerKeyStateChange(playerid, KEY:newkeys, KEY:oldkeys)
{
    if ((newkeys & INV_OPEN_KEY) && !(oldkeys & INV_OPEN_KEY))
    {
        Inv_OpenMainDialog(playerid);
    }
    return 1;
}

public FixInput(playerid)
{
    if (!IsPlayerConnected(playerid)) return 0;
    TogglePlayerControllable(playerid, true);
    SetCameraBehindPlayer(playerid);
    return 1;
}

// Запрет чата до авторизации
public OnPlayerText(playerid, text[])
{
    if (gAwaitAuth[playerid])
    {
        SendClientMessage(playerid, -1, "Сначала пройдите авторизацию.");
        return 0;
    }

    if (!Admin_OnPlayerText(playerid, text)) return 0;
    return 1;
}

// -------------------- dialogs --------------------
public OnDialogResponse(playerid, dialogid, response, listitem, inputtext[])
{
    if (!IsPlayerConnected(playerid)) return 0;

    if (Inv_OnDialogResponse(playerid, dialogid, response, listitem, inputtext)) return 1;

    if (dialogid == DIALOG_AUTH_CHOICE)
    {
        if (!response) { Kick(playerid); return 1; }

        if (listitem == 0)
        {
            ShowPlayerDialog(playerid, DIALOG_AUTH_LOGIN, DIALOG_STYLE_PASSWORD,
                "Вход",
                "Введите пароль:",
                "Войти",
                "Назад"
            );
            return 1;
        }
        else
        {
            ShowPlayerDialog(playerid, DIALOG_AUTH_REG_1, DIALOG_STYLE_PASSWORD,
                "Регистрация",
                "Придумайте пароль (мин. 4 символа):",
                "Далее",
                "Назад"
            );
            return 1;
        }
    }

    if (dialogid == DIALOG_AUTH_LOGIN)
    {
        if (!response)
        {
            ShowPlayerDialog(playerid, DIALOG_AUTH_CHOICE, DIALOG_STYLE_LIST, "Авторизация", "Вход\nРегистрация", "Выбрать", "Выход");
            return 1;
        }

        if (strlen(inputtext) < 1)
        {
            ShowPlayerDialog(playerid, DIALOG_AUTH_LOGIN, DIALOG_STYLE_PASSWORD, "Вход", "Пароль не может быть пустым.\nВведите пароль:", "Войти", "Назад");
            return 1;
        }

        new name[MAX_PLAYER_NAME];
        GetPlayerName(playerid, name, sizeof name);

        if (!AccountExists(name))
        {
            ShowPlayerDialog(playerid, DIALOG_AUTH_REG_1, DIALOG_STYLE_PASSWORD, "Регистрация", "Аккаунт не найден.\nПридумайте пароль (мин. 4 символа):", "Далее", "Назад");
            return 1;
        }

        new dbpass[64];
        if (!GetAccountPass(name, dbpass, sizeof dbpass))
        {
            SendClientMessage(playerid, -1, "Ошибка базы данных.");
            Kick(playerid);
            return 1;
        }

        if (strcmp(inputtext, dbpass, false) != 0)
        {
            gAuthAttempts[playerid]++;
            if (gAuthAttempts[playerid] >= AUTH_MAX_ATTEMPTS)
            {
                SendClientMessage(playerid, -1, "Слишком много попыток.");
                Kick(playerid);
                return 1;
            }

            ShowPlayerDialog(playerid, DIALOG_AUTH_LOGIN, DIALOG_STYLE_PASSWORD,
                "Вход",
                "Неверный пароль.\nВведите пароль:",
                "Войти",
                "Назад"
            );
            return 1;
        }

        if (!LoadAccount(playerid, name))
        {
            SendClientMessage(playerid, -1, "Ошибка загрузки аккаунта.");
            Kick(playerid);
            return 1;
        }
        // Загрузка админ-уровня
        AdminDB_LoadLevel(playerid);
        PlayerData[playerid][Logged] = true;
        PlayerData[playerid][Loaded] = true;

        if (!Inv_LoadPlayer(playerid))
        {
            SendClientMessage(playerid, -1, "[INV] Ошибка загрузки инвентаря.");
            Kick(playerid);
            return 1;
        }

        FinishAuth(playerid);
        SendClientMessage(playerid, -1, "Вы успешно вошли. Спавн...");
        SpawnPlayer(playerid);
        return 1;
    }

    if (dialogid == DIALOG_AUTH_REG_1)
    {
        if (!response)
        {
            ShowPlayerDialog(playerid, DIALOG_AUTH_CHOICE, DIALOG_STYLE_LIST, "Авторизация", "Вход\nРегистрация", "Выбрать", "Выход");
            return 1;
        }

        if (strlen(inputtext) < 4)
        {
            ShowPlayerDialog(playerid, DIALOG_AUTH_REG_1, DIALOG_STYLE_PASSWORD, "Регистрация", "Пароль слишком короткий.\nПридумайте пароль (мин. 4 символа):", "Далее", "Назад");
            return 1;
        }

        new name[MAX_PLAYER_NAME];
        GetPlayerName(playerid, name, sizeof name);

        if (AccountExists(name))
        {
            ShowPlayerDialog(playerid, DIALOG_AUTH_LOGIN, DIALOG_STYLE_PASSWORD, "Вход", "Аккаунт уже зарегистрирован.\nВведите пароль:", "Войти", "Назад");
            return 1;
        }

        format(gRegPass[playerid], sizeof gRegPass[], "%s", inputtext);

        ShowPlayerDialog(playerid, DIALOG_AUTH_REG_2, DIALOG_STYLE_PASSWORD,
            "Регистрация",
            "Подтвердите пароль:",
            "Готово",
            "Назад"
        );
        return 1;
    }

    if (dialogid == DIALOG_AUTH_REG_2)
    {
        if (!response)
        {
            ShowPlayerDialog(playerid, DIALOG_AUTH_REG_1, DIALOG_STYLE_PASSWORD, "Регистрация", "Придумайте пароль (мин. 4 символа):", "Далее", "Назад");
            return 1;
        }

        if (strcmp(inputtext, gRegPass[playerid], false) != 0)
        {
            gRegPass[playerid][0] = '\0';
            ShowPlayerDialog(playerid, DIALOG_AUTH_REG_1, DIALOG_STYLE_PASSWORD,
                "Регистрация",
                "Пароли не совпадают.\nВведите пароль заново:",
                "Далее",
                "Назад"
            );
            return 1;
        }

        new name[MAX_PLAYER_NAME];
        GetPlayerName(playerid, name, sizeof name);

        if (AccountExists(name))
        {
            ShowPlayerDialog(playerid, DIALOG_AUTH_LOGIN, DIALOG_STYLE_PASSWORD, "Вход", "Аккаунт уже зарегистрирован.\nВведите пароль:", "Войти", "Назад");
            return 1;
        }

        if (!CreateAccount(name, gRegPass[playerid]))
        {
            SendClientMessage(playerid, -1, "Ошибка регистрации (БД).");
            Kick(playerid);
            return 1;
        }

        gRegPass[playerid][0] = '\0';
        SendClientMessage(playerid, -1, "Регистрация успешна. Теперь войдите.");

        ShowPlayerDialog(playerid, DIALOG_AUTH_LOGIN, DIALOG_STYLE_PASSWORD,
            "Вход",
            "Введите пароль:",
            "Войти",
            "Назад"
        );
        return 1;
    }

    return 0;
}

// Required to avoid "bad entry point" in some setups
main() {}











