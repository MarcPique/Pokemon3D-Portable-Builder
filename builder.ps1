param(
    [string]$Rom = ""
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version 2.0

$Root = Split-Path -Parent $MyInvocation.MyCommand.Path
$Work = Join-Path $Root "_work"
$Dist = Join-Path $Root "dist"
$Deps = Join-Path $Root "_deps"
$Headers = @{ "User-Agent" = "Pokemon3DPortableBuilder/2.0" }

function Write-Step([string]$Text) {
    Write-Host ""
    Write-Host "==> $Text" -ForegroundColor Cyan
}

function Fail([string]$Text) {
    Write-Host ""
    Write-Host "ERROR: $Text" -ForegroundColor Red
    exit 1
}

function Download-File([string]$Url, [string]$OutFile) {
    $parent = Split-Path -Parent $OutFile
    if ($parent) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
    Write-Host "Descargando: $Url"
    try {
        Invoke-WebRequest -UseBasicParsing -Headers $Headers -Uri $Url -OutFile $OutFile
    } catch {
        Fail ("No se pudo descargar " + $Url + "`n" + $_.Exception.Message)
    }
}


function Test-CachedFile(
    [string]$Path,
    [long]$MinBytes = 1024
) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return $false
    }

    try {
        return (Get-Item -LiteralPath $Path -ErrorAction Stop).Length -ge $MinBytes
    }
    catch {
        return $false
    }
}

function Test-CachedZip(
    [string]$Path,
    [long]$MinBytes = 1024
) {
    if (-not (Test-CachedFile $Path $MinBytes)) {
        return $false
    }

    try {
        Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction SilentlyContinue
        $z = [System.IO.Compression.ZipFile]::OpenRead($Path)
        try {
            return $z.Entries.Count -gt 0
        }
        finally {
            $z.Dispose()
        }
    }
    catch {
        return $false
    }
}

function Show-Cached(
    [string]$Name,
    [string]$Path
) {
    $sizeMB = [math]::Round((Get-Item -LiteralPath $Path).Length / 1MB, 2)
    Write-Host ("[YA DESCARGADO] " + $Name + " (" + $sizeMB + " MB)") -ForegroundColor Green
    Write-Host ("  " + $Path) -ForegroundColor DarkGray
}

function Get-CachedFile(
    [string]$Name,
    [string]$Url,
    [string]$Path,
    [long]$MinBytes = 1024
) {
    if (Test-CachedFile $Path $MinBytes) {
        Show-Cached $Name $Path
        return $Path
    }

    if (Test-Path -LiteralPath $Path) {
        Write-Host ("[CACHE INVALIDO] " + $Name + " -> se volvera a descargar.") -ForegroundColor Yellow
        Remove-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
    }

    Write-Host ("[DESCARGANDO] " + $Name) -ForegroundColor Cyan
    Download-File $Url $Path

    if (-not (Test-CachedFile $Path $MinBytes)) {
        Fail ("La descarga no parece valida: " + $Name)
    }

    return $Path
}

function Get-CachedZip(
    [string]$Name,
    [string]$Url,
    [string]$Path,
    [long]$MinBytes = 1024
) {
    if (Test-CachedZip $Path $MinBytes) {
        Show-Cached $Name $Path
        return $Path
    }

    if (Test-Path -LiteralPath $Path) {
        Write-Host ("[CACHE INVALIDO] " + $Name + " -> se volvera a descargar.") -ForegroundColor Yellow
        Remove-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
    }

    Write-Host ("[DESCARGANDO] " + $Name) -ForegroundColor Cyan
    Download-File $Url $Path

    if (-not (Test-CachedZip $Path $MinBytes)) {
        Fail ("El ZIP descargado no es valido: " + $Name)
    }

    return $Path
}


function Wait-FileUnlocked(
    [string]$Path,
    [int]$TimeoutSeconds = 60
) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return $true
    }

    $watch = [System.Diagnostics.Stopwatch]::StartNew()
    $lastError = ""

    while ($watch.Elapsed.TotalSeconds -lt $TimeoutSeconds) {
        $stream = $null
        try {
            # Exclusive open is intentional. If this succeeds, rcedit,
            # Defender, Explorer or another process no longer owns a
            # conflicting handle to the freshly-written executable.
            $stream = [System.IO.File]::Open(
                $Path,
                [System.IO.FileMode]::Open,
                [System.IO.FileAccess]::Read,
                [System.IO.FileShare]::None
            )
            $stream.Dispose()
            return $true
        }
        catch {
            $lastError = $_.Exception.Message
            [GC]::Collect()
            [GC]::WaitForPendingFinalizers()
            Start-Sleep -Milliseconds 350
        }
        finally {
            if ($stream) {
                try { $stream.Dispose() } catch {}
            }
        }
    }

    Write-Host ("Archivo bloqueado tras " + $TimeoutSeconds + " segundos:") -ForegroundColor Yellow
    Write-Host ("  " + $Path) -ForegroundColor Yellow
    if ($lastError) {
        Write-Host ("  " + $lastError) -ForegroundColor DarkYellow
    }
    return $false
}

function Copy-FileWithRetry(
    [string]$Source,
    [string]$Destination,
    [int]$Attempts = 20
) {
    $parent = Split-Path -Parent $Destination
    if ($parent) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }

    for ($attempt = 1; $attempt -le $Attempts; $attempt++) {
        try {
            [System.IO.File]::Copy($Source, $Destination, $true)
            return
        }
        catch {
            if ($attempt -eq $Attempts) {
                Fail (
                    "No se pudo copiar este archivo tras " + $Attempts +
                    " intentos:`n" + $Source + "`n" + $_.Exception.Message
                )
            }

            [GC]::Collect()
            [GC]::WaitForPendingFinalizers()
            Start-Sleep -Milliseconds (250 + ($attempt * 100))
        }
    }
}

