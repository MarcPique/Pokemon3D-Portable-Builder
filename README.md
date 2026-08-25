<div align="center">

# 🎮 Pokémon 3D Portable Builder

### Gen1Recomp + Dramatic Shape · Windows · Single EXE

**Build your own Red / Blue / Yellow 3D Windows portable from your legally owned ROM.**

[![Windows](https://img.shields.io/badge/Windows-10%20%7C%2011-0078D6?style=for-the-badge&logo=windows11&logoColor=white)](#requirements)
[![PowerShell](https://img.shields.io/badge/PowerShell-Automated-5391FE?style=for-the-badge&logo=powershell&logoColor=white)](#quick-start)
[![Single EXE](https://img.shields.io/badge/Output-Single%20EXE-success?style=for-the-badge)](#single-exe)
[![3D WIDE Fix](https://img.shields.io/badge/3D%20Battles-WIDE%20Bars%20Fixed-brightgreen?style=for-the-badge)](#3d-wide-battle-black-bar-fix)
[![No ROMs](https://img.shields.io/badge/ROMs-Not%20Included-important?style=for-the-badge)](#important-repository-policy)

</div>

---

## ✨ Highlights

| Feature | Status |
|---|---|
| Red / Blue / Yellow | ✅ |
| Gen1Recomp auto-download | ✅ |
| Dramatic Shape auto-download | ✅ |
| 3D voxel overworld | ✅ |
| 3D battles | ✅ |
| **3D WIDE black side bars fixed** | ✅ |
| Borderless fullscreen / 4K | ✅ |
| Xbox / XInput | ✅ |
| Palette selector | ✅ |
| Persistent dependency cache | ✅ |
| Direct boot | ✅ |
| Per-game AppData saves | ✅ |
| **Single user-facing EXE** | ✅ |

> [!IMPORTANT]
> You must provide your **own legally obtained ROM dump**.  
> This repository does not contain ROMs, extracted game data, Pokémon box artwork, or bundled Dramatic Shape source.

## Important repository policy

This repository contains:

- the builder scripts;
- launcher/build integration code;
- documentation;
- GitHub CI configuration.

It intentionally contains **no**:

- Pokémon ROMs;
- ROM-derived caches;
- Pokémon box artwork;
- prebuilt game executables;
- downloaded Gen1Recomp/LÖVE binaries;
- Dramatic Shape source or archive.

Dependencies are downloaded from their upstream projects when the user builds
locally.

## Features

- Red / Blue / Yellow SHA-1 validation.
- Persistent `_deps` download cache.
- Automatic Gen1Recomp ROM import.
- Dramatic Shape integration downloaded at build time.
- Resolution and borderless fullscreen controls.
- XInput/controller option.
- Gen1Recomp gameplay, battle, speed, audio and display options.
- Palette selector.
- Dramatic Shape / voxel controls.
- Direct boot without asking for the ROM after build.
- Per-edition AppData saves.
- Optional local cover-based Windows icon.
- Single user-facing EXE with embedded private runtime payload.
- **3D WIDE battle black side bars fixed** when using Dramatic Shape.


## 🚀 One-click build flow

```text
Your legal Red / Blue / Yellow ROM
              │
              ▼
      SHA-1 verification
              │
              ▼
      Gen1Recomp importer
              │
              ▼
   Dramatic Shape integration
              │
              ▼
      Custom launcher setup
              │
              ▼
   Runtime + cache embedded
              │
              ▼
     Pokemon 3D Portable.exe
```

## Requirements

- Windows 10 or Windows 11 x64.
- Internet connection on the first build.
- Your own legally obtained canonical Red, Blue or Yellow ROM dump.
- Windows PowerShell.

The normal workflow does not require the user to manually install LÖVE,
Gen1Recomp, rcedit, Git, CMake or Visual Studio.

## Quick start

Clone or download this repository, then run:

```bat
BUILD_POKEMON_3D_PORTABLE_AUTO.bat
```

Select your own ROM when asked.

The final build is placed under:

```text
dist/
```

## Supported hashes

| Edition | SHA-1 |
|---|---|
| Red | `ea9bcae617fdf159b045185467ae58b2e4a48b9a` |
| Blue | `d7037c83e1ae5b39bde3c30787637ba1d4c48ce2` |
| Yellow | `cc7d03262ebfaf2f06772c1a480c7d9d5f4a38e1` |

These are the canonical US/English ROM inputs used by the current Gen1Recomp
workflow. The repository does not provide them.

## Dependency cache

Downloaded dependencies are kept in:

```text
_deps/
```

They are reused on later builds.

To force a refresh from `cmd.exe`:

```bat
set FORCE_DEP_UPDATE=1
BUILD_POKEMON_3D_PORTABLE_AUTO.bat
```

`_deps/` is excluded by `.gitignore`.

## Optional local cover icons

Pokémon box artwork is not included in this repository.

You can locally add:

```text
covers/red.jpg
covers/blue.jpg
covers/yellow.jpg
```

The builder will use the matching image for the Windows executable/taskbar
icon. These files are ignored by Git.

If they are absent, the build continues with the default executable icon.

## Single EXE

The distribution is designed around:

```text
Pokemon 3D Portable.exe
```

The native runtime and private generated cache are embedded as a compressed
payload. When needed, the launcher materializes that payload under:

```text
%LOCALAPPDATA%\Pokemon3DPortableRuntime\
```

This is an implementation/runtime cache. The user-facing distribution remains
a single EXE.

Saves remain separate:

```text
%APPDATA%\PokemonRed\saves\
%APPDATA%\PokemonBlue\saves\
%APPDATA%\PokemonYellow\saves\
```

## 3D WIDE battle black-bar fix

> [!TIP]
> **WIDE 3D battles no longer get the previous dark/black side frames.**
> The builder detects Dramatic Shape's full-window `worldOverride` path and
> prevents Gen1Recomp from applying the stock surround-darkening veil a second time.


**The black side bars that appeared during Dramatic Shape 3D battles in WIDE /
fullscreen configurations are fixed by this builder.**

The issue was not the user's display resolution or the WIDE setting itself.
Dramatic Shape already supplies a complete full-window 3D battle scene through
Gen1Recomp's `worldOverride`. Gen1Recomp could then apply its normal
`BATTLE BG = WORLD` surround-dimming pass (`battleDim`) on top of that
already-composed scene, which made the side regions appear as dark/black
frames during 3D battles.

The builder applies a narrow compatibility patch so that:

```text
2D / normal battle
  -> battleDim works normally

Dramatic Shape 3D battle + worldOverride
  -> full 3D arena remains visible across the WIDE screen
  -> no extra black side-bar veil is applied
```

This means users can keep configurations such as:

```text
Borderless Fullscreen
Faithful Ratio: OFF
Battle Layout: WIDE
Battle Size: FILL
Battle BG: WORLD
3D-BTL: ON
```

without the previous black side frames being added by the Gen1Recomp
surround-dimming pass.

The user's normal battle background preference is not deleted or globally
disabled; the compatibility exception applies only when a full-window
`worldOverride` is present.


## Upstream projects

- Gen1Recomp: https://github.com/bryanthaboi/gen1recomp
- Dramatic Shape Voxel Mod: https://github.com/scottcandy34/DramaticShapeVoxelMod-latest
- LÖVE: https://love2d.org/

Gen1Recomp describes its game data and graphics as being decoded from a ROM
supplied by the player. Dramatic Shape's upstream README explicitly restricts
redistribution of its non-derivative code after v1.6.0. For that reason, this
repository does not vendor the mod and downloads it from upstream during the
local build.

## Repository safety

Do not commit:

- ROMs or cartridge dumps;
- generated `red/`, `blue/`, or `yellow/` data;
- `_deps/`;
- `_work/`;
- `dist/`;
- generated EXEs;
- Pokémon box artwork;
- copies of Dramatic Shape source.

The included GitHub Actions workflow checks for accidental repository
contamination and validates PowerShell syntax.

## Legal notice

Pokémon and related names, artwork, characters and trademarks belong to their
respective owners. This project is not affiliated with or endorsed by those
owners.

Use only ROM dumps and artwork you are legally entitled to use.

## Status

Experimental. Gen1Recomp and Dramatic Shape are active upstream projects, so
future upstream revisions may require compatibility updates.


## 🏷️ Suggested GitHub topics

```text
pokemon
gen1recomp
dramatic-shape
love2d
windows
powershell
game-modding
voxel
portable
single-exe
pokemon-yellow
pokemon-red
pokemon-blue
```

---

<div align="center">

**Unofficial community tooling · Bring your own legal ROM · No ROMs included**

</div>
