# Architecture

```text
user ROM
   |
   v
SHA-1 validation
   |
   v
Gen1Recomp importer
   |
   +--> local ROM-derived cache
   |
   v
Dramatic Shape downloaded locally
   |
   v
compatibility/launcher integration
   |
   v
private LÖVE runtime
   |
   v
compressed payload
   |
   v
single user-facing EXE
```

The repository itself contains none of the ROM, generated cache, runtime
downloads or Dramatic Shape source.

## Runtime materialization

Windows must load native DLLs from files. Therefore the single EXE embeds the
private runtime and materializes it to `%LOCALAPPDATA%` before launching the
game. This is transparent to the distributed artifact: only the EXE needs to
be copied by the user.


## 3D WIDE battle frame fix

Dramatic Shape can provide a complete battle scene through
`Renderer.worldOverride`. In this path, the scene already owns the full
window.

The builder patches Gen1Recomp so the stock `battleDim` surround veil is not
drawn a second time over that full-window provider scene:

```lua
if self.battleDim and self.battleDim > 0 and not self.worldOverride then
```

Normal 2D battles still use `battleDim`. Dramatic Shape 3D WIDE battles keep
the complete arena visible to the left and right instead of receiving dark
side frames.