function Copy-DirectoryToStaging(
    [string]$SourceDir,
    [string]$StageDir
) {
    if (Test-Path -LiteralPath $StageDir) {
        Remove-Item -LiteralPath $StageDir -Recurse -Force
    }
    New-Item -ItemType Directory -Path $StageDir -Force | Out-Null

    $sourcePrefix = $SourceDir.TrimEnd('\') + '\'

    Get-ChildItem -LiteralPath $SourceDir -Recurse -File | ForEach-Object {
        $relative = $_.FullName.Substring($sourcePrefix.Length)
        $target = Join-Path $StageDir $relative
        Copy-FileWithRetry $_.FullName $target 20
    }
}

function New-PortableZipRobust(
    [string]$SourceDir,
    [string]$ZipPath,
    [string]$WorkRoot
) {
    Write-Step "Creando ZIP portable"

    $launcherExe = Join-Path $SourceDir "Pokemon 3D Portable.exe"
    $runtimeExe = Join-Path $SourceDir "runtime\Gen1Recomp3D.exe"

    Write-Host "Esperando a que Windows libere los EXE modificados..." -ForegroundColor DarkGray

    if (-not (Wait-FileUnlocked $launcherExe 60)) {
        Fail (
            "El launcher sigue en uso. Cierra Pokemon 3D Portable.exe, " +
            "el juego y cualquier ventana que lo este ejecutando, y vuelve a compilar."
        )
    }

    if (-not (Wait-FileUnlocked $runtimeExe 60)) {
        Fail (
            "El runtime sigue en uso. Cierra Gen1Recomp3D.exe/el juego " +
            "y vuelve a compilar."
        )
    }

    # A short grace period also helps with antivirus/shell hooks that open
    # the file immediately after its PE resources were changed by rcedit.
    Start-Sleep -Milliseconds 1000
    [GC]::Collect()
    [GC]::WaitForPendingFinalizers()

    $stageRoot = Join-Path $WorkRoot "zip-staging"
    $stageDir = Join-Path $stageRoot (Split-Path -Leaf $SourceDir)

    if (Test-Path -LiteralPath $stageRoot) {
        Remove-Item -LiteralPath $stageRoot -Recurse -Force
    }
    New-Item -ItemType Directory -Path $stageRoot -Force | Out-Null

    Write-Host "Copiando resultado a staging..." -ForegroundColor DarkGray
    Copy-DirectoryToStaging $SourceDir $stageDir

    if (Test-Path -LiteralPath $ZipPath) {
        Remove-Item -LiteralPath $ZipPath -Force
    }

    Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction SilentlyContinue

    $tmpZip = $ZipPath + ".tmp"
    $created = $false
    $lastError = ""

    for ($attempt = 1; $attempt -le 5; $attempt++) {
        try {
            if (Test-Path -LiteralPath $tmpZip) {
                Remove-Item -LiteralPath $tmpZip -Force -ErrorAction SilentlyContinue
            }

            # Archive stageRoot rather than the live dist directory. This
            # completely removes Compress-Archive from the rcedit/AV timing.
            [System.IO.Compression.ZipFile]::CreateFromDirectory(
                $stageRoot,
                $tmpZip,
                [System.IO.Compression.CompressionLevel]::Optimal,
                $false
            )

            if (-not (Test-Path -LiteralPath $tmpZip -PathType Leaf)) {
                throw "ZipFile no genero el archivo temporal."
            }

            $info = Get-Item -LiteralPath $tmpZip
            if ($info.Length -lt 100000) {
                throw ("ZIP demasiado pequeno: " + $info.Length + " bytes")
            }

            Move-Item -LiteralPath $tmpZip -Destination $ZipPath -Force
            $created = $true
            break
        }
        catch {
            $lastError = $_.Exception.Message
            Write-Host (
                "Intento de ZIP " + $attempt + "/5 fallo; reintentando..."
            ) -ForegroundColor Yellow
            [GC]::Collect()
            [GC]::WaitForPendingFinalizers()
            Start-Sleep -Milliseconds (700 * $attempt)
        }
    }

    if (-not $created) {
        Fail (
            "No se pudo crear el ZIP tras 5 intentos.`n" +
            "Ultimo error: " + $lastError
        )
    }

    # Validate contents before reporting success.
    $archive = [System.IO.Compression.ZipFile]::OpenRead($ZipPath)
    try {
        $hasLauncher = $false
        $hasRuntime = $false

        foreach ($entry in $archive.Entries) {
            $name = $entry.FullName.Replace('\', '/')
            if ($name -match '/Pokemon 3D Portable\.exe$') {
                $hasLauncher = $true
            }
            if ($name -match '/runtime/Gen1Recomp3D\.exe$') {
                $hasRuntime = $true
            }
        }

        if (-not $hasLauncher) {
            Fail "El ZIP se creo pero no contiene Pokemon 3D Portable.exe."
        }
        if (-not $hasRuntime) {
            Fail "El ZIP se creo pero no contiene runtime\Gen1Recomp3D.exe."
        }
    }
    finally {
        $archive.Dispose()
    }

    Write-Host ("ZIP validado: " + $ZipPath) -ForegroundColor Green

    Remove-Item -LiteralPath $stageRoot -Recurse -Force -ErrorAction SilentlyContinue
}

function Write-Utf8NoBom([string]$Path, [string]$Content) {
    $utf8NoBom = New-Object System.Text.UTF8Encoding -ArgumentList $false
    [System.IO.File]::WriteAllText($Path, $Content, $utf8NoBom)
}

function Prepare-GameIcon(
    [string]$CoverPath,
    [string]$OutPng,
    [string]$OutIco
) {
    if (-not (Test-Path -LiteralPath $CoverPath -PathType Leaf)) {
        Write-Host "No hay caratula local para esta edicion; se usara el icono por defecto." -ForegroundColor Yellow
        return $false
    }

    Add-Type -AssemblyName System.Drawing

    $src = [System.Drawing.Image]::FromFile($CoverPath)
    try {
        $size = 256
        $bmp = New-Object System.Drawing.Bitmap -ArgumentList $size, $size
        try {
            $g = [System.Drawing.Graphics]::FromImage($bmp)
            try {
                $g.Clear([System.Drawing.Color]::Black)
                $g.CompositingQuality = [System.Drawing.Drawing2D.CompositingQuality]::HighQuality
                $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
                $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::HighQuality
                $g.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality

                # The supplied Red/Blue/Yellow covers are square. Keep the full
                # cover visible rather than cropping the character or logos.
                $g.DrawImage($src, 0, 0, $size, $size)
            }
            finally {
                $g.Dispose()
            }

            $pngParent = Split-Path -Parent $OutPng
            if ($pngParent) { New-Item -ItemType Directory -Path $pngParent -Force | Out-Null }
            $bmp.Save($OutPng, [System.Drawing.Imaging.ImageFormat]::Png)
        }
        finally {
            $bmp.Dispose()
        }
    }
    finally {
        $src.Dispose()
    }

    # ICO container with a 256x256 PNG payload. Windows 10/11, Explorer,
    # WinForms and rcedit all support PNG-compressed icon entries.
    $pngBytes = [System.IO.File]::ReadAllBytes($OutPng)
    $fs = [System.IO.File]::Create($OutIco)
    try {
        $bw = New-Object System.IO.BinaryWriter -ArgumentList $fs
        try {
            $bw.Write([UInt16]0) # reserved
            $bw.Write([UInt16]1) # type = icon
            $bw.Write([UInt16]1) # image count

            $bw.Write([Byte]0)   # width 256
            $bw.Write([Byte]0)   # height 256
            $bw.Write([Byte]0)   # color count
            $bw.Write([Byte]0)   # reserved
            $bw.Write([UInt16]1) # planes
            $bw.Write([UInt16]32)# bpp
            $bw.Write([UInt32]$pngBytes.Length)
            $bw.Write([UInt32]22) # ICONDIR + one ICONDIRENTRY
            $bw.Write($pngBytes)
        }
        finally {
            $bw.Dispose()
        }
    }
    finally {
        $fs.Dispose()
    }
    return $true
}

function Ensure-Rcedit {
    New-Item -ItemType Directory -Path $Deps -Force | Out-Null
    $rcedit = Join-Path $Deps "rcedit-x64.exe"

    Get-CachedFile `
        "rcedit x64 v2.0.0" `
        "https://github.com/electron/rcedit/releases/download/v2.0.0/rcedit-x64.exe" `
        $rcedit `
        500000 | Out-Null

    return $rcedit
}

function Apply-ExeIcon(
    [string]$ExePath,
    [string]$IcoPath,
    [string]$Description
) {
    if (-not (Test-Path -LiteralPath $ExePath -PathType Leaf)) {
        Fail "No se puede aplicar icono: no existe $ExePath"
    }
    if (-not $IcoPath -or -not (Test-Path -LiteralPath $IcoPath -PathType Leaf)) {
        Write-Host "Icono personalizado omitido." -ForegroundColor DarkGray
        return
    }

    $rcedit = Ensure-Rcedit
    & $rcedit $ExePath `
        --set-icon $IcoPath `
        --set-version-string "ProductName" $Description `
        --set-version-string "FileDescription" $Description `
        --set-version-string "InternalName" $Description

    if ($LASTEXITCODE -ne 0) {
        Fail "rcedit no pudo incrustar el icono en $ExePath"
    }
}

function Get-PythonCommand {
    $portable = Join-Path $Deps "python\python.exe"
    if (Test-Path $portable) {
        try {
            $v = & $portable --version 2>&1
            if ($LASTEXITCODE -eq 0 -and "$v" -match "Python 3") {
                return @{ exe = $portable; args = @() }
            }
        } catch {}
    }

    $py = Get-Command py -ErrorAction SilentlyContinue
    if ($py) {
        try {
            $v = & py -3 --version 2>&1
            if ($LASTEXITCODE -eq 0 -and "$v" -match "Python 3") {
                return @{ exe = "py"; args = @("-3") }
            }
        } catch {}
    }

    $python = Get-Command python -ErrorAction SilentlyContinue
    if ($python) {
        try {
            $v = & python --version 2>&1
            if ($LASTEXITCODE -eq 0 -and "$v" -match "Python 3") {
                return @{ exe = $python.Source; args = @() }
            }
        } catch {}
    }

    return $null
}

function Ensure-Python {
    New-Item -ItemType Directory -Path $Deps -Force | Out-Null

    $cmd = Get-PythonCommand
    if ($cmd) {
        Write-Host "Python encontrado/preparado: $($cmd.exe)" -ForegroundColor Green
        return $cmd
    }

    Write-Step "Descargando Python 3.12 automaticamente"

    $installer = Join-Path $Deps "python-3.12.10-amd64.exe"
    Get-CachedFile `
        "Python 3.12.10 installer" `
        "https://www.python.org/ftp/python/3.12.10/python-3.12.10-amd64.exe" `
        $installer `
        10000000 | Out-Null

    $target = Join-Path $Deps "python"
    if (Test-Path $target) { Remove-Item $target -Recurse -Force }

    Write-Host "Instalando Python dentro de la carpeta del builder..."
    $installArgs = @(
        "/quiet",
        "InstallAllUsers=0",
        "PrependPath=0",
        "Include_launcher=0",
        "Include_test=0",
        "Include_doc=0",
        "Include_tcltk=0",
        "Include_pip=1",
        "Include_tools=1",
        "TargetDir=`"$target`""
    )

    $proc = Start-Process -FilePath $installer -ArgumentList $installArgs -Wait -PassThru
    if ($proc.ExitCode -ne 0) {
        Fail "No se pudo instalar Python automaticamente. Codigo: $($proc.ExitCode)"
    }

    $pythonExe = Join-Path $target "python.exe"
    if (-not (Test-Path $pythonExe)) {
        Fail "Python termino de instalarse pero python.exe no aparece en $target"
    }

    return @{ exe = $pythonExe; args = @() }
}

function Pick-Rom {
    Add-Type -AssemblyName System.Windows.Forms
    $dlg = New-Object System.Windows.Forms.OpenFileDialog
    $dlg.Title = "Selecciona tu ROM legal de Pokemon Red, Blue o Yellow"
    $dlg.Filter = "Pokemon ROM (*.gb;*.gbc)|*.gb;*.gbc|Todos los archivos (*.*)|*.*"
    $dlg.Multiselect = $false
    if ($dlg.ShowDialog() -ne [System.Windows.Forms.DialogResult]::OK) {
        return ""
    }
    return $dlg.FileName
}

function Expand-Zip([string]$Zip, [string]$Destination) {
    if (Test-Path $Destination) { Remove-Item $Destination -Recurse -Force }
    New-Item -ItemType Directory -Path $Destination -Force | Out-Null
    Expand-Archive -LiteralPath $Zip -DestinationPath $Destination -Force
}

function Get-FirstDirectory([string]$Path) {
    $dir = Get-ChildItem -LiteralPath $Path -Directory | Select-Object -First 1
    if (-not $dir) { Fail "No se encontro la carpeta raiz tras descomprimir $Path" }
    return $dir.FullName
}

function Patch-Gen1Config([string]$SourceRoot) {
    $confPath = Join-Path $SourceRoot "conf.lua"
    if (-not (Test-Path $confPath)) { Fail "No se encontro conf.lua en el codigo de Gen1Recomp." }

    $conf = Get-Content -LiteralPath $confPath -Raw

    if ($conf -notmatch 'P3D_WIDTH') {
        $needle = "t.window.vsync = 1"
        $inject = @'
t.window.vsync = 1

    -- Pokemon3D Portable launcher overrides (Windows desktop).
    local p3dWidth = tonumber(os.getenv("P3D_WIDTH") or "")
    local p3dHeight = tonumber(os.getenv("P3D_HEIGHT") or "")
    if p3dWidth and p3dHeight then
        t.window.width = math.max(480, p3dWidth)
        t.window.height = math.max(360, p3dHeight)
    end
    if os.getenv("P3D_FULLSCREEN") == "1" then
        t.window.fullscreen = true
        t.window.fullscreentype = "desktop"
    end
    local p3dTitle = os.getenv("P3D_TITLE")
    if p3dTitle and p3dTitle ~= "" then
        t.window.title = p3dTitle
    end

    -- Cover art icon prepared by the builder. LÖVE uses this for the
    -- game window/taskbar while the PE resource covers Explorer/shortcuts.
    t.window.icon = "game_icon.png"
'@
        if (-not $conf.Contains($needle)) { Fail "No se pudo insertar el parche de resolucion en conf.lua." }
        $conf = $conf.Replace($needle, $inject)
    }

    $joyNeedle = "t.modules.joystick = not companion"
    if ($conf.Contains($joyNeedle)) {
        $conf = $conf.Replace($joyNeedle, 't.modules.joystick = not companion and os.getenv("P3D_GAMEPAD") ~= "0"')
    }

    Write-Utf8NoBom $confPath $conf
}


function Patch-AppDataPersistence([string]$SourceRoot) {
    $saveDataPath = Join-Path $SourceRoot "src\core\SaveData.lua"
    if (-not (Test-Path $saveDataPath)) {
        Fail "No se encontro src\core\SaveData.lua para aplicar la ruta AppData personalizada."
    }

    $code = Get-Content -LiteralPath $saveDataPath -Raw

    # Do NOT treat the custom AppData root as Gen1Recomp portable mode.
    # Portable mode also controls CacheFs; v6 only redirects saves/options.
    if ($code -notmatch 'local function pokemon3dPersistFs') {
        $anchor = '-- Resolve the filesystem a persistent read/write should land on:'
        if (-not $code.Contains($anchor)) {
            Fail "No se encontro el punto de insercion de persistencia en SaveData.lua."
        }

        $helper = @'
-- Pokemon3D launcher: save/options persistence root independent from
-- Gen1Recomp portable mode. This deliberately does NOT alter
-- portableBaseDir(), so CacheFs still sees the bundled ROM-derived cache.
local pokemon3dPersistDir = nil
local pokemon3dPersistCache = nil

local function pokemon3dPersistFs()
  local dir = os.getenv("POKEPORT_PERSIST_DIR")
  if not dir or dir == "" then return nil end

  if pokemon3dPersistCache and pokemon3dPersistDir == dir then
    return pokemon3dPersistCache
  end

  local osPath = dir:gsub("/", SEP)
  if SEP == "\\" then
    os.execute('mkdir "' .. osPath .. '" 2>nul')
  else
    os.execute('mkdir -p "' .. osPath .. '" 2>/dev/null')
  end

  pokemon3dPersistDir = dir
  pokemon3dPersistCache = makePortableFs(dir)
  return pokemon3dPersistCache
end

'@
        $code = $code.Replace($anchor, $helper + $anchor)
    }

    $oldReturn = 'return SaveData.portableFs() or fs or (love and love.filesystem)'
    $newReturn = 'return pokemon3dPersistFs() or SaveData.portableFs() or fs or (love and love.filesystem)'
    if ($code.Contains($oldReturn)) {
        $code = $code.Replace($oldReturn, $newReturn)
    } elseif (-not $code.Contains($newReturn)) {
        Fail "No se pudo redirigir persistFs() a AppData."
    }

    if ($code -notmatch 'POKEPORT_FLAT_SAVE_DIR') {
        $oldSlot = 'local function slotDir(key) return "saves/" .. key end'
        $newSlot = @'
local function slotDir(key)
    -- Each launcher build already owns a game-specific root:
    -- %APPDATA%\PokemonRed, PokemonBlue or PokemonYellow.
    -- Keep slots directly in <root>\saves rather than saves\red etc.
    if os.getenv("POKEPORT_FLAT_SAVE_DIR") == "1" and not isCartKey(key) then
        return "saves"
    end
    return "saves/" .. key
end
'@
        if (-not $code.Contains($oldSlot)) {
            Fail "No se encontro slotDir() en SaveData.lua."
        }
        $code = $code.Replace($oldSlot, $newSlot)
    }

    Write-Utf8NoBom $saveDataPath $code
}


function Validate-DramaticShapeFullWindowBattle([string]$SourceRoot) {
    Write-Step "Validando soporte 3D Battle Full Window"

    $modRoot = Join-Path $SourceRoot "mods\DRAMATIC_SHAPE"
    $scenePath = Join-Path $modRoot "lib\BattleScene.lua"
    $battlePath = Join-Path $modRoot "lib\OverworldBattle.lua"

    if (-not (Test-Path -LiteralPath $scenePath -PathType Leaf)) {
        Fail "Dramatic Shape no contiene lib\BattleScene.lua."
    }
    if (-not (Test-Path -LiteralPath $battlePath -PathType Leaf)) {
        Fail "Dramatic Shape no contiene lib\OverworldBattle.lua."
    }

    $scene = Get-Content -LiteralPath $scenePath -Raw
    $battle = Get-Content -LiteralPath $battlePath -Raw

    $requiredScene = @(
        "function BattleScene.pixelSize()",
        "function BattleScene.letterboxFov",
        "cam.fov = BattleScene.letterboxFov(cam.fov, ph, s)",
        "local rw, rh = AntiAlias.expand(pw, ph)",
        "AntiAlias.resolve(Voxel3D.endScene(), pw, ph"
    )

    foreach ($needle in $requiredScene) {
        if (-not $scene.Contains($needle)) {
            Fail ("La revision de Dramatic Shape no tiene el soporte Full Window esperado: " + $needle)
        }
    }

    if (-not $battle.Contains("renderer:setWorldOverride(shot.canvas)")) {
        Fail "Dramatic Shape no entrega la escena 3D completa a Renderer.worldOverride."
    }

    Write-Host "3D Battle Full Window: validado." -ForegroundColor Green
}



function Patch-3DBattleWorldOverrideDim([string]$SourceRoot) {
    Write-Step "Aplicando fix REAL de marcos 3D-BTL (battleDim + worldOverride)"

    $rendererPath = Join-Path $SourceRoot "src\render\Renderer.lua"
    if (-not (Test-Path -LiteralPath $rendererPath -PathType Leaf)) {
        Fail "No se encontro src\render\Renderer.lua."
    }

    $renderer = Get-Content -LiteralPath $rendererPath -Raw

    $patched = "if self.battleDim and self.battleDim > 0 and not self.worldOverride then"
    if ($renderer.Contains($patched)) {
        Write-Host "Fix battleDim/worldOverride ya aplicado." -ForegroundColor Green
        return
    }

    $original = "if self.battleDim and self.battleDim > 0 then"
    $matches = [regex]::Matches($renderer, [regex]::Escape($original))

    if ($matches.Count -ne 1) {
        Fail (
            "Renderer.lua no tiene exactamente un battleDim esperado. " +
            "Encontrados: " + $matches.Count
        )
    }

    # IMPORTANT:
    # worldOverride is already a complete window-resolution battle scene.
    # BATTLE BG=WORLD's veil is intended for the stock battle SURROUND, not
    # for a provider that has already supplied that surround itself.
    #
    # Keep the user's option untouched. It still works for ordinary 2D
    # battles; it is skipped only for a frame carrying worldOverride.
    $renderer = $renderer.Replace(
        $original,
        "if self.battleDim and self.battleDim > 0 and not self.worldOverride then"
    )

    Write-Utf8NoBom $rendererPath $renderer

    $verify = Get-Content -LiteralPath $rendererPath -Raw
    if (-not $verify.Contains($patched)) {
        Fail "El fix battleDim/worldOverride no quedo escrito."
    }

    # Structural sanity: the full-window provider path must still exist.
    if (-not $verify.Contains("if self.worldOverride then")) {
        Fail "Renderer.lua perdio la rama worldOverride inesperadamente."
    }
    if (-not $verify.Contains("love.graphics.draw(self.worldOverride")) {
        Fail "Renderer.lua ya no contiene el blit worldOverride."
    }

    Write-Host "Marcos 3D: veil WORLD desactivado solo sobre worldOverride." -ForegroundColor Green
}

function Patch-LauncherOptions([string]$SourceRoot) {
    $saveDataPath = Join-Path $SourceRoot "src\core\SaveData.lua"
    if (-not (Test-Path $saveDataPath)) {
        Fail "No se encontro src\core\SaveData.lua para integrar las opciones del launcher."
    }

    $code = Get-Content -LiteralPath $saveDataPath -Raw

    if ($code -notmatch 'local function applyPokemon3DLauncherOptions') {
        $anchor = 'function SaveData.loadOptions(fs)'
        if (-not $code.Contains($anchor)) {
            Fail "No se encontro SaveData.loadOptions() para integrar el launcher."
        }

        $helper = @'
-- Pokemon3D v8: launcher-owned runtime options.
-- Values are passed as environment variables so the external launcher can
-- expose Gen1Recomp settings without hand-editing options.lua.
local function p3dEnv(name)
  local v = os.getenv(name)
  if v == nil or v == "" then return nil end
  return v
end

local function p3dBool(name)
  local v = p3dEnv(name)
  if v == nil then return nil end
  v = tostring(v):lower()
  if v == "1" or v == "true" or v == "on" or v == "yes" then return true end
  if v == "0" or v == "false" or v == "off" or v == "no" then return false end
  return nil
end

local function p3dNum(name)
  local v = tonumber(p3dEnv(name))
  return v
end

local function applyPokemon3DLauncherOptions(opts)
  if type(opts) ~= "table" then opts = SaveData.defaultOptions() end

  local s
  local n
  local b

  n = p3dNum("P3D_TEXT_SPEED");       if n then opts.textSpeed = n end
  b = p3dBool("P3D_ANIMATIONS");      if b ~= nil then opts.animations = b end
  s = p3dEnv("P3D_BATTLE_STYLE");     if s then opts.battleStyle = s end
  s = p3dEnv("P3D_BATTLE_LAYOUT");    if s then opts.battleLayout = s end
  s = p3dEnv("P3D_BATTLE_FIT");       if s then opts.battleFit = s end
  s = p3dEnv("P3D_BATTLE_HUD");       if s then opts.battleHud = s end
  s = p3dEnv("P3D_BATTLE_BG");        if s then opts.battleBg = s end
  s = p3dEnv("P3D_UI_LAYOUT");        if s then opts.uiLayout = s end
  s = p3dEnv("P3D_RULESET");          if s then opts.ruleset = s end

  n = p3dNum("P3D_MUSIC_VOL");        if n then opts.musicVol = math.max(0, math.min(7, math.floor(n))) end
  n = p3dNum("P3D_SFX_VOL");          if n then opts.sfxVol = math.max(0, math.min(7, math.floor(n))) end
  n = p3dNum("P3D_PIKA_VOL");         if n then opts.pikaVol = math.max(0, math.min(7, math.floor(n))) end
  n = p3dNum("P3D_MUSIC_FILTER");     if n then opts.musicFilter = math.max(0, math.min(3, math.floor(n))) end

  s = p3dEnv("P3D_PERFORMANCE");      if s then opts.performance = s end
  s = p3dEnv("P3D_COLORS");           if s then opts.colors = s end
  n = p3dNum("P3D_TILT");             if n then opts.tilt = math.max(0, math.min(3, math.floor(n))) end
  n = p3dNum("P3D_ZOOM");             if n then opts.zoom = math.floor(n) end
  s = p3dEnv("P3D_VOID_FILL");        if s then opts.voidFill = s end
  s = p3dEnv("P3D_VIDEO_MODE");       if s then opts.videoMode = s end
  n = p3dNum("P3D_FAITHFUL_RES");     if n then opts.faithfulRes = math.max(0, math.min(4, math.floor(n))) end
  s = p3dEnv("P3D_SCREEN_POS");       if s then opts.screenPos = s end
  n = p3dNum("P3D_FPS_CAP");          if n then opts.fpsCap = math.floor(n) end

  n = p3dNum("P3D_SPEED_OVERWORLD");  if n then opts.speedOverworld = n end
  n = p3dNum("P3D_SPEED_BATTLE");     if n then opts.speedBattle = n end
  n = p3dNum("P3D_SPEED_MENU");       if n then opts.speedMenu = n end

  s = p3dEnv("P3D_DATE_FORMAT");      if s then opts.dateFormat = s end
  s = p3dEnv("P3D_TIME_FORMAT");      if s then opts.timeFormat = s end
  b = p3dBool("P3D_SAFE_MODE");       if b ~= nil then opts.safeMode = b end

  -- Render pipelines. Dramatic Shape declares voxel + tiltshift.
  opts.pipelines = type(opts.pipelines) == "table" and opts.pipelines or {}
  n = p3dNum("P3D_VOXEL_LEVEL")
  if n then
    opts.pipelines.voxel = math.max(0, math.min(7, math.floor(n)))
    if opts.pipelines.voxel > 0 then opts.tilt = 0 end
  end
  n = p3dNum("P3D_TSHIFT_LEVEL")
  if n then opts.pipelines.tiltshift = math.max(0, math.min(3, math.floor(n))) end

  -- Dramatic Shape mod settings (options.modOptions.DRAMATIC_SHAPE).
  opts.modOptions = type(opts.modOptions) == "table" and opts.modOptions or {}
  local ds = type(opts.modOptions.DRAMATIC_SHAPE) == "table"
             and opts.modOptions.DRAMATIC_SHAPE or {}
  opts.modOptions.DRAMATIC_SHAPE = ds

  b = p3dBool("P3D_DS_GRID");         if b ~= nil then ds.grid = b end
  n = p3dNum("P3D_DS_CURVE");         if n then ds.curve = math.max(0, math.min(5, math.floor(n))) end
  n = p3dNum("P3D_DS_VIEWBOX");       if n then ds.viewbox = math.max(0, math.min(4, math.floor(n))) end
  s = p3dEnv("P3D_DS_WATER");         if s then ds.water = s end
  s = p3dEnv("P3D_DS_DAYTIME");       if s then ds.daytime = s end
  b = p3dBool("P3D_DS_BACKSPRITES");  if b ~= nil then ds.battleBack = b end
  s = p3dEnv("P3D_DS_LETSGO")
  if s then
    if s == "off" then ds.letsgo = false else ds.letsgo = s end
  end
  s = p3dEnv("P3D_DS_ATMOS");         if s then ds.atmos = s end
  b = p3dBool("P3D_DS_SHADOWS");      if b ~= nil then ds.shadows = b end
  n = p3dNum("P3D_DS_AA");            if n then ds.aa = math.floor(n) end
  n = p3dNum("P3D_DS_SHINY");         if n then ds.shinyOdds = math.max(1, math.floor(n)) end

  s = p3dEnv("P3D_DS_BATTLES")
  if s then
    if s == "2d3d_a" then ds.battles = true
    elseif s == "2d3d_b" then ds.battles = "flatB"
    elseif s == "stadium_a" then ds.battles = "stadium"
    elseif s == "stadium_b" then ds.battles = "stadiumB"
    elseif s == "off" then ds.battles = false
    end
  end

  return opts
end

'@
        $code = $code.Replace($anchor, $helper + $anchor)
    }

    # Route every successful/default return from loadOptions through launcher overrides.
    $code = $code.Replace(
        'return applyCartOverlay(SaveData.mergeOptions(recovered))',
        'return applyPokemon3DLauncherOptions(applyCartOverlay(SaveData.mergeOptions(recovered)))'
    )
    $code = $code.Replace(
        'return SaveData.defaultOptions()',
        'return applyPokemon3DLauncherOptions(SaveData.defaultOptions())'
    )
    $code = $code.Replace(
        'return applyCartOverlay(SaveData.mergeOptions(data))',
        'return applyPokemon3DLauncherOptions(applyCartOverlay(SaveData.mergeOptions(data)))'
    )

    Write-Utf8NoBom $saveDataPath $code
}

function Patch-LauncherPipelines([string]$SourceRoot) {
    $pipelinesPath = Join-Path $SourceRoot "src\render\Pipelines.lua"
    if (-not (Test-Path $pipelinesPath)) {
        Fail "No se encontro src\render\Pipelines.lua."
    }

    $p = Get-Content -LiteralPath $pipelinesPath -Raw

    if ($p -notmatch 'P3D_VOXEL_LEVEL') {
        $pattern = 'function\s+Pipelines\.applyOptions\(opts\)\r?\n\s*local\s+bucket\s*=\s*type\(opts\)\s*==\s*"table"\s*and\s*opts\.pipelines\s*or\s*nil'
        $replacement = @'
function Pipelines.applyOptions(opts)
  local bucket = type(opts) == "table" and opts.pipelines or nil

  -- Pokemon3D v8: the external launcher may choose render pipeline
  -- levels for this boot. This patch is line-ending agnostic.
  local p3dVoxel = tonumber(os.getenv("P3D_VOXEL_LEVEL"))
  local p3dTShift = tonumber(os.getenv("P3D_TSHIFT_LEVEL"))
  if p3dVoxel or p3dTShift then
    if type(opts) ~= "table" then opts = {} end
    if type(bucket) ~= "table" then
      bucket = {}
      opts.pipelines = bucket
    end
    if p3dVoxel then
      bucket.voxel = math.max(0, math.min(7, math.floor(p3dVoxel)))
      if bucket.voxel > 0 then opts.tilt = 0 end
    end
    if p3dTShift then
      bucket.tiltshift = math.max(0, math.min(3, math.floor(p3dTShift)))
    end
  end
'@

        $patched = [regex]::Replace($p, $pattern, $replacement, 1)
        if ($patched -eq $p) {
            Fail "No se encontro Pipelines.applyOptions() para integrar Voxel."
        }
        $p = $patched
    }

    Write-Utf8NoBom $pipelinesPath $p
}

function Patch-LauncherModEnable([string]$SourceRoot) {
    $loaderPath = Join-Path $SourceRoot "src\mods\Loader.lua"
    if (-not (Test-Path $loaderPath)) {
        Fail "No se encontro src\mods\Loader.lua."
    }

    $l = Get-Content -LiteralPath $loaderPath -Raw

    if ($l -notmatch 'P3D_DS_ENABLED') {
        $anchor = "  -- the player's target override"
        $inject = @'
  -- Pokemon3D v8: the external launcher owns the enabled state of the
  -- bundled Dramatic Shape mod for this launch.
  local p3dDs = os.getenv("P3D_DS_ENABLED")
  if p3dDs == "1" then
    self.disabled["DRAMATIC_SHAPE"] = nil
  elseif p3dDs == "0" then
    self.disabled["DRAMATIC_SHAPE"] = true
  end

'@
        if (-not $l.Contains($anchor)) {
            Fail "No se encontro el punto de insercion en Loader:_loadState()."
        }
        $l = $l.Replace($anchor, $inject + $anchor)
    }

    Write-Utf8NoBom $loaderPath $l
}

function Build-CompleteRomCache(
    [string]$SourceRoot,
    [string]$Rom,
    [string]$GameId,
    [string]$LoveExe
) {
    Write-Step "Creando cache completo de la ROM con el importador oficial de Gen1Recomp"

    if (-not (Test-Path $LoveExe)) {
        Fail "No se encontro love.exe para ejecutar el importador oficial."
    }

    # Temporary portable mode makes the OFFICIAL runtime importer publish
    # directly into the source tree. portable.txt is removed before packing.
    $portableMarker = Join-Path $SourceRoot "portable.txt"
    New-Item -ItemType File -Path $portableMarker -Force | Out-Null

    $envNames = @(
        "POKEPORT_IMPORT_ONLY",
        "POKEPORT_IMPORT_ROM",
        "POKEPORT_VERSION",
        "POKEPORT_GAME",
        "POKEPORT_FORCE_IMPORT",
        "POKEPORT_BUNDLED_GAME",
        "POKEPORT_PERSIST_DIR"
    )

    $oldEnv = @{}
    foreach ($name in $envNames) {
        $oldEnv[$name] = [Environment]::GetEnvironmentVariable($name, "Process")
    }

    try {
        [Environment]::SetEnvironmentVariable("POKEPORT_IMPORT_ONLY", "1", "Process")
        [Environment]::SetEnvironmentVariable("POKEPORT_IMPORT_ROM", $Rom, "Process")
        [Environment]::SetEnvironmentVariable("POKEPORT_VERSION", $GameId, "Process")
        [Environment]::SetEnvironmentVariable("POKEPORT_GAME", $GameId, "Process")
        [Environment]::SetEnvironmentVariable("POKEPORT_FORCE_IMPORT", "1", "Process")
        [Environment]::SetEnvironmentVariable("POKEPORT_BUNDLED_GAME", $null, "Process")
        [Environment]::SetEnvironmentVariable("POKEPORT_PERSIST_DIR", $null, "Process")

        Write-Host "Extrayendo datos, graficos y audio con Gen1Recomp..."
        Write-Host "Puede aparecer una ventana unos segundos. Se cerrara sola al terminar."

        $arg = '"' + $SourceRoot + '"'
        $proc = Start-Process `
            -FilePath $LoveExe `
            -ArgumentList $arg `
            -WorkingDirectory (Split-Path -Parent $LoveExe) `
            -Wait `
            -PassThru

        if ($proc.ExitCode -ne 0) {
            Fail ("El importador oficial de Gen1Recomp termino con codigo " + $proc.ExitCode)
        }
    }
    finally {
        foreach ($name in $envNames) {
            [Environment]::SetEnvironmentVariable($name, $oldEnv[$name], "Process")
        }
        if (Test-Path $portableMarker) {
            Remove-Item $portableMarker -Force
        }
    }

    # Current Gen1Recomp stores every edition's generated cache under its id.
    $cacheRoot = Join-Path $SourceRoot $GameId
    $required = @(
        (Join-Path $cacheRoot "rom-cache.complete"),
        (Join-Path $cacheRoot "data\generated\constants.lua"),
        (Join-Path $cacheRoot "data\generated\maps.lua"),
        (Join-Path $cacheRoot "assets\generated\title\pokemon_logo.png"),
        (Join-Path $cacheRoot "assets\generated\fonts\font.png"),
        (Join-Path $cacheRoot "assets\generated\battle\front\pikachu.png"),
        (Join-Path $cacheRoot "assets\generated\audio\programs.bin")
    )

    if ($GameId -eq "yellow") {
        $required += (Join-Path $cacheRoot "assets\generated\pikachu\pikapic_1.png")
    }

    $missing = @()
    foreach ($path in $required) {
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
            $missing += $path
        }
    }

    if ($missing.Count -gt 0) {
        Write-Host ""
        Write-Host "Faltan archivos del cache completo:" -ForegroundColor Red
        foreach ($path in $missing) {
            Write-Host ("  - " + $path) -ForegroundColor Red
        }
        Fail "El cache quedo incompleto. No se generara un EXE que vuelva a pedir la ROM."
    }

    # Remove any generic save/options files touched during the build-time boot.
    $builderArtifacts = @(
        "options.lua", "options.lua.bak", "options.lua.tmp",
        "save.lua", "save.lua.bak", "save.lua.tmp",
        "save_blue.lua", "save_blue.lua.bak", "save_blue.lua.tmp",
        "save_yellow.lua", "save_yellow.lua.bak", "save_yellow.lua.tmp",
        "relaunch_to_launcher.txt"
    )

    foreach ($name in $builderArtifacts) {
        $p = Join-Path $SourceRoot $name
        if (Test-Path $p) {
            Remove-Item $p -Force -ErrorAction SilentlyContinue
        }
    }

    $builderSaves = Join-Path $SourceRoot "saves"
    if (Test-Path $builderSaves) {
        Remove-Item $builderSaves -Recurse -Force -ErrorAction SilentlyContinue
    }

    Write-Host ("Cache completo listo para " + $GameId + ". El .gb original no se incluira.") -ForegroundColor Green
}


function Stage-RuntimeRomCache(
    [string]$SourceRoot,
    [string]$GameId,
    [string]$StageRoot
) {
    Write-Step "Separando cache del juego del ejecutable"

    $sourceCache = Join-Path $SourceRoot $GameId
    if (-not (Test-Path -LiteralPath $sourceCache -PathType Container)) {
        Fail ("No se encontro el cache versionado generado: " + $sourceCache)
    }

    $marker = Join-Path $sourceCache "rom-cache.complete"
    $audio = Join-Path $sourceCache "assets\generated\audio\programs.bin"
    $maps = Join-Path $sourceCache "data\generated\maps.lua"

    foreach ($required in @($marker, $audio, $maps)) {
        if (-not (Test-Path -LiteralPath $required -PathType Leaf)) {
            Fail ("Cache incompleto antes de empaquetar: " + $required)
        }
    }

    if (Test-Path $StageRoot) {
        Remove-Item $StageRoot -Recurse -Force
    }
    New-Item -ItemType Directory -Path $StageRoot -Force | Out-Null

    $stageGame = Join-Path $StageRoot $GameId
    Copy-Item -LiteralPath $sourceCache -Destination $stageGame -Recurse -Force

    # Critical v9 change: do NOT put the generated ROM cache inside game.love.
    # At runtime CacheFs mounts runtime\<game>\ as the active generated tree.
    Remove-Item -LiteralPath $sourceCache -Recurse -Force

    if (Test-Path -LiteralPath $sourceCache) {
        Fail "No se pudo retirar el cache de la fuente antes de crear game.love."
    }

    Write-Host ("Cache preparado externamente: runtime\" + $GameId + "\") -ForegroundColor Green
}

function Install-VoxelMod([string]$SourceRoot, [string]$ModZip, [string]$TempDir) {
    Expand-Zip $ModZip $TempDir

    $manifest = Get-ChildItem -LiteralPath $TempDir -Filter "manifest.json" -Recurse -File |
        Sort-Object { $_.FullName.Length } |
        Select-Object -First 1

    if (-not $manifest) { Fail "El ZIP del Voxel Mod no contiene manifest.json." }

    $meta = Get-Content -LiteralPath $manifest.FullName -Raw | ConvertFrom-Json
    $modId = if ($meta.id) { [string]$meta.id } else { "DRAMATIC_SHAPE" }

    $modsDir = Join-Path $SourceRoot "mods"
    if (Test-Path $modsDir) {
        Get-ChildItem -LiteralPath $modsDir -Force | Remove-Item -Recurse -Force
    } else {
        New-Item -ItemType Directory -Path $modsDir -Force | Out-Null
    }

    $dest = Join-Path $modsDir $modId
    New-Item -ItemType Directory -Path $dest -Force | Out-Null
    Copy-Item -Path (Join-Path $manifest.Directory.FullName "*") -Destination $dest -Recurse -Force

    return $modId
}

function Make-GameLove([string]$SourceRoot, [string]$OutFile) {
    if (Test-Path $OutFile) { Remove-Item $OutFile -Force }

    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $tempZip = [System.IO.Path]::ChangeExtension($OutFile, ".zip")
    if (Test-Path $tempZip) { Remove-Item $tempZip -Force }

    [System.IO.Compression.ZipFile]::CreateFromDirectory(
        $SourceRoot,
        $tempZip,
        [System.IO.Compression.CompressionLevel]::Optimal,
        $false
    )
    Move-Item -LiteralPath $tempZip -Destination $OutFile -Force
}

function Fuse-Love([string]$LoveExe, [string]$GameLove, [string]$OutputExe) {
    $out = [System.IO.File]::Create($OutputExe)
    try {
        $a = [System.IO.File]::OpenRead($LoveExe)
        try { $a.CopyTo($out) } finally { $a.Dispose() }

        $b = [System.IO.File]::OpenRead($GameLove)
        try { $b.CopyTo($out) } finally { $b.Dispose() }
    } finally {
        $out.Dispose()
    }
}


function New-RuntimePayloadZip(
    [string]$RuntimeDir,
    [string]$OutFile
) {
    Write-Step "Empaquetando runtime interno para EXE unico"

    if (-not (Test-Path -LiteralPath $RuntimeDir -PathType Container)) {
        Fail "No existe el runtime que debe incrustarse."
    }

    $runtimeExe = Join-Path $RuntimeDir "Gen1Recomp3D.exe"
    $portable = Join-Path $RuntimeDir "portable.txt"

    if (-not (Test-Path -LiteralPath $runtimeExe -PathType Leaf)) {
        Fail "Falta Gen1Recomp3D.exe antes de crear el payload."
    }
    if (-not (Test-Path -LiteralPath $portable -PathType Leaf)) {
        Fail "Falta runtime\portable.txt antes de crear el payload."
    }

    if (Test-Path -LiteralPath $OutFile) {
        Remove-Item -LiteralPath $OutFile -Force
    }

    Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction SilentlyContinue

    [System.IO.Compression.ZipFile]::CreateFromDirectory(
        $RuntimeDir,
        $OutFile,
        [System.IO.Compression.CompressionLevel]::Optimal,
        $false
    )

    if (-not (Test-Path -LiteralPath $OutFile -PathType Leaf)) {
        Fail "No se pudo crear el payload ZIP interno."
    }

    $size = (Get-Item -LiteralPath $OutFile).Length
    if ($size -lt 1000000) {
        Fail ("Payload interno sospechosamente pequeno: " + $size + " bytes")
    }

    Write-Host (
        "Payload interno: " +
        [math]::Round($size / 1MB, 2) + " MB"
    ) -ForegroundColor Green
}

function Append-PayloadToExe(
    [string]$ExePath,
    [string]$PayloadZip
) {
    Write-Step "Creando EXE monolitico"

    if (-not (Wait-FileUnlocked $ExePath 60)) {
        Fail "El launcher EXE sigue bloqueado antes de incrustar el payload."
    }

    $markerText = "P3DPAYLOADV17END"
    $marker = [System.Text.Encoding]::ASCII.GetBytes($markerText)
    $payloadLength = (Get-Item -LiteralPath $PayloadZip).Length

    $fs = $null
    $payload = $null
    $writer = $null

    try {
        $fs = New-Object System.IO.FileStream(
            $ExePath,
            [System.IO.FileMode]::Open,
            [System.IO.FileAccess]::ReadWrite,
            [System.IO.FileShare]::None
        )
        $fs.Seek(0, [System.IO.SeekOrigin]::End) | Out-Null

        $payload = [System.IO.File]::OpenRead($PayloadZip)
        $payload.CopyTo($fs)

        $writer = New-Object System.IO.BinaryWriter($fs)
        $writer.Write([Int64]$payloadLength)
        $writer.Write($marker)
        $writer.Flush()
        $fs.Flush()
    }
    finally {
        if ($writer) { try { $writer.Dispose() } catch {} }
        if ($payload) { try { $payload.Dispose() } catch {} }
        if ($fs) { try { $fs.Dispose() } catch {} }
    }

    # Validate the overlay footer without extracting it.
    $check = [System.IO.File]::OpenRead($ExePath)
    try {
        $footer = 8 + $marker.Length
        if ($check.Length -le $footer + $payloadLength) {
            Fail "El EXE monolitico quedo demasiado pequeno para su payload."
        }

        $check.Seek(-$marker.Length, [System.IO.SeekOrigin]::End) | Out-Null
        $got = New-Object byte[] $marker.Length
        $null = $check.Read($got, 0, $got.Length)

        for ($i = 0; $i -lt $marker.Length; $i++) {
            if ($got[$i] -ne $marker[$i]) {
                Fail "El marcador del payload no esta al final del EXE."
            }
        }

        $check.Seek(-$footer, [System.IO.SeekOrigin]::End) | Out-Null
        $reader = New-Object System.IO.BinaryReader($check)
        try {
            $storedLength = $reader.ReadInt64()
            if ($storedLength -ne $payloadLength) {
                Fail "La longitud del payload escrita en el EXE no coincide."
            }
        }
        finally {
            $reader.Dispose()
        }
    }
    finally {
        $check.Dispose()
    }

    Write-Host "EXE unico: runtime y cache incrustados correctamente." -ForegroundColor Green
}

function New-SingleExeZip(
    [string]$ExePath,
    [string]$ZipPath,
    [string]$WorkRoot
) {
    Write-Step "Creando ZIP con un solo EXE"

    if (-not (Wait-FileUnlocked $ExePath 60)) {
        Fail "El EXE final sigue bloqueado y no se puede comprimir."
    }

    $stage = Join-Path $WorkRoot "single-exe-zip"
    if (Test-Path -LiteralPath $stage) {
        Remove-Item -LiteralPath $stage -Recurse -Force
    }
    New-Item -ItemType Directory -Path $stage -Force | Out-Null

    Copy-FileWithRetry $ExePath (Join-Path $stage "Pokemon 3D Portable.exe") 20

    if (Test-Path -LiteralPath $ZipPath) {
        Remove-Item -LiteralPath $ZipPath -Force
    }

    Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction SilentlyContinue
    [System.IO.Compression.ZipFile]::CreateFromDirectory(
        $stage,
        $ZipPath,
        [System.IO.Compression.CompressionLevel]::Optimal,
        $false
    )

    if (-not (Test-Path -LiteralPath $ZipPath -PathType Leaf)) {
        Fail "No se pudo crear el ZIP del EXE unico."
    }

    $archive = [System.IO.Compression.ZipFile]::OpenRead($ZipPath)
    try {
        if ($archive.Entries.Count -ne 1) {
            Fail (
                "El ZIP final debe contener exactamente un archivo, contiene: " +
                $archive.Entries.Count
            )
        }

        if ($archive.Entries[0].Name -ne "Pokemon 3D Portable.exe") {
            Fail "El unico archivo del ZIP final no es Pokemon 3D Portable.exe."
        }
    }
    finally {
        $archive.Dispose()
    }

    Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue
    Write-Host "ZIP final contiene solamente Pokemon 3D Portable.exe." -ForegroundColor Green
}

function Build-Launcher([string]$OutputDir, [string]$GameId, [string]$GameName, [string]$PayloadId) {
    $launcherPath = Join-Path $OutputDir "Pokemon 3D Portable.exe"

    $source = @'
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.IO;
using System.IO.Compression;
using System.Text;
using System.Threading;
using System.Windows.Forms;

public sealed class Pokemon3DLauncher : Form
{
    const string GameId = "__GAME_ID__";
    const string GameName = "__GAME_NAME__";

    const string PayloadId = "__PAYLOAD_ID__";
    const string PayloadMarkerText = "P3DPAYLOADV17END";

    string RuntimeRoot
    {
        get
        {
            string local = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
            return Path.Combine(local, "Pokemon3DPortableRuntime",
                GameName.Replace(" ", ""), PayloadId);
        }
    }

    string RuntimeExe { get { return Path.Combine(RuntimeRoot, "Gen1Recomp3D.exe"); } }

    string AppDataRoot
    {
        get
        {
            string appData = Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData);
            return Path.Combine(appData, GameName.Replace(" ", ""));
        }
    }

    string SavesDir { get { return Path.Combine(AppDataRoot, "saves"); } }
    string IniPath { get { return Path.Combine(AppDataRoot, "launcher.ini"); } }

    TabControl tabs = new TabControl();
    Label status = new Label();

    ComboBox resolution;
    TextBox customW;
    TextBox customH;
    ComboBox videoMode;
    CheckBox gamepad;
    ComboBox faithfulRes;
    ComboBox screenPos;
    ComboBox fpsCap;
    ComboBox performance;

    ComboBox textSpeed;
    CheckBox animations;
    ComboBox ruleset;
    ComboBox dateFormat;
    ComboBox timeFormat;
    ComboBox speedOverworld;
    ComboBox speedBattle;
    ComboBox speedMenu;

    ComboBox battleStyle;
    ComboBox battleLayout;
    ComboBox battleFit;
    ComboBox battleHud;
    ComboBox battleBg;
    ComboBox uiLayout;

    NumericUpDown musicVol;
    NumericUpDown sfxVol;
    NumericUpDown pikaVol;
    ComboBox musicFilter;
    ComboBox colors;
    NumericUpDown zoom;
    ComboBox voidFill;
    ComboBox tilt;
    CheckBox safeMode;

    CheckBox dsEnabled;
    ComboBox voxelLevel;
    ComboBox tiltShift;
    CheckBox voxelGrid;
    ComboBox curve;
    ComboBox renderDist;
    ComboBox water;
    ComboBox daytime;
    ComboBox battle3d;
    CheckBox backSprites;
    ComboBox letsGo;
    ComboBox forestFx;
    CheckBox shadows;
    ComboBox aa;
    ComboBox shinyOdds;

    Button play;
    Button internalLauncher;
    Button saves;
    Button reset;

    readonly string[] speedValues =
        new string[] { "1X", "2X", "3X", "4X", "10X", "20X", "30X", "50X", "75X", "100X", "200X" };

    public Pokemon3DLauncher()
    {
        Text = GameName + " 3D Launcher";
        try
        {
            this.Icon = System.Drawing.Icon.ExtractAssociatedIcon(Application.ExecutablePath);
        }
        catch {}

        ClientSize = new Size(960, 760);
        MinimumSize = new Size(900, 700);
        StartPosition = FormStartPosition.CenterScreen;
        Font = new Font("Segoe UI", 9F);

        Label title = new Label();
        title.Text = GameName + " - Gen1Recomp + Dramatic Shape";
        title.Font = new Font("Segoe UI Semibold", 18F);
        title.AutoSize = true;
        title.Location = new Point(22, 16);
        Controls.Add(title);

        Label subtitle = new Label();
        subtitle.Text = "Launcher v18 - SINGLE EXE + configuracion completa";
        subtitle.AutoSize = true;
        subtitle.Location = new Point(25, 52);
        Controls.Add(subtitle);

        tabs.Location = new Point(20, 82);
        tabs.Size = new Size(920, 565);
        tabs.Anchor = AnchorStyles.Top | AnchorStyles.Left | AnchorStyles.Right | AnchorStyles.Bottom;
        Controls.Add(tabs);

        BuildGeneralTab();
        BuildGameplayTab();
        BuildBattleTab();
        BuildAudioDisplayTab();
        BuildVoxelTab();
        BuildAdvancedTab();

        play = new Button();
        play.Text = "JUGAR";
        play.Font = new Font("Segoe UI Semibold", 12F);
        play.Location = new Point(20, 660);
        play.Size = new Size(330, 48);
        play.Anchor = AnchorStyles.Bottom | AnchorStyles.Left;
        play.Click += delegate { Launch(false); };
        Controls.Add(play);

        internalLauncher = new Button();
        internalLauncher.Text = "Gen1Recomp / Mods / Shaders / Controls";
        internalLauncher.Location = new Point(365, 660);
        internalLauncher.Size = new Size(285, 48);
        internalLauncher.Anchor = AnchorStyles.Bottom | AnchorStyles.Left;
        internalLauncher.Click += delegate { Launch(true); };
        Controls.Add(internalLauncher);

        saves = new Button();
        saves.Text = "Abrir saves";
        saves.Location = new Point(665, 660);
        saves.Size = new Size(130, 48);
        saves.Anchor = AnchorStyles.Bottom | AnchorStyles.Right;
        saves.Click += delegate { OpenSaves(); };
        Controls.Add(saves);

        reset = new Button();
        reset.Text = "Defaults";
        reset.Location = new Point(810, 660);
        reset.Size = new Size(130, 48);
        reset.Anchor = AnchorStyles.Bottom | AnchorStyles.Right;
        reset.Click += delegate
        {
            if (MessageBox.Show("Restaurar los valores del launcher?", "Pokemon 3D",
                MessageBoxButtons.YesNo, MessageBoxIcon.Question) == DialogResult.Yes)
            {
                SetDefaults();
                SaveSettings();
            }
        };
        Controls.Add(reset);

        status.AutoSize = false;
        status.Location = new Point(22, 716);
        status.Size = new Size(910, 24);
        status.Anchor = AnchorStyles.Bottom | AnchorStyles.Left | AnchorStyles.Right;
        status.Text = "JUGAR entra directo al juego. La ROM no se vuelve a pedir.";
        Controls.Add(status);

        SetDefaults();
        LoadSettings();
        UpdateStates();

        FormClosing += delegate { SaveSettings(); };
    }

    TabPage NewTab(string text)
    {
        TabPage page = new TabPage(text);
        page.AutoScroll = true;
        tabs.TabPages.Add(page);
        return page;
    }

    Label LabelAt(Control parent, string text, int x, int y, int width)
    {
        Label l = new Label();
        l.Text = text;
        l.Location = new Point(x, y + 4);
        l.Size = new Size(width, 24);
        parent.Controls.Add(l);
        return l;
    }

    ComboBox ComboAt(Control parent, string label, int x, int y, int width, string[] items)
    {
        LabelAt(parent, label, x, y, 165);
        ComboBox c = new ComboBox();
        c.DropDownStyle = ComboBoxStyle.DropDownList;
        c.Location = new Point(x + 170, y);
        c.Size = new Size(width, 26);
        c.Items.AddRange(items);
        parent.Controls.Add(c);
        return c;
    }

    CheckBox CheckAt(Control parent, string text, int x, int y)
    {
        CheckBox c = new CheckBox();
        c.Text = text;
        c.AutoSize = true;
        c.Location = new Point(x, y + 3);
        parent.Controls.Add(c);
        return c;
    }

    NumericUpDown NumericAt(Control parent, string label, int x, int y, int width, decimal min, decimal max)
    {
        LabelAt(parent, label, x, y, 165);
        NumericUpDown n = new NumericUpDown();
        n.Minimum = min;
        n.Maximum = max;
        n.Location = new Point(x + 170, y);
        n.Size = new Size(width, 26);
        parent.Controls.Add(n);
        return n;
    }

    void AddNote(Control parent, string text, int x, int y, int width)
    {
        Label l = new Label();
        l.Text = text;
        l.Location = new Point(x, y);
        l.Size = new Size(width, 44);
        parent.Controls.Add(l);
    }

    void BuildGeneralTab()
    {
        TabPage p = NewTab("General / Video");

        resolution = ComboAt(p, "Resolucion", 25, 28, 190,
            new string[] { "1280x720", "1600x900", "1920x1080", "2560x1440", "3840x2160", "Personalizada" });
        resolution.SelectedIndexChanged += delegate { UpdateStates(); };

        LabelAt(p, "Personalizada", 465, 28, 105);
        customW = new TextBox();
        customW.Location = new Point(570, 28);
        customW.Size = new Size(75, 25);
        p.Controls.Add(customW);
        Label x = new Label(); x.Text = "x"; x.Location = new Point(652, 32); x.AutoSize = true; p.Controls.Add(x);
        customH = new TextBox();
        customH.Location = new Point(670, 28);
        customH.Size = new Size(75, 25);
        p.Controls.Add(customH);

        videoMode = ComboAt(p, "Video mode", 25, 72, 190,
            new string[] { "WINDOWED", "BORDERLESS FULLSCREEN" });

        gamepad = CheckAt(p, "Usar mando Xbox / XInput", 465, 75);

        faithfulRes = ComboAt(p, "Faithful ratio", 25, 116, 190,
            new string[] { "OFF", "1X", "2X", "3X", "4X" });
        screenPos = ComboAt(p, "Screen position", 465, 116, 190,
            new string[] { "CENTER", "UPPER", "TOP" });

        fpsCap = ComboAt(p, "Max FPS", 25, 160, 190,
            new string[] { "30", "40", "50", "60", "75", "90", "100", "120", "144", "160" });
        performance = ComboAt(p, "Performance", 465, 160, 190,
            new string[] { "AUTO", "HIGH", "BALANCED", "LOW" });

        string ogPaletteLabel =
            GameId == "yellow" ? "OG YELLOW" :
            GameId == "blue" ? "OG BLUE" : "OG RED";

        colors = ComboAt(p, "Paleta de colores", 25, 204, 220,
            new string[] {
                ogPaletteLabel,
                "SGB",
                "ADVANCED",
                "OG MONO",
                "OG MONO INV",
                "SGB INV",
                "CLASSIC DMG GREEN"
            });

        AddNote(p,
            "PALETA: OG usa la colorizacion original de la edicion. SGB usa paletas Super Game Boy. ADVANCED usa la colorizacion mas rica por mapa/especie. CLASSIC DMG GREEN imita el verde de la Game Boy original.",
            25, 260, 820);
    }

    void BuildGameplayTab()
    {
        TabPage p = NewTab("Gameplay / Speed");

        textSpeed = ComboAt(p, "Text speed", 25, 28, 190,
            new string[] { "FAST", "MEDIUM", "SLOW" });
        animations = CheckAt(p, "Battle animations", 465, 31);

        ruleset = ComboAt(p, "Ruleset", 25, 72, 190,
            new string[] { "GEN1 FAITHFUL", "MODERN CLEAN" });

        dateFormat = ComboAt(p, "Date format", 25, 116, 190,
            new string[] { "DEVICE", "DD-MM-YYYY", "MM-DD-YYYY", "YYYY-MM-DD" });
        timeFormat = ComboAt(p, "Time format", 465, 116, 190,
            new string[] { "DEVICE", "24 HOUR", "12 HOUR" });

        speedOverworld = ComboAt(p, "Overworld speed", 25, 180, 190, speedValues);
        speedBattle = ComboAt(p, "Battle speed", 465, 180, 190, speedValues);
        speedMenu = ComboAt(p, "Menu speed", 25, 224, 190, speedValues);

        AddNote(p,
            "Las velocidades aceleran la logica del juego; musica y efectos mantienen el tono y tempo normales.",
            25, 285, 820);
    }

    void BuildBattleTab()
    {
        TabPage p = NewTab("Battle");

        battleStyle = ComboAt(p, "Battle style", 25, 28, 190,
            new string[] { "SHIFT", "SET" });
        battleLayout = ComboAt(p, "Battle layout", 465, 28, 190,
            new string[] { "OG", "WIDE" });

        battleFit = ComboAt(p, "Battle size", 25, 72, 190,
            new string[] { "FIXED", "FILL" });
        battleHud = ComboAt(p, "Battle HUD", 465, 72, 190,
            new string[] { "STANDARD", "EXTENDED" });

        battleBg = ComboAt(p, "Battle BG", 25, 116, 190,
            new string[] { "WHITE", "BLACK", "WORLD" });
        uiLayout = ComboAt(p, "UI layout", 465, 116, 190,
            new string[] { "CENTERED", "DYNAMIC" });

        AddNote(p,
            "3D-BTL ALPHA FIX: las zonas negras/transparentes fuera del frame central se enmascaran y dejan ver un underlay del escenario 3D. HUD, textos, Pokemon y tus ajustes no se estiran.",
            25, 180, 820);
    }

    void BuildAudioDisplayTab()
    {
        TabPage p = NewTab("Audio / Display avanzado");

        musicVol = NumericAt(p, "Music volume", 25, 28, 90, 0, 7);
        sfxVol = NumericAt(p, "SFX volume", 465, 28, 90, 0, 7);
        pikaVol = NumericAt(p, "Pikachu volume", 25, 72, 90, 0, 7);
        musicFilter = ComboAt(p, "Music filter", 465, 72, 190,
            new string[] { "OFF", "1X", "2X", "3X" });

        zoom = NumericAt(p, "Zoom offset", 25, 132, 90, -12, 12);

        voidFill = ComboAt(p, "Void fill", 25, 176, 190,
            new string[] { "TREES", "WATER", "BLACK" });
        tilt = ComboAt(p, "Engine tilt", 465, 176, 190,
            new string[] { "OFF", "15", "35", "50" });

        safeMode = CheckAt(p, "Gen1Recomp Safe Mode", 25, 234);

        AddNote(p,
            "ZOOM: 0=FIT, negativos=OUT, positivos=IN. Engine TILT se mantiene OFF cuando Dramatic Shape usa VOXEL, porque ambos intentan controlar el mismo world pass.",
            25, 285, 820);
    }

    void BuildVoxelTab()
    {
        TabPage p = NewTab("Dramatic Shape / Voxel");

        dsEnabled = CheckAt(p, "Dramatic Shape habilitado", 25, 20);
        dsEnabled.CheckedChanged += delegate { UpdateStates(); };

        voxelLevel = ComboAt(p, "VOXEL", 25, 58, 220,
            new string[] { "OFF", "FULL", "15", "35", "50", "75", "1ST EXPERIMENTAL", "3RD EXPERIMENTAL" });
        tiltShift = ComboAt(p, "T-SHIFT", 465, 58, 190,
            new string[] { "OFF", "1", "2", "3" });

        voxelGrid = CheckAt(p, "V-GRID - wireframe", 25, 105);
        curve = ComboAt(p, "V-CURVE", 465, 102, 190,
            new string[] { "OFF", "1", "2", "3", "4", "5" });

        renderDist = ComboAt(p, "Render distance", 25, 146, 220,
            new string[] { "FIT", "WIDE", "WIDER", "WIDEST", "OFF" });
        water = ComboAt(p, "Water", 465, 146, 190,
            new string[] { "FULL", "SKY", "OFF" });

        daytime = ComboAt(p, "Daytime", 25, 190, 220,
            new string[] { "SYNC", "DAY", "NIGHT", "DUSK", "DAWN", "CYCLE" });
        battle3d = ComboAt(p, "3D Battle", 465, 190, 190,
            new string[] { "2D-3D A", "2D-3D B", "STADIUM A", "STADIUM B", "OFF" });

        backSprites = CheckAt(p, "Back sprites", 25, 237);
        letsGo = ComboAt(p, "Let's Go", 465, 234, 190,
            new string[] { "OFF", "FULL", "CATCH ONLY" });

        forestFx = ComboAt(p, "Forest FX", 25, 278, 220,
            new string[] { "FULL", "LOW", "OFF" });
        shadows = CheckAt(p, "Real cast shadows", 465, 281);

        aa = ComboAt(p, "Anti-aliasing", 25, 322, 220,
            new string[] { "OFF", "2X", "4X" });
        shinyOdds = ComboAt(p, "Shiny odds", 465, 322, 190,
            new string[] { "1:8192", "1:4096", "1:2048", "1:1024", "1:512", "1:256",
                           "1:128", "1:64", "1:32", "1:16", "1:8", "1:4", "1:2", "1:1" });

        AddNote(p,
            "STADIUM A/B siguen necesitando que el mod tenga los modelos derivados de una ROM de Pokemon Stadium aportada por el usuario. 2D-3D A/B no la necesitan.",
            25, 380, 820);
    }

    void BuildAdvancedTab()
    {
        TabPage p = NewTab("Advanced / Dynamic");

        Label h = new Label();
        h.Text = "Opciones dinámicas de Gen1Recomp";
        h.Font = new Font("Segoe UI Semibold", 13F);
        h.AutoSize = true;
        h.Location = new Point(25, 25);
        p.Controls.Add(h);

        AddNote(p,
            "Shader FX 1/2, presets .slangp, rebinding de controles, perfiles de mods, importacion de mods y otras opciones que dependen de archivos instalados se administran con el gestor interno.",
            25, 65, 820);

        Button open = new Button();
        open.Text = "Abrir Gen1Recomp / Mods / Shaders / Controls";
        open.Location = new Point(25, 125);
        open.Size = new Size(390, 42);
        open.Click += delegate { Launch(true); };
        p.Controls.Add(open);

        Button appdata = new Button();
        appdata.Text = "Abrir AppData del juego";
        appdata.Location = new Point(435, 125);
        appdata.Size = new Size(220, 42);
        appdata.Click += delegate { OpenAppData(); };
        p.Controls.Add(appdata);

        Button saveFolder = new Button();
        saveFolder.Text = "Abrir saves";
        saveFolder.Location = new Point(675, 125);
        saveFolder.Size = new Size(160, 42);
        saveFolder.Click += delegate { OpenSaves(); };
        p.Controls.Add(saveFolder);

        Button logs = new Button();
        logs.Text = "Abrir logs Gen1Recomp";
        logs.Location = new Point(435, 175);
        logs.Size = new Size(220, 38);
        logs.Click += delegate { OpenEngineLogs(); };
        p.Controls.Add(logs);

        Label path = new Label();
        path.Text = "Datos persistentes: %APPDATA%\\" + GameName.Replace(" ", "") + "\\";
        path.Location = new Point(25, 195);
        path.Size = new Size(820, 28);
        p.Controls.Add(path);
    }

    void SetDefaults()
    {
        resolution.SelectedItem = "1920x1080";
        customW.Text = "1920";
        customH.Text = "1080";
        videoMode.SelectedItem = "BORDERLESS FULLSCREEN";
        gamepad.Checked = true;
        faithfulRes.SelectedItem = "OFF";
        screenPos.SelectedItem = "CENTER";
        fpsCap.SelectedItem = "60";
        performance.SelectedItem = "AUTO";

        textSpeed.SelectedItem = "MEDIUM";
        animations.Checked = true;
        ruleset.SelectedItem = "GEN1 FAITHFUL";
        dateFormat.SelectedItem = "DEVICE";
        timeFormat.SelectedItem = "DEVICE";
        speedOverworld.SelectedItem = "1X";
        speedBattle.SelectedItem = "1X";
        speedMenu.SelectedItem = "1X";

        battleStyle.SelectedItem = "SHIFT";
        battleLayout.SelectedItem = "OG";
        battleFit.SelectedItem = "FIXED";
        battleHud.SelectedItem = "STANDARD";
        battleBg.SelectedItem = "WHITE";
        uiLayout.SelectedItem = "CENTERED";

        musicVol.Value = 7;
        sfxVol.Value = 7;
        pikaVol.Value = 7;
        musicFilter.SelectedItem = "OFF";
        colors.SelectedItem = "SGB";
        zoom.Value = 0;
        voidFill.SelectedItem = "TREES";
        tilt.SelectedItem = "OFF";
        safeMode.Checked = false;

        dsEnabled.Checked = true;
        voxelLevel.SelectedItem = "FULL";
        tiltShift.SelectedItem = "3";
        voxelGrid.Checked = false;
        curve.SelectedItem = "OFF";
        renderDist.SelectedItem = "FIT";
        water.SelectedItem = "FULL";
        daytime.SelectedItem = "SYNC";
        battle3d.SelectedItem = "2D-3D A";
        backSprites.Checked = false;
        letsGo.SelectedItem = "OFF";
        forestFx.SelectedItem = "FULL";
        shadows.Checked = true;
        aa.SelectedItem = "OFF";
        shinyOdds.SelectedItem = "1:8192";

        UpdateStates();
    }

    void UpdateStates()
    {
        bool custom = Selected(resolution) == "Personalizada";
        customW.Enabled = custom;
        customH.Enabled = custom;

        bool ds = dsEnabled.Checked;
        voxelLevel.Enabled = ds;
        tiltShift.Enabled = ds;
        voxelGrid.Enabled = ds;
        curve.Enabled = ds;
        renderDist.Enabled = ds;
        water.Enabled = ds;
        daytime.Enabled = ds;
        battle3d.Enabled = ds;
        backSprites.Enabled = ds;
        letsGo.Enabled = ds;
        forestFx.Enabled = ds;
        shadows.Enabled = ds;
        aa.Enabled = ds;
        shinyOdds.Enabled = ds;

        pikaVol.Enabled = GameId == "yellow";
        tilt.Enabled = !ds || Selected(voxelLevel) == "OFF";
    }

    string Selected(ComboBox c)
    {
        return c.SelectedItem == null ? "" : c.SelectedItem.ToString();
    }

    int ParseSpeed(ComboBox c)
    {
        string s = Selected(c).Replace("X", "");
        int v;
        return int.TryParse(s, out v) ? v : 1;
    }

    int VoxelLevelValue()
    {
        string s = Selected(voxelLevel);
        if (s == "FULL") return 1;
        if (s == "15") return 2;
        if (s == "35") return 3;
        if (s == "50") return 4;
        if (s == "75") return 5;
        if (s.StartsWith("1ST")) return 6;
        if (s.StartsWith("3RD")) return 7;
        return 0;
    }

    int ComboIndexOr(ComboBox c, int fallback)
    {
        return c.SelectedIndex >= 0 ? c.SelectedIndex : fallback;
    }

    void GetResolution(out int w, out int h)
    {
        w = 1920;
        h = 1080;

        string r = Selected(resolution);
        if (r == "Personalizada")
        {
            int.TryParse(customW.Text, out w);
            int.TryParse(customH.Text, out h);
            if (w < 480) w = 480;
            if (h < 360) h = 360;
            return;
        }

        string[] p = r.Split('x');
        if (p.Length == 2)
        {
            int.TryParse(p[0], out w);
            int.TryParse(p[1], out h);
        }
    }

    string ColorId()
    {
        string s = Selected(colors);

        // Gen1Recomp uses the historical id "ogred" for the edition-specific
        // original colorization. Internally it resolves Red/Blue/Yellow from
        // the active GameVersion, so the launcher can show the correct name.
        if (s == "OG RED" || s == "OG BLUE" || s == "OG YELLOW") return "ogred";
        if (s == "ADVANCED") return "redpp";
        if (s == "OG MONO") return "og";
        if (s == "OG MONO INV") return "og_inv";
        if (s == "SGB INV") return "gbc_inv";
        if (s == "CLASSIC DMG GREEN") return "classic";
        return "gbc"; // SGB
    }

    string RuleId()
    {
        return Selected(ruleset) == "MODERN CLEAN" ? "modern_clean" : "gen1_faithful";
    }

    string DateId()
    {
        string s = Selected(dateFormat);
        if (s == "DD-MM-YYYY") return "dmy";
        if (s == "MM-DD-YYYY") return "mdy";
        if (s == "YYYY-MM-DD") return "ymd";
        return "device";
    }

    string TimeId()
    {
        string s = Selected(timeFormat);
        if (s == "24 HOUR") return "24h";
        if (s == "12 HOUR") return "12h";
        return "device";
    }

    string BattlesId()
    {
        string s = Selected(battle3d);
        if (s == "2D-3D A") return "2d3d_a";
        if (s == "2D-3D B") return "2d3d_b";
        if (s == "STADIUM A") return "stadium_a";
        if (s == "STADIUM B") return "stadium_b";
        return "off";
    }

    string LetsGoId()
    {
        string s = Selected(letsGo);
        if (s == "FULL") return "full";
        if (s == "CATCH ONLY") return "catching";
        return "off";
    }


    bool RuntimeReady()
    {
        return File.Exists(RuntimeExe)
            && File.Exists(Path.Combine(RuntimeRoot, "portable.txt"));
    }

    void CleanupOldRuntimes()
    {
        try
        {
            DirectoryInfo current = new DirectoryInfo(RuntimeRoot);
            DirectoryInfo gameRoot = current.Parent;
            if (gameRoot == null || !gameRoot.Exists) return;

            foreach (DirectoryInfo dir in gameRoot.GetDirectories())
            {
                if (dir.FullName.Equals(current.FullName,
                    StringComparison.OrdinalIgnoreCase)) continue;
                try { dir.Delete(true); } catch {}
            }
        }
        catch {}
    }

    void ExtractPayload(string destination)
    {
        byte[] marker = Encoding.ASCII.GetBytes(PayloadMarkerText);
        string self = Application.ExecutablePath;

        using (FileStream fs = new FileStream(
            self, FileMode.Open, FileAccess.Read, FileShare.ReadWrite))
        {
            long footer = marker.Length + 8L;
            if (fs.Length <= footer)
                throw new InvalidDataException("El EXE no contiene payload interno.");

            fs.Seek(-marker.Length, SeekOrigin.End);
            byte[] got = new byte[marker.Length];
            if (fs.Read(got, 0, got.Length) != got.Length)
                throw new EndOfStreamException("No se pudo leer el marcador del payload.");

            for (int i = 0; i < marker.Length; i++)
                if (got[i] != marker[i])
                    throw new InvalidDataException("Marcador del payload no encontrado.");

            fs.Seek(-footer, SeekOrigin.End);
            long payloadLength;
            using (BinaryReader br = new BinaryReader(fs, Encoding.UTF8, true))
                payloadLength = br.ReadInt64();

            long payloadStart = fs.Length - footer - payloadLength;
            if (payloadLength <= 0 || payloadStart <= 0)
                throw new InvalidDataException("Longitud del payload invalida.");

            string tempZip = Path.Combine(Path.GetTempPath(),
                "Pokemon3D_" + GameId + "_" + PayloadId + "_" +
                Process.GetCurrentProcess().Id + ".zip");

            try
            {
                fs.Seek(payloadStart, SeekOrigin.Begin);

                using (FileStream output = new FileStream(
                    tempZip, FileMode.Create, FileAccess.Write, FileShare.None))
                {
                    byte[] buffer = new byte[1024 * 1024];
                    long remaining = payloadLength;

                    while (remaining > 0)
                    {
                        int wanted = (int)Math.Min(buffer.Length, remaining);
                        int read = fs.Read(buffer, 0, wanted);
                        if (read <= 0)
                            throw new EndOfStreamException("Payload truncado.");
                        output.Write(buffer, 0, read);
                        remaining -= read;
                    }
                }

                ZipFile.ExtractToDirectory(tempZip, destination);
            }
            finally
            {
                try { if (File.Exists(tempZip)) File.Delete(tempZip); } catch {}
            }
        }
    }

    bool EnsureRuntime()
    {
        if (RuntimeReady()) return true;

        string mutexName = "Pokemon3DPortable_" + GameId + "_" + PayloadId;
        using (Mutex mutex = new Mutex(false, mutexName))
        {
            bool locked = false;
            try
            {
                try { locked = mutex.WaitOne(TimeSpan.FromMinutes(2)); }
                catch (AbandonedMutexException) { locked = true; }

                if (!locked)
                    throw new IOException("Timeout esperando preparar el runtime.");

                if (RuntimeReady()) return true;

                string temp = RuntimeRoot + ".extract-" +
                    Process.GetCurrentProcess().Id;

                try
                {
                    if (Directory.Exists(temp)) Directory.Delete(temp, true);
                    Directory.CreateDirectory(temp);

                    ExtractPayload(temp);

                    string exe = Path.Combine(temp, "Gen1Recomp3D.exe");
                    string portable = Path.Combine(temp, "portable.txt");
                    if (!File.Exists(exe) || !File.Exists(portable))
                        throw new InvalidDataException(
                            "El payload se extrajo pero faltan archivos del runtime.");

                    if (Directory.Exists(RuntimeRoot))
                    {
                        try { Directory.Delete(RuntimeRoot, true); }
                        catch {}
                    }

                    DirectoryInfo parent = Directory.GetParent(RuntimeRoot);
                    if (parent != null) Directory.CreateDirectory(parent.FullName);

                    Directory.Move(temp, RuntimeRoot);
                    File.WriteAllText(Path.Combine(RuntimeRoot, ".payload-ready"), PayloadId);
                    CleanupOldRuntimes();
                }
                finally
                {
                    try
                    {
                        if (Directory.Exists(temp)) Directory.Delete(temp, true);
                    }
                    catch {}
                }

                return RuntimeReady();
            }
            catch (Exception ex)
            {
                MessageBox.Show(
                    "No se pudo preparar el runtime interno:\n\n" + ex.Message,
                    "Pokemon 3D - EXE unico",
                    MessageBoxButtons.OK,
                    MessageBoxIcon.Error);
                return false;
            }
            finally
            {
                if (locked)
                {
                    try { mutex.ReleaseMutex(); } catch {}
                }
            }
        }
    }

    void SetEnv(ProcessStartInfo psi, string key, string value)
    {
        psi.EnvironmentVariables[key] = value;
    }

    void Launch(bool openInternalLauncher)
    {
        status.Text = "Preparando runtime interno...";
        status.Refresh();

        if (!EnsureRuntime())
        {
            status.Text = "No se pudo preparar el runtime interno.";
            return;
        }

        SaveSettings();

        int w, h;
        GetResolution(out w, out h);

        ProcessStartInfo psi = new ProcessStartInfo();
        psi.FileName = RuntimeExe;
        psi.WorkingDirectory = Path.GetDirectoryName(RuntimeExe);
        psi.UseShellExecute = false;
        psi.Arguments = openInternalLauncher ? "--launcher" : "--game=" + GameId;

        Directory.CreateDirectory(AppDataRoot);
        Directory.CreateDirectory(SavesDir);

        SetEnv(psi, "P3D_WIDTH", w.ToString());
        SetEnv(psi, "P3D_HEIGHT", h.ToString());
        SetEnv(psi, "P3D_FULLSCREEN", Selected(videoMode) == "BORDERLESS FULLSCREEN" ? "1" : "0");
        SetEnv(psi, "P3D_GAMEPAD", gamepad.Checked ? "1" : "0");
        SetEnv(psi, "P3D_TITLE", GameName + " 3D");
        SetEnv(psi, "POKEPORT_PERSIST_DIR", AppDataRoot);
        SetEnv(psi, "POKEPORT_FLAT_SAVE_DIR", "1");
        SetEnv(psi, "POKEPORT_BUNDLED_GAME", GameId);
        SetEnv(psi, "POKEPORT_IDENTITY", GameName.Replace(" ", ""));

        SetEnv(psi, "P3D_TEXT_SPEED", Selected(textSpeed) == "FAST" ? "1" : Selected(textSpeed) == "SLOW" ? "5" : "3");
        SetEnv(psi, "P3D_ANIMATIONS", animations.Checked ? "1" : "0");
        SetEnv(psi, "P3D_RULESET", RuleId());
        SetEnv(psi, "P3D_DATE_FORMAT", DateId());
        SetEnv(psi, "P3D_TIME_FORMAT", TimeId());
        SetEnv(psi, "P3D_SPEED_OVERWORLD", ParseSpeed(speedOverworld).ToString());
        SetEnv(psi, "P3D_SPEED_BATTLE", ParseSpeed(speedBattle).ToString());
        SetEnv(psi, "P3D_SPEED_MENU", ParseSpeed(speedMenu).ToString());

        SetEnv(psi, "P3D_BATTLE_STYLE", Selected(battleStyle).ToLowerInvariant());
        SetEnv(psi, "P3D_BATTLE_LAYOUT", Selected(battleLayout).ToLowerInvariant());
        SetEnv(psi, "P3D_BATTLE_FIT", Selected(battleFit).ToLowerInvariant());
        SetEnv(psi, "P3D_BATTLE_HUD", Selected(battleHud).ToLowerInvariant());
        SetEnv(psi, "P3D_BATTLE_BG", Selected(battleBg).ToLowerInvariant());
        SetEnv(psi, "P3D_UI_LAYOUT", Selected(uiLayout).ToLowerInvariant());

        SetEnv(psi, "P3D_MUSIC_VOL", ((int)musicVol.Value).ToString());
        SetEnv(psi, "P3D_SFX_VOL", ((int)sfxVol.Value).ToString());
        SetEnv(psi, "P3D_PIKA_VOL", ((int)pikaVol.Value).ToString());
        SetEnv(psi, "P3D_MUSIC_FILTER", ComboIndexOr(musicFilter, 0).ToString());
        SetEnv(psi, "P3D_PERFORMANCE", Selected(performance).ToLowerInvariant());
        SetEnv(psi, "P3D_COLORS", ColorId());
        SetEnv(psi, "P3D_ZOOM", ((int)zoom.Value).ToString());
        SetEnv(psi, "P3D_VOID_FILL", Selected(voidFill).ToLowerInvariant());
        SetEnv(psi, "P3D_VIDEO_MODE", Selected(videoMode) == "BORDERLESS FULLSCREEN" ? "borderless" : "windowed");
        SetEnv(psi, "P3D_FAITHFUL_RES", ComboIndexOr(faithfulRes, 0).ToString());
        SetEnv(psi, "P3D_SCREEN_POS", Selected(screenPos).ToLowerInvariant());
        SetEnv(psi, "P3D_FPS_CAP", Selected(fpsCap));
        SetEnv(psi, "P3D_TILT", ComboIndexOr(tilt, 0).ToString());
        SetEnv(psi, "P3D_SAFE_MODE", safeMode.Checked ? "1" : "0");

        SetEnv(psi, "P3D_DS_ENABLED", dsEnabled.Checked ? "1" : "0");
        SetEnv(psi, "P3D_VOXEL_LEVEL", VoxelLevelValue().ToString());
        SetEnv(psi, "P3D_TSHIFT_LEVEL", ComboIndexOr(tiltShift, 0).ToString());
        SetEnv(psi, "P3D_DS_GRID", voxelGrid.Checked ? "1" : "0");
        SetEnv(psi, "P3D_DS_CURVE", ComboIndexOr(curve, 0).ToString());
        SetEnv(psi, "P3D_DS_VIEWBOX", ComboIndexOr(renderDist, 0).ToString());
        SetEnv(psi, "P3D_DS_WATER", Selected(water).ToLowerInvariant());
        SetEnv(psi, "P3D_DS_DAYTIME", Selected(daytime).ToLowerInvariant());
        SetEnv(psi, "P3D_DS_BATTLES", BattlesId());
        SetEnv(psi, "P3D_DS_BACKSPRITES", backSprites.Checked ? "1" : "0");
        SetEnv(psi, "P3D_DS_LETSGO", LetsGoId());
        SetEnv(psi, "P3D_DS_ATMOS", Selected(forestFx).ToLowerInvariant());
        SetEnv(psi, "P3D_DS_SHADOWS", shadows.Checked ? "1" : "0");
        SetEnv(psi, "P3D_DS_AA", Selected(aa) == "2X" ? "2" : Selected(aa) == "4X" ? "4" : "0");
        SetEnv(psi, "P3D_DS_SHINY", Selected(shinyOdds).Replace("1:", ""));

        if (openInternalLauncher)
            SetEnv(psi, "POKEPORT_FORCE_LAUNCHER", "1");

        try
        {
            Process.Start(psi);
            status.Text = openInternalLauncher
                ? "Gen1Recomp launcher abierto."
                : "Juego iniciado directamente con la configuracion seleccionada.";
        }
        catch (Exception ex)
        {
            MessageBox.Show(ex.Message, "Error al iniciar",
                MessageBoxButtons.OK, MessageBoxIcon.Error);
        }
    }

    void OpenSaves()
    {
        Directory.CreateDirectory(SavesDir);
        Process.Start("explorer.exe", "\"" + SavesDir + "\"");
    }

    void OpenAppData()
    {
        Directory.CreateDirectory(AppDataRoot);
        Process.Start("explorer.exe", "\"" + AppDataRoot + "\"");
    }

    void OpenEngineLogs()
    {
        string roaming = Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData);
        string dir = Path.Combine(roaming, "LOVE", "pokemon-love2d");
        Directory.CreateDirectory(dir);
        Process.Start("explorer.exe", "\"" + dir + "\"");
    }

    Dictionary<string, string> ReadIni()
    {
        Dictionary<string, string> d = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        if (!File.Exists(IniPath)) return d;
        try
        {
            foreach (string line in File.ReadAllLines(IniPath))
            {
                int eq = line.IndexOf('=');
                if (eq <= 0) continue;
                d[line.Substring(0, eq).Trim()] = line.Substring(eq + 1).Trim();
            }
        }
        catch {}
        return d;
    }

    string Get(Dictionary<string, string> d, string key, string fallback)
    {
        string v;
        return d.TryGetValue(key, out v) ? v : fallback;
    }

    bool Bool(Dictionary<string, string> d, string key, bool fallback)
    {
        string v = Get(d, key, fallback ? "1" : "0");
        return v == "1" || v.Equals("true", StringComparison.OrdinalIgnoreCase);
    }

    void SelectSaved(ComboBox c, string value)
    {
        if (c.Items.Contains(value)) c.SelectedItem = value;
    }

    void LoadSettings()
    {
        Dictionary<string, string> d = ReadIni();
        if (d.Count == 0) return;

        SelectSaved(resolution, Get(d, "resolution", Selected(resolution)));
        customW.Text = Get(d, "customW", customW.Text);
        customH.Text = Get(d, "customH", customH.Text);
        SelectSaved(videoMode, Get(d, "videoMode", Selected(videoMode)));
        gamepad.Checked = Bool(d, "gamepad", gamepad.Checked);
        SelectSaved(faithfulRes, Get(d, "faithfulRes", Selected(faithfulRes)));
        SelectSaved(screenPos, Get(d, "screenPos", Selected(screenPos)));
        SelectSaved(fpsCap, Get(d, "fpsCap", Selected(fpsCap)));
        SelectSaved(performance, Get(d, "performance", Selected(performance)));

        SelectSaved(textSpeed, Get(d, "textSpeed", Selected(textSpeed)));
        animations.Checked = Bool(d, "animations", animations.Checked);
        SelectSaved(ruleset, Get(d, "ruleset", Selected(ruleset)));
        SelectSaved(dateFormat, Get(d, "dateFormat", Selected(dateFormat)));
        SelectSaved(timeFormat, Get(d, "timeFormat", Selected(timeFormat)));
        SelectSaved(speedOverworld, Get(d, "speedOverworld", Selected(speedOverworld)));
        SelectSaved(speedBattle, Get(d, "speedBattle", Selected(speedBattle)));
        SelectSaved(speedMenu, Get(d, "speedMenu", Selected(speedMenu)));

        SelectSaved(battleStyle, Get(d, "battleStyle", Selected(battleStyle)));
        SelectSaved(battleLayout, Get(d, "battleLayout", Selected(battleLayout)));
        SelectSaved(battleFit, Get(d, "battleFit", Selected(battleFit)));
        SelectSaved(battleHud, Get(d, "battleHud", Selected(battleHud)));
        SelectSaved(battleBg, Get(d, "battleBg", Selected(battleBg)));
        SelectSaved(uiLayout, Get(d, "uiLayout", Selected(uiLayout)));

        decimal n;
        if (decimal.TryParse(Get(d, "musicVol", "7"), out n)) musicVol.Value = Math.Max(musicVol.Minimum, Math.Min(musicVol.Maximum, n));
        if (decimal.TryParse(Get(d, "sfxVol", "7"), out n)) sfxVol.Value = Math.Max(sfxVol.Minimum, Math.Min(sfxVol.Maximum, n));
        if (decimal.TryParse(Get(d, "pikaVol", "7"), out n)) pikaVol.Value = Math.Max(pikaVol.Minimum, Math.Min(pikaVol.Maximum, n));
        SelectSaved(musicFilter, Get(d, "musicFilter", Selected(musicFilter)));
        SelectSaved(colors, Get(d, "colors", Selected(colors)));
        if (decimal.TryParse(Get(d, "zoom", "0"), out n)) zoom.Value = Math.Max(zoom.Minimum, Math.Min(zoom.Maximum, n));
        SelectSaved(voidFill, Get(d, "voidFill", Selected(voidFill)));
        SelectSaved(tilt, Get(d, "tilt", Selected(tilt)));
        safeMode.Checked = Bool(d, "safeMode", safeMode.Checked);

        dsEnabled.Checked = Bool(d, "dsEnabled", dsEnabled.Checked);
        SelectSaved(voxelLevel, Get(d, "voxelLevel", Selected(voxelLevel)));
        SelectSaved(tiltShift, Get(d, "tiltShift", Selected(tiltShift)));
        voxelGrid.Checked = Bool(d, "voxelGrid", voxelGrid.Checked);
        SelectSaved(curve, Get(d, "curve", Selected(curve)));
        SelectSaved(renderDist, Get(d, "renderDist", Selected(renderDist)));
        SelectSaved(water, Get(d, "water", Selected(water)));
        SelectSaved(daytime, Get(d, "daytime", Selected(daytime)));
        SelectSaved(battle3d, Get(d, "battle3d", Selected(battle3d)));
        backSprites.Checked = Bool(d, "backSprites", backSprites.Checked);
        SelectSaved(letsGo, Get(d, "letsGo", Selected(letsGo)));
        SelectSaved(forestFx, Get(d, "forestFx", Selected(forestFx)));
        shadows.Checked = Bool(d, "shadows", shadows.Checked);
        SelectSaved(aa, Get(d, "aa", Selected(aa)));
        SelectSaved(shinyOdds, Get(d, "shinyOdds", Selected(shinyOdds)));

        UpdateStates();
    }

    void SaveSettings()
    {
        try
        {
            Directory.CreateDirectory(AppDataRoot);
            List<string> lines = new List<string>();

            lines.Add("resolution=" + Selected(resolution));
            lines.Add("customW=" + customW.Text);
            lines.Add("customH=" + customH.Text);
            lines.Add("videoMode=" + Selected(videoMode));
            lines.Add("gamepad=" + (gamepad.Checked ? "1" : "0"));
            lines.Add("faithfulRes=" + Selected(faithfulRes));
            lines.Add("screenPos=" + Selected(screenPos));
            lines.Add("fpsCap=" + Selected(fpsCap));
            lines.Add("performance=" + Selected(performance));

            lines.Add("textSpeed=" + Selected(textSpeed));
            lines.Add("animations=" + (animations.Checked ? "1" : "0"));
            lines.Add("ruleset=" + Selected(ruleset));
            lines.Add("dateFormat=" + Selected(dateFormat));
            lines.Add("timeFormat=" + Selected(timeFormat));
            lines.Add("speedOverworld=" + Selected(speedOverworld));
            lines.Add("speedBattle=" + Selected(speedBattle));
            lines.Add("speedMenu=" + Selected(speedMenu));

            lines.Add("battleStyle=" + Selected(battleStyle));
            lines.Add("battleLayout=" + Selected(battleLayout));
            lines.Add("battleFit=" + Selected(battleFit));
            lines.Add("battleHud=" + Selected(battleHud));
            lines.Add("battleBg=" + Selected(battleBg));
            lines.Add("uiLayout=" + Selected(uiLayout));

            lines.Add("musicVol=" + ((int)musicVol.Value));
            lines.Add("sfxVol=" + ((int)sfxVol.Value));
            lines.Add("pikaVol=" + ((int)pikaVol.Value));
            lines.Add("musicFilter=" + Selected(musicFilter));
            lines.Add("colors=" + Selected(colors));
            lines.Add("zoom=" + ((int)zoom.Value));
            lines.Add("voidFill=" + Selected(voidFill));
            lines.Add("tilt=" + Selected(tilt));
            lines.Add("safeMode=" + (safeMode.Checked ? "1" : "0"));

            lines.Add("dsEnabled=" + (dsEnabled.Checked ? "1" : "0"));
            lines.Add("voxelLevel=" + Selected(voxelLevel));
            lines.Add("tiltShift=" + Selected(tiltShift));
            lines.Add("voxelGrid=" + (voxelGrid.Checked ? "1" : "0"));
            lines.Add("curve=" + Selected(curve));
            lines.Add("renderDist=" + Selected(renderDist));
            lines.Add("water=" + Selected(water));
            lines.Add("daytime=" + Selected(daytime));
            lines.Add("battle3d=" + Selected(battle3d));
            lines.Add("backSprites=" + (backSprites.Checked ? "1" : "0"));
            lines.Add("letsGo=" + Selected(letsGo));
            lines.Add("forestFx=" + Selected(forestFx));
            lines.Add("shadows=" + (shadows.Checked ? "1" : "0"));
            lines.Add("aa=" + Selected(aa));
            lines.Add("shinyOdds=" + Selected(shinyOdds));

            File.WriteAllLines(IniPath, lines.ToArray());
        }
        catch {}
    }

    [STAThread]
    public static void Main()
    {
        Application.EnableVisualStyles();
        Application.SetCompatibleTextRenderingDefault(false);
        Application.Run(new Pokemon3DLauncher());
    }
}
'@

    $source = $source.Replace("__GAME_ID__", $GameId).Replace("__GAME_NAME__", $GameName).Replace("__PAYLOAD_ID__", $PayloadId)

    if (Test-Path $launcherPath) {
        Remove-Item $launcherPath -Force
    }

    Add-Type `
        -TypeDefinition $source `
        -Language CSharp `
        -ReferencedAssemblies @("System.dll", "System.Drawing.dll", "System.Windows.Forms.dll", "System.IO.Compression.dll", "System.IO.Compression.FileSystem.dll") `
        -OutputAssembly $launcherPath `
        -OutputType WindowsApplication

    if (-not (Test-Path $launcherPath)) {
        Fail "No se pudo compilar el launcher EXE."
    }
}

# ------------------------- START -------------------------

Write-Host "============================================================"
Write-Host " Pokemon 3D Portable Builder v18"
Write-Host " Gen1Recomp + Dramatic Shape Voxel Mod"
Write-Host " Descarga automaticamente todas las dependencias"
Write-Host "============================================================"

if (-not $Rom) { $Rom = Pick-Rom }
if (-not $Rom) { Fail "No seleccionaste ninguna ROM." }
if (-not (Test-Path -LiteralPath $Rom -PathType Leaf)) { Fail "La ROM no existe: $Rom" }
$Rom = (Resolve-Path -LiteralPath $Rom).Path

Write-Step "Verificando ROM"
$sha1 = (Get-FileHash -LiteralPath $Rom -Algorithm SHA1).Hash.ToLowerInvariant()

$roms = @{
    "ea9bcae617fdf159b045185467ae58b2e4a48b9a" = @{ id="red";    name="Pokemon Red" }
    "d7037c83e1ae5b39bde3c30787637ba1d4c48ce2" = @{ id="blue";   name="Pokemon Blue" }
    "cc7d03262ebfaf2f06772c1a480c7d9d5f4a38e1" = @{ id="yellow"; name="Pokemon Yellow" }
}

if (-not $roms.ContainsKey($sha1)) {
    Fail ("ROM no compatible. SHA-1 detectado: " + $sha1 + "`n" +
          "Se requiere un dump canonico US de Pokemon Red, Blue o Yellow.")
}
$game = $roms[$sha1]
Write-Host ("Detectado: " + $game.name + " [" + $game.id + "]") -ForegroundColor Green

