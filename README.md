# RPGMCheat — Universal In-Game Cheat Menu & RGSS Decryptor for RPG Maker

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Engines: MV MZ VXAce VX XP mkxp](https://img.shields.io/badge/Engines-MV%20%7C%20MZ%20%7C%20VXAce%20%7C%20VX%20%7C%20XP%20%7C%20mkxp-brightgreen.svg)](#supported-engines--encrypted-archives)
[![Zero-Dependency](https://img.shields.io/badge/Zero--Dependencies-Windows%20PowerShell%20%2B%20Python3%20std-orange.svg)](#quick-installation)

A self-contained in-game cheat menu with **zero-Ruby / zero-Python installers** and a **built-in RGSS archive decryptor/patcher** (`Game.rgss3a`, `Game.rgss2a`, `Game.rgssad`). Automatically detects the RPG Maker engine and folder layout — even if you point to `www/`, `data/`, `Game.exe`, `.rgss3a`, or a parent wrapper directory.

---

## Supported Engines & Encrypted Archives

| Engine | Architecture | Layout / Archive Detected Automatically | Cheat Payload |
| :--- | :--- | :--- | :--- |
| **RPG Maker MV** | NW.js / JavaScript | `www/js/plugins.js`, `www/index.html`, `www/data/*.json` | `cheat.js` |
| **RPG Maker MZ** | NW.js / JavaScript | `js/plugins.js`, `index.html`, `data/*.json` | `cheat.js` |
| **RPG Maker VX Ace** | RGSS3 / Ruby 1.9 | `Data/Scripts.rvdata2`, **`Game.rgss3a`**, or custom `Game.ini` | `cheat.rb` |
| **RPG Maker VX** | RGSS2 / Ruby 1.8 | `Data/Scripts.rvdata`, **`Game.rgss2a`**, or custom `Game.ini` | `cheat.rb` |
| **RPG Maker XP** | RGSS1 / Ruby 1.8 | `Data/Scripts.rxdata`, **`Game.rgssad`**, or custom `Game.ini` | `cheat.rb` |
| **mkxp / mkxp-z** | RGSS1–3 / Ruby 3.x | `Data/Scripts.*` or `mkxp.json` `preloadScript` | `cheat.rb` |

---

## Features

- **Direct `Game.rgss3a` / `.rgss2a` / `.rgssad` Surgical Patching** — Injects the cheat menu directly into encrypted RGSS archives in milliseconds **without** needing to extract gigabytes of assets first. Clean bit-exact rollback with `--remove`.
- **Standalone Archive Decryptor** (`decrypt.bat` / `--decrypt`) — Extracts all `Data/`, `Graphics/`, and `Audio/` files from `.rgss3a`, `.rgss2a`, `.rgssad` to disk on demand, renaming original archives so the game runs loose files.
- **Edit Owned Inventory (`1.Bag`)** — View held items, weapons, and armors (including `YEP_ItemCore` independent items in MV), adjust stack counts (`+-1`, `+-10`, `+-100`, or exact digit input down to `0` to remove), and edit party Gold.
- **Obtain Any Database Item (`2.Items`, `3.Weapons`, `4.Armors`)** — Browse `$data_items` / `$dataItems`, weapons, and armors with descriptions, empty-slot filtering (`[S]`), and live search filter (`[F]` in MV/MZ).
- **Edit Actor Stats (`5.Stats`)** — Cycle through party members (`[A]`), edit `Level`, current `HP`/`MP`/`SP`, and all core parameters (`MHP`, `MMP`, `ATK`, `DEF`, `MAT`, `MDF`, `AGI`, `LUK` / `STR`, `DEX`, `INT`, `SPI`), or heal instantly (`[S]`).
- **Runtime Cheats & QoL (`6.Cheats`)**:
  - **Defeat All Enemies in Battle** — Instant battle victory / eliminate active enemies without tedious grinding.
  - **Always Enable Saving** — Save anywhere, even in dungeons or restricted areas where save points are disabled.
  - **God Mode** — Automatic per-frame party restore (HP/MP).
  - **Walk Through Walls (Noclip)** — Pass through impassable map tiles and event blocks.
  - **Disable Random Encounters** — Explore map without monster interruptions.
  - **Stat Uncap (`999,999`)** & **Item Stack Uncap (`9,999`)** — Bypass engine-level maximums without corrupting saves.
  - **Mass Item Grants** — Grant +1 or +10 of every database item in one click.
- **Mobile, Steam Deck & Touch Support** — Supports 3-finger touch tap on Android/JoiPlay/touchscreens in MV/MZ, and exposes `window.RPGMCheat.toggle()` for console / DevTools.
- **3D & Custom-UI Safe Overlay** — Isolated DOM overlay above Canvas/WebGL in MV/MZ (compatible with `MV3D`, `SRD_HUDMaker`, `Yanfly`, `VisuStella`) and raw `Sprite + Bitmap` in RGSS without changing active scenes.

---

## Quick Installation

You can pass **any** path related to the game: the root folder (`Project1`), `Project1\www`, `www\data`, `Game.rgss3a`, `Game.exe`, or a parent directory.

### Option 1: Windows (No Ruby, No Python Required)

Uses built-in Windows PowerShell + `.NET` (`inject.bat` & `decrypt.bat`):

- **Double-Click / Drag & Drop:** Double-click `inject.bat` and paste the folder path, or drag your game folder directly onto `inject.bat`. *(Works automatically even on encrypted `.rgss3a` / `.rgss2a` / `.rgssad`!)*
- **Command Line:**
  ```bat
  inject.bat "C:\Games\MyGame"
  inject.bat --remove "C:\Games\MyGame"
  ```
- **Full Archive Unpacker (Optional):**
  ```bat
  decrypt.bat "C:\Games\MyGame"
  :: or: inject.bat --decrypt "C:\Games\MyGame"
  ```

### Option 2: Linux / macOS (Python 3 Standard Library)

```bash
# Install cheat (auto-detects engine & archives):
./inject.sh "/path/to/MyGame"

# Optional: extract all files from .rgss3a/.rgss2a/.rgssad to disk:
./decrypt.sh "/path/to/MyGame"

# Uninstall cleanly (restores original archive):
./inject.sh --remove "/path/to/MyGame"
```

*(Optional: for RGSS games, pass `--standalone` to embed `cheat.rb` solely inside the game scripts without placing `cheat.rb` in the game root).*

### Option 3: Manual Installation

- **RPG Maker MV / MZ:** Copy `cheat.js` to `www/js/plugins/RPGMCheat.js` (MV) or `js/plugins/RPGMCheat.js` (MZ) and enable `RPGMCheat` in `plugins.js` — or add `<script src="js/rpgm_cheat.js"></script>` before `</body>` in `index.html`.
- **RPG Maker XP / VX / VX Ace:** Open Script Editor (`F11`), insert a new section right above `Main`, and paste `cheat.rb`.
- **mkxp / mkxp-z:** Copy `cheat.rb` to the game root and set `"preloadScript": ["cheat.rb"]` in `mkxp.json`.

---

## In-Game Controls

| Key | Action |
| :--- | :--- |
| **`F8`** | Open / close the cheat menu |
| **3-Finger Tap** *(MV/MZ)* | Open / close on touchscreen (mobile / Android / Steam Deck) |
| **`Q` / `W`** (`PageUp` / `PageDown`) | Switch between tabs (`1..6`) |
| **`Up` / `Down`** | Move selection (hold **`Ctrl`** to jump 10 rows) |
| **`Left` / `Right`** | Adjust item count / stat by `+-1` (`+-100` for Gold) |
| **`Shift` + `Left` / `Right`** | Adjust by `+-10` (`+-1000` for Gold) |
| **`Ctrl` + `Left` / `Right`** | Adjust by `+-100` (`+-10000` for Gold) |
| **`Enter` / `Space` / `Z`** | Open **Exact Number Editor** (type `0-9` directly or use arrows) / toggle option |
| **`A`** | Switch actor in `5.Stats` / refresh `1.Bag` / set minimum in number editor |
| **`S`** | Show/hide unnamed DB entries (`2-4`) / heal actor (`5`) / set maximum in number editor |
| **`F` or `/`** *(MV/MZ)* | Live search filter by item name or ID (`2.Items`, `3.Weapons`, `4.Armors`) |
| **`Esc` / `X`** | Cancel popup / search or close the cheat menu |

---

## Developer & Console API (MV / MZ)

If you are running the game with DevTools enabled (`F12`), you can control the cheat system via console:

```javascript
RPGMCheat.open();       // Opens the cheat overlay
RPGMCheat.close();      // Closes the cheat overlay
RPGMCheat.toggle();     // Toggles open/close state
RPGMCheat.godMode = true;
RPGMCheat.noclip = true;
```

---


---

## License

This project is licensed under the [MIT License](LICENSE).
