<#
.SYNOPSIS
  Перенос собственного провайдера (и всей привязки моделей) OpenCode Desktop между компьютерами.

.DESCRIPTION
  Экспорт: собирает конфиг opencode (opencode.json / opencode.jsonc / .opencode),
           файл ключей auth.json (папка data) и выбранные переменные окружения
           (например API-ключ провайдера) в один zip.

  Импорт:  разворачивает zip на другой машине. Конфиг сливается с уже существующим
           (провайдеры/модели/настройки из архива имеют приоритет), auth.json
           сливается по провайдерам, отсутствующие переменные окружения добавляются
           как пользовательские переменные (если запущено с параметром -SetEnv).

  Ничего не удаляет: старые файлы сохраняются через .bak.

.EXAMPLE
  .\opencode-port.cmd
  .\opencode-port.cmd export
  .\opencode-port.cmd export -Secrets All -Env AISTAR_API_KEY
  .\opencode-port.cmd import -Zip .\opencode-port-....zip
  .\opencode-port.cmd import -Zip .\x.zip -SetEnv -OverwriteEnv
#>

[CmdletBinding()]
param(
  [Parameter(Position = 0)]
  [ValidateSet('export', 'import', 'menu')]
  [string]$Mode = 'menu',

  [string]$Out,
  [string]$Zip,
  [ValidateSet('None', 'Auth', 'Vars', 'All')]
  [string]$Secrets = 'Auth',
  [Alias('Env')]
  [string[]]$EnvVars,
  [switch]$SetEnv,
  [switch]$OverwriteEnv,
  [switch]$DryRun,
  [switch]$DryRunExport,
  [string]$HomeDir = $env:USERPROFILE
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$script:Format = 'opencode-port'
$script:Version = 1

function Say([string]$Text, [string]$Color = 'Gray') {
  Write-Host $Text -ForegroundColor $Color
}

# Strict-mode-safe: значение свойства объекта, если свойство есть; иначе default.
function Get-Prop($Object, [string]$Name, $Default = $null) {
  if ($null -eq $Object) { return $Default }
  if ($Object.PSObject.Properties.Name -contains $Name) { return $Object.$Name }
  return $Default
}

function Get-EnvPath([string]$Name) {
  $user = [Environment]::GetEnvironmentVariable($Name, 'User')
  $machine = [Environment]::GetEnvironmentVariable($Name, 'Machine')
  $process = [Environment]::GetEnvironmentVariable($Name, 'Process')

  $value = $process
  $scope = 'Process'
  if ([string]::IsNullOrEmpty($value)) { $value = $user; $scope = 'User' }
  if ([string]::IsNullOrEmpty($value)) { $value = $machine; $scope = 'Machine' }
  [pscustomobject]@{ Name = $Name; Value = $value; Scope = $scope }
}

# Resolve opencode paths the same way the desktop sidecar does:
#   config -> %XDG_CONFIG_HOME%\opencode  (else %USERPROFILE%\.config\opencode)
#   data   -> %XDG_DATA_HOME%\opencode    (else %USERPROFILE%\.local\share\opencode)
function Get-OpencodePaths([string]$HomeDir) {
  $xdgConfig = $env:XDG_CONFIG_HOME
  if ([string]::IsNullOrWhiteSpace($xdgConfig)) { $xdgConfig = Join-Path $HomeDir '.config' }
  $xdgData = $env:XDG_DATA_HOME
  if ([string]::IsNullOrWhiteSpace($xdgData)) { $xdgData = Join-Path $HomeDir '.local\share' }

  $configDir = if ($env:OPENCODE_CONFIG_DIR) { $env:OPENCODE_CONFIG_DIR } else { Join-Path $xdgConfig 'opencode' }
  $dataDir = Join-Path $xdgData 'opencode'

  $configFiles = @()
  foreach ($name in 'opencode.jsonc', 'opencode.json') {
    $p = Join-Path $configDir $name
    if (Test-Path -LiteralPath $p -PathType Leaf) { $configFiles += (Get-Item -LiteralPath $p) }
  }

  [pscustomobject]@{
    Home        = $HomeDir
    ConfigDir   = $configDir
    ConfigFiles = $configFiles
    DataDir     = $dataDir
    AuthFile    = Join-Path $dataDir 'auth.json'
  }
}

# Парсит JSON, а также JSONC (одиночные //, блочные /* */ комментарии и
# висячие запятые) — так же, как их понимает сам opencode.
function ConvertFrom-JsonText([string]$Text) {
  if ([string]::IsNullOrWhiteSpace($Text)) {
    return [pscustomobject]@{ Ok = $true; Data = $null }
  }

  $sb = New-Object System.Text.StringBuilder
  $i = 0
  $n = $Text.Length
  $inString = $false
  $lastComma = -1

  while ($i -lt $n) {
    $c = $text[$i]

    if ($inString) {
      [void]$sb.Append($c)
      if ($c -eq '\' -and ($i + 1) -lt $n) {
        [void]$sb.Append($text[$i + 1])
        $i += 2
        continue
      }
      if ($c -eq '"') { $inString = $false }
      $i++
      continue
    }

    if ($c -eq '"') {
      $inString = $true
      $lastComma = -1
      [void]$sb.Append($c)
      $i++
      continue
    }

    if ($c -eq '/' -and ($i + 1) -lt $n -and $text[$i + 1] -eq '/') {
      while ($i -lt $n -and $text[$i] -ne "`n") { $i++ }
      [void]$sb.Append(' ')
      continue
    }

    if ($c -eq '/' -and ($i + 1) -lt $n -and $text[$i + 1] -eq '*') {
      $i += 2
      while ($i -lt ($n - 1) -and -not ($text[$i] -eq '*' -and $text[$i + 1] -eq '/')) { $i++ }
      $i = [Math]::Min($i + 2, $n)
      [void]$sb.Append(' ')
      continue
    }

    if ($c -eq ',') {
      $lastComma = $sb.Length
      [void]$sb.Append($c)
      $i++
      continue
    }

    if ($c -eq '}' -or $c -eq ']') {
      if ($lastComma -ge 0) {
        # между запятой и закрывающей скобкой только пробелы -> запятая висячая
        [void]$sb.Remove($lastComma, 1)
        $lastComma = -1
      }
      [void]$sb.Append($c)
      $i++
      continue
    }

    if (-not [char]::IsWhiteSpace($c)) { $lastComma = -1 }
    [void]$sb.Append($c)
    $i++
  }

  try {
    $data = $sb.ToString() | ConvertFrom-Json
    return [pscustomobject]@{ Ok = $true; Data = $data }
  } catch {
    return [pscustomobject]@{ Ok = $false; Data = $null; Error = $_.Exception.Message }
  }
}

function Read-JsonFile([string]$Path) {
  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
    return [pscustomobject]@{ Ok = $true; Data = $null }
  }
  try {
    $raw = [System.IO.File]::ReadAllText($Path)
  } catch {
    return [pscustomobject]@{ Ok = $false; Data = $null; Error = $_.Exception.Message }
  }
  $parsed = ConvertFrom-JsonText $raw
  return $parsed
}

