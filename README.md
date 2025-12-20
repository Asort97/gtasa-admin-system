# GTA SA Admin System

Advanced admin system for open.mp GTA:SA servers.

## Features

- **5-level admin hierarchy** (Level 1-4 + Owner)
- **Player management**: kick, ban, mute, teleport
- **Admin chat** with @ prefix
- **SQLite database** for bans and admin levels
- **Action logging** with UTF-8 support
- **Test commands**: /veh, /fly, /giveitem

## Commands

**Level 1**: `/a`, `/kick`, `/goto`, `/gethere`  
**Level 2**: `/mute`, `/unmute`  
**Level 4**: `/ban`, `/unban`  
**Level 5**: `/setadmin`  
**Info**: `/admin`

## Requirements

- open.mp server
- omp_database module
- sscanf2 plugin

## License

MIT