if (Test-Path $Work) { Remove-Item $Work -Recurse -Force }
New-Item -ItemType Directory -Path $Work -Force | Out-Null
New-Item -ItemType Directory -Path $Dist -Force | Out-Null
New-Item -ItemType Directory -Path $Deps -Force | Out-Null

Write-Step "Preparando Gen1Recomp"
$sourceZip = Join-Path $Deps "gen1recomp-latest.zip"
$versionFile = Join-Path $Deps "gen1recomp-version.txt"
$forceDeps = $env:FORCE_DEP_UPDATE -eq "1"

if ((Test-CachedZip $sourceZip 100000) -and -not $forceDeps) {
    Show-Cached "Gen1Recomp" $sourceZip

    if (Test-Path -LiteralPath $versionFile) {
        $engineVersion = (Get-Content -LiteralPath $versionFile -Raw).Trim()
        if (-not $engineVersion) { $engineVersion = "cached" }
    }
    else {
        # Compatible with an existing _deps folder created by v8/v9/v10.
        $engineVersion = "cached"
    }
}
else {
    if ($forceDeps) {
        Write-Host "[FORZANDO ACTUALIZACION] Gen1Recomp" -ForegroundColor Yellow
    }

    try {
        $g1Release = Invoke-RestMethod `
            -Headers $Headers `
            -Uri "https://api.github.com/repos/bryanthaboi/gen1recomp/releases/latest"

        $sourceUrl = [string]$g1Release.zipball_url
        if (-not $sourceUrl) {
            throw "La API no devolvio zipball_url."
        }

        $engineVersion = [string]$g1Release.tag_name

        if (Test-Path -LiteralPath $sourceZip) {
            Remove-Item -LiteralPath $sourceZip -Force -ErrorAction SilentlyContinue
        }

        Get-CachedZip `
            ("Gen1Recomp " + $engineVersion) `
            $sourceUrl `
            $sourceZip `
            100000 | Out-Null

        Set-Content -LiteralPath $versionFile -Value $engineVersion -Encoding ASCII
    }
    catch {
        Write-Host "Aviso: no se pudo resolver Releases; usando cache/dev." -ForegroundColor Yellow

        if (Test-CachedZip $sourceZip 100000) {
            Show-Cached "Gen1Recomp (cache existente)" $sourceZip
            $engineVersion = "cached"
        }
        else {
            $engineVersion = "dev"
            Get-CachedZip `
                "Gen1Recomp dev" `
                "https://github.com/bryanthaboi/gen1recomp/archive/refs/heads/dev.zip" `
                $sourceZip `
                100000 | Out-Null
            Set-Content -LiteralPath $versionFile -Value $engineVersion -Encoding ASCII
        }
    }
}