function Merge-JsonNode($Base, $Overlay) {
  if ($null -eq $Overlay) { return $Base }
  if ($null -eq $Base) { return $Overlay }
  if ($Base -isnot [System.Management.Automation.PSCustomObject] -or $Overlay -isnot [System.Management.Automation.PSCustomObject]) { return $Overlay }

  $result = [ordered]@{}
  foreach ($p in $Base.PSObject.Properties) { $result[$p.Name] = $p.Value }
  foreach ($p in $Overlay.PSObject.Properties) {
    if ($result.Contains($p.Name)) {
      $result[$p.Name] = Merge-JsonNode $result[$p.Name] $p.Value
    } else {
      $result[$p.Name] = $p.Value
    }
  }
  [pscustomobject]$result
}

function Write-JsonFile([string]$Path, $Object) {
  $json = $Object | ConvertTo-Json -Depth 100
  $utf8 = New-Object System.Text.UTF8Encoding($false)
  [System.IO.File]::WriteAllText($Path, $json, $utf8)
}

function Backup-File([string]$Path) {
  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
  $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
  $backup = "$Path.$stamp.bak"
  Copy-Item -LiteralPath $Path -Destination $backup -Force
  $backup
}

function Copy-DirectoryContents([string]$Source, [string]$Destination) {
  if (-not (Test-Path -LiteralPath $Destination)) { New-Item -ItemType Directory -Path $Destination -Force | Out-Null }
  $copied = @()
  Get-ChildItem -LiteralPath $Source -Force | ForEach-Object {
    $target = Join-Path $Destination $_.Name
    Copy-Item -LiteralPath $_.FullName -Destination $target -Recurse -Force
    $copied += $_.Name
  }
  $copied
}

