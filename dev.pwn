#include <open.mp>
#include <omp_database>

#define DB_FILE "server.db"
#define INVALID_RESULT (DBResult:0)

// ---- Диалоги
#define DIALOG_AUTH_CHOICE     1000
#define DIALOG_AUTH_LOGIN      1001
#define DIALOG_AUTH_REG_1      1002
#define DIALOG_AUTH_REG_2      1003

// ---- Настройки авторизации
#define AUTH_TIMEOUT_MS        30000
#define AUTH_MAX_ATTEMPTS      3

new DB:gDB;

enum E_PLAYER_DATA
{
    bool:Logged,
    bool:Loaded,

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

// состояние авторизации
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

#include "admin.pwn"

// -------------------- DB миграция (чтобы старая БД не ломалась) --------------------
stock DB_MigrateAccounts()
{
    // базовая таблица (если нет)
    DB_ExecuteQuery(gDB, "CREATE TABLE IF NOT EXISTS accounts (name TEXT PRIMARY KEY, pass TEXT, money INTEGER, x REAL, y REAL, z REAL, a REAL, hp REAL, arm REAL, skin INTEGER, interior INTEGER, vw INTEGER);");

    // добавляем колонки в старую таблицу (если уже была без них)
    DB_ExecuteQuery(gDB, "ALTER TABLE accounts ADD COLUMN a REAL;");
    DB_ExecuteQuery(gDB, "ALTER TABLE accounts ADD COLUMN hp REAL;");
    DB_ExecuteQuery(gDB, "ALTER TABLE accounts ADD COLUMN arm REAL;");
    DB_ExecuteQuery(gDB, "ALTER TABLE accounts ADD COLUMN skin INTEGER;");
    DB_ExecuteQuery(gDB, "ALTER TABLE accounts ADD COLUMN interior INTEGER;");
    DB_ExecuteQuery(gDB, "ALTER TABLE accounts ADD COLUMN vw INTEGER;");
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
    format(q, sizeof q, "SELECT money,x,y,z,a,hp,arm,skin,interior,vw FROM accounts WHERE name='%s' LIMIT 1;", ename);

    new DBResult:r = DB_ExecuteQuery(gDB, q);
    if (r == INVALID_RESULT) return false;

    if (DB_GetRowCount(r) < 1)
    {
        DB_FreeResultSet(r);
        return false;
    }

    PlayerData[playerid][Money]    = DB_GetFieldIntByName(r, "money");
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

    // значения по умолчанию, если в БД нули
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

    // стартовые значения
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

    new name[MAX_PLAYER_NAME];
    GetPlayerName(playerid, name, sizeof name);

    new ename[MAX_PLAYER_NAME * 2 + 8];
    SQLEscape(name, ename, sizeof ename);

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
        "UPDATE accounts SET money=%d, x=%f, y=%f, z=%f, a=%f, hp=%f, arm=%f, skin=%d, interior=%d, vw=%d WHERE name='%s';",
        money, x, y, z, a, hp, arm, skin, interior, vw, ename
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
        "Войти\nРегистрация",
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

    Admin_OnPlayerConnect(playerid);

    if (gDB == DB:0)
    {
        SendClientMessage(playerid, -1, "Ошибка базы данных. Сервер настроен неверно.");
        Kick(playerid);
        return 1;
    }
    // Проверяем бан при подключении
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
        // VW/Interior до позиции (иначе могут быть глюки)
        SetPlayerVirtualWorld(playerid, PlayerData[playerid][VW]);
        SetPlayerInterior(playerid, PlayerData[playerid][Interior]);

        SetPlayerPos(playerid, PlayerData[playerid][PX], PlayerData[playerid][PY], PlayerData[playerid][PZ]);
        SetPlayerFacingAngle(playerid, PlayerData[playerid][PA]);

        SetPlayerHealth(playerid, PlayerData[playerid][Health]);
        SetPlayerArmour(playerid, PlayerData[playerid][Armour]);

        SetPlayerSkin(playerid, PlayerData[playerid][Skin]);

        ResetPlayerMoney(playerid);
        GivePlayerMoney(playerid, PlayerData[playerid][Money]);
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

public FixInput(playerid)
{
    if (!IsPlayerConnected(playerid)) return 0;
    TogglePlayerControllable(playerid, true);
    SetCameraBehindPlayer(playerid);
    return 1;
}

// блокируем чат до авторизации
public OnPlayerText(playerid, text[])
{
    if (gAwaitAuth[playerid])
    {
        SendClientMessage(playerid, -1, "Сначала войдите или зарегистрируйтесь.");
        return 0;
    }

    if (!Admin_OnPlayerText(playerid, text)) return 0;
    return 1;
}

// -------------------- dialogs --------------------
public OnDialogResponse(playerid, dialogid, response, listitem, inputtext[])
{
    if (!IsPlayerConnected(playerid)) return 0;

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
                "Придумайте пароль (минимум 4 символа):",
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
            ShowPlayerDialog(playerid, DIALOG_AUTH_CHOICE, DIALOG_STYLE_LIST, "Авторизация", "Войти\nРегистрация", "Выбрать", "Выход");
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
                "Неверный пароль.\nПопробуйте снова:",
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
        // Загружаем админ-уровень
        AdminDB_LoadLevel(playerid);
        PlayerData[playerid][Logged] = true;
        PlayerData[playerid][Loaded] = true;

        FinishAuth(playerid);
        SendClientMessage(playerid, -1, "Вход выполнен. Спавн...");
        SpawnPlayer(playerid);
        return 1;
    }

    if (dialogid == DIALOG_AUTH_REG_1)
    {
        if (!response)
        {
            ShowPlayerDialog(playerid, DIALOG_AUTH_CHOICE, DIALOG_STYLE_LIST, "Авторизация", "Войти\nРегистрация", "Выбрать", "Выход");
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
            ShowPlayerDialog(playerid, DIALOG_AUTH_LOGIN, DIALOG_STYLE_PASSWORD, "Вход", "Аккаунт уже существует.\nВведите пароль:", "Войти", "Назад");
            return 1;
        }

        format(gRegPass[playerid], sizeof gRegPass[], "%s", inputtext);

        ShowPlayerDialog(playerid, DIALOG_AUTH_REG_2, DIALOG_STYLE_PASSWORD,
            "Регистрация",
            "Повторите пароль:",
            "Создать",
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
                "Пароли не совпали.\nВведите пароль заново:",
                "Далее",
                "Назад"
            );
            return 1;
        }

        new name[MAX_PLAYER_NAME];
        GetPlayerName(playerid, name, sizeof name);

        if (AccountExists(name))
        {
            ShowPlayerDialog(playerid, DIALOG_AUTH_LOGIN, DIALOG_STYLE_PASSWORD, "Вход", "Аккаунт уже существует.\nВведите пароль:", "Войти", "Назад");
            return 1;
        }

        if (!CreateAccount(name, gRegPass[playerid]))
        {
            SendClientMessage(playerid, -1, "Ошибка регистрации (БД).");
            Kick(playerid);
            return 1;
        }

        gRegPass[playerid][0] = '\0';
        SendClientMessage(playerid, -1, "Аккаунт создан. Теперь войдите.");

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