$sourceUnpack = Join-Path $Work "source"
Expand-Zip $sourceZip $sourceUnpack
$sourceRoot = Get-FirstDirectory $sourceUnpack
Write-Host "Gen1Recomp: $engineVersion"

Write-Step "Preparando icono de la caratula"
$coverPath = Join-Path $Root ("covers\" + [string]$game.id + ".jpg")
$gameIconPng = Join-Path $Work "game_icon.png"
$gameIconIco = Join-Path $Work "game_icon.ico"
$hasCustomIcon = Prepare-GameIcon $coverPath $gameIconPng $gameIconIco
if ($hasCustomIcon) {
    Copy-Item -LiteralPath $gameIconPng -Destination (Join-Path $sourceRoot "game_icon.png") -Force
    Write-Host ("Icono seleccionado: covers\" + [string]$game.id + ".jpg") -ForegroundColor Green
}
else {
    $gameIconPng = $null
    $gameIconIco = $null
    Write-Host "Build continuara sin caratula personalizada." -ForegroundColor Yellow
}

Write-Step "Preparando runtime LÖVE 11.5 x64"
$loveZip = Join-Path $Deps "love-11.5-win64.zip"

Get-CachedZip `
    "LÖVE 11.5 x64" `
    "https://github.com/love2d/love/releases/download/11.5/love-11.5-win64.zip" `
    $loveZip `
    1000000 | Out-Null
$loveUnpack = Join-Path $Work "love"
Expand-Zip $loveZip $loveUnpack
$loveRoot = Get-FirstDirectory $loveUnpack
$loveExe = Join-Path $loveRoot "love.exe"
if (-not (Test-Path $loveExe)) {
    Fail "No se encontro love.exe en el runtime descargado."
}

# v6: complete cache at build time; the finished game never imports the ROM.
Build-CompleteRomCache $sourceRoot $Rom ([string]$game.id) $loveExe

$runtimeCacheStage = Join-Path $Work "runtime-cache"
Stage-RuntimeRomCache $sourceRoot ([string]$game.id) $runtimeCacheStage


Write-Step "Preparando Dramatic Shape Voxel Mod - Full Window Battle"

# v13 pins a known revision whose BattleScene renders staged 3D battles at
# the WINDOW'S own pixel dimensions and widens the camera around the classic
# 160x144 frame. A new cache filename intentionally causes ONE download when
# upgrading from v11; later builds reuse it normally.
$modZip = Join-Path $Deps "DramaticShapeVoxelMod-fullwindow-cd10ac31.zip"
$modDownloaded = $false
$modSourceName = ""
$forceDeps = $env:FORCE_DEP_UPDATE -eq "1"

if ((Test-CachedZip $modZip 50000) -and -not $forceDeps) {
    Show-Cached "Dramatic Shape Full-Window Battle cd10ac31" $modZip
    $modDownloaded = $true
    $modSourceName = "cache local cd10ac31"
}
else {
    if ($forceDeps) {
        Write-Host "[FORZANDO ACTUALIZACION] Dramatic Shape Full-Window Battle" -ForegroundColor Yellow
    }

    if (Test-Path -LiteralPath $modZip) {
        Remove-Item -LiteralPath $modZip -Force -ErrorAction SilentlyContinue
    }

    $modSources = @(
        @{
            Name = "Dramatic Shape pinned full-window revision cd10ac31"
            Url  = "https://github.com/scottcandy34/DramaticShapeVoxelMod-latest/archive/cd10ac3158db9a53e2e33efa3651935723715c9b.zip"
        },
        @{
            Name = "Dramatic Shape current dev fallback"
            Url  = "https://github.com/scottcandy34/DramaticShapeVoxelMod-latest/archive/refs/heads/dev.zip"
        }
    )

    foreach ($modSource in $modSources) {
        try {
            if (Test-Path -LiteralPath $modZip) {
                Remove-Item -LiteralPath $modZip -Force -ErrorAction SilentlyContinue
            }

            Write-Host ("[DESCARGANDO] " + [string]$modSource.Name) -ForegroundColor Cyan
            Download-File ([string]$modSource.Url) $modZip

            if (Test-CachedZip $modZip 50000) {
                $modDownloaded = $true
                $modSourceName = [string]$modSource.Name
                break
            }
        }
        catch {
            Write-Host ("No disponible: " + [string]$modSource.Name) -ForegroundColor Yellow
        }
    }
}

if (-not $modDownloaded) {
    Fail "No se pudo obtener la revision Full-Window de Dramatic Shape."
}

$modId = Install-VoxelMod $sourceRoot $modZip (Join-Path $Work "voxelmod")
Validate-DramaticShapeFullWindowBattle $sourceRoot

Patch-3DBattleWorldOverrideDim $sourceRoot



$installedManifest = Join-Path (Join-Path $sourceRoot "mods") (Join-Path $modId "manifest.json")
$modVersion = "desconocida"
if (Test-Path $installedManifest) {
    try {
        $installedMeta = Get-Content -LiteralPath $installedManifest -Raw | ConvertFrom-Json
        if ($installedMeta.version) { $modVersion = [string]$installedMeta.version }
    } catch {}
}

Write-Host ("Voxel Mod instalado: " + $modId + " v" + $modVersion + " (" + $modSourceName + ")") -ForegroundColor Green

Write-Step "Aplicando soporte de launcher: resolucion, fullscreen y mando"
Patch-Gen1Config $sourceRoot
Patch-AppDataPersistence $sourceRoot
Patch-LauncherOptions $sourceRoot
Patch-LauncherPipelines $sourceRoot
Patch-LauncherModEnable $sourceRoot

Write-Step "Empaquetando juego LÖVE"
$gameLove = Join-Path $Work "game.love"
Make-GameLove $sourceRoot $gameLove

$safeGameName = ($game.name -replace '[^\w\- ]','').Trim()
$outDir = Join-Path $Dist ($safeGameName + " 3D Portable")
if (Test-Path $outDir) { Remove-Item $outDir -Recurse -Force }
$runtimeDir = Join-Path $outDir "runtime"
New-Item -ItemType Directory -Path $runtimeDir -Force | Out-Null

Write-Step "Creando runtime privado"
$fusedExe = Join-Path $runtimeDir "Gen1Recomp3D.exe"

# Patch a COPY of love.exe before appending game.love. Editing resources
# after fusion can risk the PE overlay that contains the .love archive.
$loveExeWithIcon = Join-Path $Work "love-game-icon.exe"
Copy-Item -LiteralPath $loveExe -Destination $loveExeWithIcon -Force
Apply-ExeIcon $loveExeWithIcon $gameIconIco ([string]$game.name + " 3D")
Fuse-Love $loveExeWithIcon $gameLove $fusedExe

Get-ChildItem -LiteralPath $loveRoot -File |
    Where-Object { $_.Name -notin @("love.exe", "lovec.exe") } |
    Copy-Item -Destination $runtimeDir -Force


# v9: ROM-derived cache is an external, real directory. This is what
# Gen1Recomp's CacheFs.mountVersion() is designed to mount for Blue/Yellow.
$stagedGameCache = Join-Path $runtimeCacheStage ([string]$game.id)
$runtimeGameCache = Join-Path $runtimeDir ([string]$game.id)

if (-not (Test-Path -LiteralPath $stagedGameCache -PathType Container)) {
    Fail ("No se encontro el cache staged: " + $stagedGameCache)
}

Copy-Item -LiteralPath $stagedGameCache -Destination $runtimeGameCache -Recurse -Force

# portable.txt is intentionally used ONLY for CacheFs. Our SaveData patch
# gives POKEPORT_PERSIST_DIR higher priority, so options/saves continue in
# %APPDATA%\PokemonRed|Blue|Yellow rather than beside the EXE.
New-Item -ItemType File -Path (Join-Path $runtimeDir "portable.txt") -Force | Out-Null

$runtimeMarker = Join-Path $runtimeGameCache "rom-cache.complete"
$runtimeAudio = Join-Path $runtimeGameCache "assets\generated\audio\programs.bin"
if (-not (Test-Path $runtimeMarker) -or -not (Test-Path $runtimeAudio)) {
    Fail "El cache externo no se copio correctamente al runtime."
}

Write-Host ("Cache externo instalado: runtime\" + [string]$game.id + "\") -ForegroundColor Green

# v9 persistence split:
# - runtime\portable.txt routes ONLY the ROM-derived cache through CacheFs.
# - POKEPORT_PERSIST_DIR still wins for SaveData, so saves/options remain:
#   %APPDATA%\PokemonRed\saves\
#   %APPDATA%\PokemonBlue\saves\
#   %APPDATA%\PokemonYellow\saves\

Write-Step "Preparando payload para EXE unico"
$payloadZip = Join-Path $Work "runtime-payload-v17.zip"
New-RuntimePayloadZip $runtimeDir $payloadZip

$payloadHash = (Get-FileHash -LiteralPath $payloadZip -Algorithm SHA256).Hash.ToLowerInvariant()
$payloadId = $payloadHash.Substring(0, 16)
Write-Host ("Payload ID: " + $payloadId) -ForegroundColor Green

Write-Step "Compilando launcher EXE monolitico"
New-Item -ItemType Directory -Path $outDir -Force | Out-Null
Build-Launcher $outDir ([string]$game.id) ([string]$game.name) $payloadId

$launcherExe = Join-Path $outDir "Pokemon 3D Portable.exe"
Apply-ExeIcon $launcherExe $gameIconIco ([string]$game.name + " 3D Launcher")

# rcedit must finish BEFORE the payload is appended, otherwise a PE resource
# rewrite could truncate/rebuild the overlay.
if (-not (Wait-FileUnlocked $launcherExe 60)) {
    Fail "El launcher sigue bloqueado despues de aplicar el icono."
}

Append-PayloadToExe $launcherExe $payloadZip

# The runtime directory was only build material. The finished distribution
# must contain ONE file and nothing else.
if (Test-Path -LiteralPath $runtimeDir) {
    Remove-Item -LiteralPath $runtimeDir -Recurse -Force
}

Get-ChildItem -LiteralPath $outDir -Force |
    Where-Object { $_.FullName -ne $launcherExe } |
    Remove-Item -Recurse -Force -ErrorAction SilentlyContinue

$left = @(Get-ChildItem -LiteralPath $outDir -File)
if ($left.Count -ne 1 -or $left[0].Name -ne "Pokemon 3D Portable.exe") {
    Fail "La carpeta final no contiene exclusivamente Pokemon 3D Portable.exe."
}

if ($gameIconIco) {
    Write-Host "Icono de caratula incrustado. Runtime/cache ahora viven DENTRO del EXE." -ForegroundColor Green
}
else {
    Write-Host "EXE monolitico creado sin icono de caratula personalizado." -ForegroundColor Green
}

$outZip = Join-Path $Dist ($safeGameName + " 3D Portable - SINGLE EXE.zip")
New-SingleExeZip $launcherExe $outZip $Work

Write-Host ""
Write-Host "============================================================" -ForegroundColor Green
Write-Host " LISTO" -ForegroundColor Green
Write-Host " EXE:     $launcherExe"
Write-Host " ZIP:     $outZip"
Write-Host " El ZIP contiene SOLO el EXE."
Write-Host "============================================================" -ForegroundColor Green

Start-Process explorer.exe -ArgumentList ('"' + $outDir + '"')