function Compress-ArchiveSafe([string]$SourceDir, [string]$Destination) {
  if (Test-Path -LiteralPath $Destination -PathType Container) {
    throw "Путь '$Destination' — каталог. Укажите имя файла (например .\port.zip)."
  }
  if (Test-Path -LiteralPath $Destination -PathType Leaf) { Remove-Item -LiteralPath $Destination -Force }
  Compress-Archive -Path $SourceDir -DestinationPath $Destination -CompressionLevel Optimal
}

function Get-DesktopVersion {
  $exe = Join-Path $env:LOCALAPPDATA 'Programs\@opencode-aidesktop\OpenCode.exe'
  if (-not (Test-Path -LiteralPath $exe -PathType Leaf)) { return $null }
  try { return (Get-Item -LiteralPath $exe).VersionInfo.FileVersion } catch { return $null }
}

function Invoke-Export {
  param(
    [string]$OutputPath,
    [string]$SecretsMode = 'Auth',
    [string[]]$EnvNames = @(),
    [string]$HomeDir = $env:USERPROFILE,
    [switch]$DryRun
  )

  $paths = Get-OpencodePaths $HomeDir
  if ($paths.ConfigFiles.Count -eq 0) {
    throw "Не найден конфиг opencode в $($paths.ConfigDir) (ожидался opencode.json или opencode.jsonc)."
  }

  $providers = @()
  $warnings = @()
  foreach ($file in $paths.ConfigFiles) {
    $parsed = Read-JsonFile $file.FullName
    if (-not $parsed.Ok) {
      $warnings += "$($file.Name): не удалось разобрать (даже с учётом комментариев JSONC) — файл скопирован как есть."
      continue
    }
    $prov = Get-Prop $parsed.Data 'provider' $null
    if ($prov -is [System.Management.Automation.PSCustomObject]) { $providers += $prov }
  }
  $providerNames = @()
  foreach ($p in $providers) { $providerNames += @($p.PSObject.Properties.Name) }
  $providerNames = @($providerNames | Sort-Object -Unique)

  $staging = Join-Path ([System.IO.Path]::GetTempPath()) ("opencode-port-" + [guid]::NewGuid().ToString('N'))
  New-Item -ItemType Directory -Path $staging -Force | Out-Null

  try {
    $filesRoot = Join-Path $staging 'opencode-port'
    $configRoot = Join-Path $filesRoot 'config'
    New-Item -ItemType Directory -Path $configRoot -Force | Out-Null

    foreach ($file in $paths.ConfigFiles) {
      Copy-Item -LiteralPath $file.FullName -Destination (Join-Path $configRoot $file.Name) -Force
    }
    $localConfigDir = Join-Path $paths.ConfigDir '.opencode'
    if (Test-Path -LiteralPath $localConfigDir -PathType Container) {
      $target = Join-Path $configRoot '.opencode'
      New-Item -ItemType Directory -Path $target -Force | Out-Null
      Copy-DirectoryContents $localConfigDir $target | Out-Null
    }

    $authIncluded = @()
    if ($SecretsMode -in 'Auth', 'All') {
      if (Test-Path -LiteralPath $paths.AuthFile -PathType Leaf) {
        New-Item -ItemType Directory -Path (Join-Path $filesRoot 'data') -Force | Out-Null
        Copy-Item -LiteralPath $paths.AuthFile -Destination (Join-Path $filesRoot 'data\auth.json') -Force
        $auth = Read-JsonFile $paths.AuthFile
        if ($auth.Ok -and $null -ne $auth.Data) { $authIncluded = @($auth.Data.PSObject.Properties.Name) }
      } else {
        $warnings += "auth.json не найден ($($paths.AuthFile)) — ключи API не экспортированы."
      }
    }

    $exports = @()
    if ($SecretsMode -in 'Vars', 'All') {
      $names = @($EnvNames | Where-Object { $_ })
      if ($names.Count -eq 0) { $names = @('OPENCODE_AUTH_CONTENT') }
      foreach ($name in $names) {
        $item = Get-EnvPath $name
        if ([string]::IsNullOrEmpty($item.Value)) {
          $warnings += "Переменная окружения $name не задана — пропущена."
          continue
        }
        $exports += [pscustomobject]@{
          name  = $name
          scope = $item.Scope
          value = $item.Value
        }
      }
    } elseif (@($EnvNames | Where-Object { $_ }).Count -gt 0) {
      $warnings += 'Имена переменных заданы (-Env), но -Secrets не включает Vars/All — переменные не экспортированы.'
    }

    $manifest = [pscustomobject]@{
      format         = $script:Format
      version        = $script:Version
      created        = (Get-Date).ToString('o')
      computer       = $env:COMPUTERNAME
      user           = $env:USERNAME
      desktopVersion = (Get-DesktopVersion)
      providers      = $providerNames
      auth           = $authIncluded
      env            = @($exports | ForEach-Object { [pscustomobject]@{ name = $_.name; scope = $_.scope } })
      configFiles    = @($paths.ConfigFiles | ForEach-Object { $_.Name })
      warnings       = $warnings
    }
    Write-JsonFile (Join-Path $filesRoot 'manifest.json') $manifest
    if ($exports.Count -gt 0) {
      New-Item -ItemType Directory -Path (Join-Path $filesRoot 'env') -Force | Out-Null
      Write-JsonFile (Join-Path $filesRoot 'env\env.json') ([pscustomobject]@{ vars = $exports })
    }

    Say ''
    Say "Провайдеры: $(if ($providerNames.Count) { $providerNames -join ', ' } else { '(в конфиге не найдены)' })" 'Cyan'
    Say "Ключи API (auth.json): $(if ($authIncluded.Count) { $authIncluded -join ', ' } else { 'нет' })" 'Cyan'
    if ($exports.Count) { Say "Переменные окружения: $((@($exports | ForEach-Object { $_.name })) -join ', ')" 'Cyan' }
    foreach ($w in $warnings) { Say "! $w" 'Yellow' }

    if ($DryRun) {
      Say ''
      Say 'DryRun: архив не создаётся. Содержимое staging:' 'Yellow'
      Get-ChildItem -LiteralPath $filesRoot -Recurse -File | ForEach-Object { $_.FullName.Substring($filesRoot.Length + 1) }
      return
    }

    $outPath = $OutputPath
    if ([string]::IsNullOrWhiteSpace($outPath)) {
      $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
      $outPath = Join-Path (Get-Location).Path "opencode-port-$($env:COMPUTERNAME)-$stamp.zip"
    }
    if (Test-Path -LiteralPath $outPath -PathType Container) {
      throw "Путь '$outPath' — каталог. Укажите имя файла .zip."
    }
    $outDir = Split-Path -Parent $outPath
    if ($outDir -and -not (Test-Path -LiteralPath $outDir)) { New-Item -ItemType Directory -Path $outDir -Force | Out-Null }

    Compress-ArchiveSafe -SourceDir $filesRoot -Destination $outPath
    Say ''
    Say "Готово: $outPath" 'Green'
    if ($SecretsMode -in 'Auth', 'All') {
      Say 'ВНИМАНИЕ: архив содержит API-ключ. Храните и передавайте его как секрет.' 'Yellow'
    }
    return $outPath
  } finally {
    if (Test-Path -LiteralPath $staging) { Remove-Item -LiteralPath $staging -Recurse -Force -ErrorAction SilentlyContinue }
  }
}

function Find-ArchiveRoot([string]$Dir) {
  $direct = Join-Path $Dir 'opencode-port'
  if (Test-Path -LiteralPath (Join-Path $direct 'manifest.json') -PathType Leaf) { return $direct }
  $found = Get-ChildItem -LiteralPath $Dir -Recurse -Filter 'manifest.json' -File -ErrorAction SilentlyContinue |
    Where-Object { $_.Directory.Name -eq 'opencode-port' } | Select-Object -First 1
  if (-not $found) { throw 'В архиве нет opencode-port\manifest.json — это не архив opencode-port.' }
  $found.Directory.FullName
}

function Test-OpencodeRunning {
  foreach ($n in @('OpenCode', 'opencode')) {
    if (Get-Process -Name $n -ErrorAction SilentlyContinue) { return $true }
  }
  return $false
}

function Invoke-Import {
  param(
    [string]$ArchivePath,
    [string]$HomeDir = $env:USERPROFILE,
    [switch]$ApplyEnv,
    [switch]$ForceEnv,
    [switch]$DryRun
  )

  if ([string]::IsNullOrWhiteSpace($ArchivePath)) { throw 'Не указан путь к архиву (-Zip).' }
  if (-not (Test-Path -LiteralPath $ArchivePath -PathType Leaf)) { throw "Архив не найден: $ArchivePath" }
  if ((Test-OpencodeRunning) -and -not $DryRun -and $HomeDir -eq $env:USERPROFILE) {
    throw 'OpenCode Desktop запущен. Закройте приложение (включая трей) и повторите импорт — иначе sidecar перезапишет конфиг из памяти.'
  }

  $paths = Get-OpencodePaths $HomeDir
  $staging = Join-Path ([System.IO.Path]::GetTempPath()) ("opencode-port-import-" + [guid]::NewGuid().ToString('N'))
  New-Item -ItemType Directory -Path $staging -Force | Out-Null

  try {
    Expand-Archive -LiteralPath $ArchivePath -DestinationPath $staging -Force
    $root = Find-ArchiveRoot $staging
    $manifest = Read-JsonFile (Join-Path $root 'manifest.json')
    if (-not $manifest.Ok -or $null -eq $manifest.Data) { throw 'manifest.json повреждён или пуст.' }

    $meta = $manifest.Data
    $archiveFormat = Get-Prop $meta 'format' ''
    if ($archiveFormat -ne $script:Format) { throw "Неизвестный формат архива: '$archiveFormat'" }
    $archiveVersion = Get-Prop $meta 'version' 0
    if ($archiveVersion -gt $script:Version) {
      Say "! Архив создан более новой версией скрипта ($archiveVersion > $($script:Version)) — возможны несовместимости." 'Yellow'
    }
    $archiveProviders = @(Get-Prop $meta 'providers' @())

    $archiveConfigDir = Join-Path $root 'config'
    $changes = @()

    if (Test-Path -LiteralPath $archiveConfigDir -PathType Container) {
      if (-not (Test-Path -LiteralPath $paths.ConfigDir)) {
        New-Item -ItemType Directory -Path $paths.ConfigDir -Force | Out-Null
      }

      # Оверлей из архива: json, затем поверх jsonc (как их загружает opencode).
      $overlay = $null
      $overlaySources = @()
      foreach ($name in 'opencode.json', 'opencode.jsonc') {
        $p = Join-Path $archiveConfigDir $name
        if (-not (Test-Path -LiteralPath $p -PathType Leaf)) { continue }
        $parsed = Read-JsonFile $p
        if (-not $parsed.Ok) {
          Say "! $name в архиве не разбирается (даже с учётом JSONC-комментариев): $($parsed.Error)" 'Yellow'
          continue
        }
        if ($null -ne $parsed.Data) {
          $overlay = Merge-JsonNode $overlay $parsed.Data
          $overlaySources += $name
        }
      }

      # База на этой машине: json, затем поверх jsonc (тот же порядок загрузки).
      $base = $null
      $baseSources = @()
      foreach ($name in 'opencode.json', 'opencode.jsonc') {
        $p = Join-Path $paths.ConfigDir $name
        if (-not (Test-Path -LiteralPath $p -PathType Leaf)) { continue }
        $parsed = Read-JsonFile $p
        if ($parsed.Ok -and $null -ne $parsed.Data) {
          $base = Merge-JsonNode $base $parsed.Data
          $baseSources += $name
        }
      }

      if ($overlay) {
        # opencode загружает opencode.json, затем opencode.jsonc (jsonc имеет приоритет).
        # Поэтому результат пишем в файл с наивысшим приоритетом, иначе старый файл
        # затенит изменённые ключи.
        $targetName = 'opencode.json'
        if (Test-Path -LiteralPath (Join-Path $paths.ConfigDir 'opencode.jsonc') -PathType Leaf) {
          $targetName = 'opencode.jsonc'
        }
        $targetPath = Join-Path $paths.ConfigDir $targetName

        $merged = Merge-JsonNode $base $overlay
        $desc = "merge -> $targetName"
        if ($baseSources.Count) { $desc += " (локальные: $($baseSources -join ' + '))" }
        $desc += "; архив: $($overlaySources -join ' + ')"
        $changes += $desc
        Say "> Слияние конфига: $desc" 'Cyan'
        if ($targetName -eq 'opencode.jsonc') {
          Say '  (локальные комментарии в opencode.jsonc не сохраняются; оригинал — в .bak)' 'DarkGray'
        }
        if (-not $DryRun) {
          Backup-File $targetPath | Out-Null
          Write-JsonFile $targetPath $merged
        }
      } else {
        # Ни один конфиг из архива не разобран — копируем как есть, чтобы не потерять данные.
        $rawConfigs = @(Get-ChildItem -LiteralPath $archiveConfigDir -Filter 'opencode.json*' -File -ErrorAction SilentlyContinue)
        foreach ($f in $rawConfigs) {
          $targetPath = Join-Path $paths.ConfigDir $f.Name
          $changes += "copy $($f.Name) (как есть)"
          Say "> $($f.Name) скопирован без слияния (неразборчивый исходник)" 'Yellow'
          if (-not $DryRun) {
            Backup-File $targetPath | Out-Null
            Copy-Item -LiteralPath $f.FullName -Destination $targetPath -Force
          }
        }
      }

      $archiveLocal = Join-Path $archiveConfigDir '.opencode'
      if (Test-Path -LiteralPath $archiveLocal -PathType Container) {
        $targetLocal = Join-Path $paths.ConfigDir '.opencode'
        $names = @(Get-ChildItem -LiteralPath $archiveLocal -Force | ForEach-Object { $_.Name })
        $changes += "copy .opencode ($($names -join ', '))"
        Say "> .opencode: $($names -join ', ')" 'Cyan'
        if (-not $DryRun) { Copy-DirectoryContents $archiveLocal $targetLocal | Out-Null }
      }
    }

    $archiveAuth = Join-Path $root 'data\auth.json'
    if (Test-Path -LiteralPath $archiveAuth -PathType Leaf) {
      $incoming = Read-JsonFile $archiveAuth
      if (-not $incoming.Ok) { throw 'data\auth.json в архиве повреждён.' }
      if ($null -ne $incoming.Data) {
        $merged = [ordered]@{}
        if (Test-Path -LiteralPath $paths.AuthFile -PathType Leaf) {
          $current = Read-JsonFile $paths.AuthFile
          if ($current.Ok -and $null -ne $current.Data) {
            foreach ($p in $current.Data.PSObject.Properties) { $merged[$p.Name] = $p.Value }
          }
        }
        $incomingNames = @()
        foreach ($p in $incoming.Data.PSObject.Properties) {
          $merged[$p.Name] = $p.Value
          $incomingNames += $p.Name
        }
        $changes += "auth.json += $($incomingNames -join ', ')"
        Say "> auth.json: провайдеры $($incomingNames -join ', ')" 'Cyan'
        if (-not $DryRun) {
          if (-not (Test-Path -LiteralPath $paths.DataDir)) { New-Item -ItemType Directory -Path $paths.DataDir -Force | Out-Null }
          Backup-File $paths.AuthFile | Out-Null
          Write-JsonFile $paths.AuthFile ([pscustomobject]$merged)
          # Права: только текущий пользователь.
          $icaclsOk = $false
          try {
            $null = icacls $paths.AuthFile /inheritance:r /grant:r "$($env:USERNAME):(F)" 2>&1
            $icaclsOk = ($LASTEXITCODE -eq 0)
          } catch { }
          if (-not $icaclsOk) { Say '! Не удалось ограничить права на auth.json (не критично).' 'Yellow' }
        }
      }
    }

    $envFile = Join-Path $root 'env\env.json'
    if (Test-Path -LiteralPath $envFile -PathType Leaf) {
      $envData = Read-JsonFile $envFile
      $envVars = @(Get-Prop $envData.Data 'vars' @())
      if ($envData.Ok -and $envVars.Count -gt 0) {
        $envApplied = 0
        foreach ($v in $envVars) {
          $vname = Get-Prop $v 'name' $null
          if ([string]::IsNullOrWhiteSpace($vname)) { continue }
          $vscope = Get-Prop $v 'scope' 'User'
          $vvalue = Get-Prop $v 'value' $null
          if ($null -eq $vvalue) { continue }

          $current = Get-EnvPath $vname
          if ((-not [string]::IsNullOrEmpty($current.Value)) -and -not $ForceEnv) {
            Say "= ${vname}: уже задана, оставлена текущая (используйте -OverwriteEnv)" 'DarkGray'
            continue
          }
          $changes += "env $vname"
          Say "> env $vname (было: $vscope)" 'Cyan'
          if (-not $DryRun -and $ApplyEnv) {
            # Пишем в пользовательскую область: машинная требует прав администратора.
            # Если переменная была машинной — пробуем обновить и её, но не падаем.
            if ($vscope -eq 'Machine') {
              try { [Environment]::SetEnvironmentVariable($vname, $vvalue, 'Machine') } catch { }
            }
            [Environment]::SetEnvironmentVariable($vname, $vvalue, 'User')
            [Environment]::SetEnvironmentVariable($vname, $vvalue, 'Process')
            $envApplied++
            Say '  записано в область: User (запущенные приложения увидят после перезапуска)' 'DarkGray'
          }
        }
        if (-not $ApplyEnv -and -not $DryRun) {
          Say '  (переменные не применены: добавьте -SetEnv)' 'Yellow'
        }
      }
    }

    Say ''
    if ($DryRun) {
      Say 'DryRun: изменения не применены. Плановые действия:' 'Yellow'
      if ($changes.Count) { $changes | ForEach-Object { Say "  - $_" } }
      else { Say '  (нечего менять)' }
      return
    }

    Say 'Готово.' 'Green'
    Say "Провайдеры в архиве: $(if ($archiveProviders.Count) { $archiveProviders -join ', ' } else { '(неизвестно)' })" 'Cyan'
    Say "Всего изменений: $($changes.Count)" 'Cyan'
    Say 'Перезапустите OpenCode Desktop и проверьте: Настройки -> Модели (провайдер должен быть в списке).' 'Yellow'
  } finally {
    if (Test-Path -LiteralPath $staging) { Remove-Item -LiteralPath $staging -Recurse -Force -ErrorAction SilentlyContinue }
  }
}

function Show-Menu {
  while ($true) {
    Say ''
    Say '=== OpenCode Desktop: перенос своего провайдера ===' 'White'
    Say '  1) Экспорт: собрать конфиг + ключи API в zip (на этом компьютере)'
    Say '  2) Импорт:  развернуть zip (на другом компьютере; OpenCode должен быть закрыт)'
    Say '  3) Проверить, что попадёт в экспорт (без записи архива)'
    Say '  0) Выход'
    $choice = Read-Host 'Выбор'
    switch ($choice) {
      '1' {
        try {
          $sec = Read-Host 'Включить секреты: [1] auth.json (ключи API), [2] auth.json + переменные окружения, [3] без секретов'
          $mode = 'Auth'
          if ($sec -eq '2') { $mode = 'All' }
          if ($sec -eq '3') { $mode = 'None' }
          $vars = @()
          if ($sec -eq '2') {
            $vars = (Read-Host 'Имена переменных окружения через запятую (Enter = OPENCODE_AUTH_CONTENT)') -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ }
          }
          $out = Read-Host 'Путь к zip (Enter = opencode-port-<ПК>-<дата>.zip в текущей папке)'
          if ([string]::IsNullOrWhiteSpace($out)) {
            Invoke-Export -SecretsMode $mode -EnvNames $vars | Out-Null
          } else {
            Invoke-Export -OutputPath $out -SecretsMode $mode -EnvNames $vars | Out-Null
          }
        } catch { Say "ОШИБКА: $($_.Exception.Message)" 'Red' }
      }
      '2' {
        try {
          $path = Read-Host 'Путь к zip-архиву'
          if ([string]::IsNullOrWhiteSpace($path)) { Say 'Путь не указан.' 'Red'; break }
          $setEnv = (Read-Host 'Применить переменные окружения? (y/N)') -match '^(y|д)'
          Invoke-Import -ArchivePath $path -ApplyEnv:$setEnv
        } catch { Say "ОШИБКА: $($_.Exception.Message)" 'Red' }
      }
      '3' {
        try { Invoke-Export -SecretsMode 'Auth' -DryRun | Out-Null }
        catch { Say "ОШИБКА: $($_.Exception.Message)" 'Red' }
      }
      '0' { return }
      '' { return }
      default { Say 'Нет такого пункта.' 'Red' }
    }
    if ($choice -in '1', '2', '3') {
      Say ''
      $null = Read-Host 'Enter — назад в меню'
    }
  }
}

switch ($Mode) {
  'export' {
    Invoke-Export -OutputPath $Out -SecretsMode $Secrets -EnvNames $EnvVars -HomeDir $HomeDir -DryRun:$DryRunExport | Out-Null
  }
  'import' {
    if ([string]::IsNullOrWhiteSpace($Zip)) {
      $found = Get-ChildItem -LiteralPath (Get-Location).Path -Filter 'opencode-port-*.zip' -File -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending | Select-Object -First 1 -ExpandProperty FullName
      if ([string]::IsNullOrWhiteSpace($found)) { throw 'Укажите архив: -Zip <путь>' }
      $Zip = $found
      Say "Архив по умолчанию: $Zip" 'DarkGray'
    }
    Invoke-Import -ArchivePath $Zip -HomeDir $HomeDir -ApplyEnv:$SetEnv -ForceEnv:$OverwriteEnv -DryRun:$DryRun
  }
  default { Show-Menu }
}
