<#
.SYNOPSIS
  Безопасный аддитивный перенос провайдеров, моделей, API-ключей и диалогов OpenCode между компьютерами.

.DESCRIPTION
  Экспорт: собирает конфиг opencode (opencode.json / opencode.jsonc / .opencode),
           файл ключей auth.json (папка data), выбранные переменные окружения
           (например API-ключ провайдера) и диалоги (через CLI OpenCode) в один zip.

  Импорт:  разворачивает zip на другой машине. Конфиг и auth.json сливаются
           аддитивно (локальные конфликтующие значения и настройки, не связанные
           с провайдерами, сохраняются), отсутствующие переменные окружения
           добавляются как пользовательские (если задан -SetEnv), диалоги
           переносятся через штатные CLI-команды с пропуском уже существующих ID.

  Ничего не удаляет: старые файлы и диалоги с совпадающими ID сохраняются.

.EXAMPLE
  .\opencode-port.cmd
  .\opencode-port.cmd export
  .\opencode-port.cmd export -Secrets All -Env AISTAR_API_KEY
  .\opencode-port.cmd import -Zip .\opencode-port-....zip
  .\opencode-port.cmd import -Zip .\x.zip -SetEnv -OverwriteEnv
  .\opencode-port.cmd import -Zip .\x.zip -DryRun
  .\opencode-port.cmd export -SkipSessions
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
  [switch]$SkipSessions,
  [string]$SessionDirectory = (Get-Location).Path,
  [string]$HomeDir = $env:USERPROFILE
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$script:Format = 'opencode-port'
$script:Version = 2

function Say([string]$Text, [string]$Color = 'Gray') {
  Write-Host $Text -ForegroundColor $Color
}

# Strict-mode-safe: значение свойства объекта, если свойство есть; иначе default.
function Get-Prop($Object, [string]$Name, $Default = $null) {
  if ($null -eq $Object) { return $Default }
  if ($null -ne $Object.PSObject.Properties[$Name]) { return $Object.$Name }
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

# Аддитивный вариант: при конфликте сохраняется локальное значение, а из архива
# добавляются только отсутствующие провайдеры, модели и поля их настроек.
function Merge-JsonNodeAdditive($Local, $Incoming) {
  if ($null -eq $Local) { return $Incoming }
  if ($null -eq $Incoming) { return $Local }
  if ($Local -isnot [System.Management.Automation.PSCustomObject] -or $Incoming -isnot [System.Management.Automation.PSCustomObject]) { return $Local }

  $result = [ordered]@{}
  foreach ($p in $Local.PSObject.Properties) { $result[$p.Name] = $p.Value }
  foreach ($p in $Incoming.PSObject.Properties) {
    if ($result.Contains($p.Name)) {
      $result[$p.Name] = Merge-JsonNodeAdditive $result[$p.Name] $p.Value
    } else {
      $result[$p.Name] = $p.Value
    }
  }
  [pscustomobject]$result
}

function Select-ProviderConfig($Config) {
  $result = [ordered]@{}
  foreach ($name in 'provider', 'providers') {
    $value = Get-Prop $Config $name $null
    if ($value -is [System.Management.Automation.PSCustomObject]) { $result[$name] = $value }
  }
  if ($result.Count -eq 0) { return $null }
  [pscustomobject]$result
}

function Write-JsonFile([string]$Path, $Object) {
  $json = $Object | ConvertTo-Json -Depth 100
  $utf8 = New-Object System.Text.UTF8Encoding($false)
  $temp = "$Path.$([guid]::NewGuid().ToString('N')).tmp"
  try {
    [System.IO.File]::WriteAllText($temp, $json, $utf8)
    if (Test-Path -LiteralPath $Path -PathType Leaf) {
      $replaceBackup = "$Path.$([guid]::NewGuid().ToString('N')).replace.bak"
      [System.IO.File]::Replace($temp, $Path, $replaceBackup, $true)
    } else {
      [System.IO.File]::Move($temp, $Path)
    }
  } finally {
    if (Test-Path -LiteralPath $temp -PathType Leaf) { Remove-Item -LiteralPath $temp -Force }
  }
}

function Backup-File([string]$Path) {
  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
  $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
  $guid = [guid]::NewGuid().ToString('N')
  $backup = "$Path.$stamp-$guid.bak"
  Copy-Item -LiteralPath $Path -Destination $backup
  $backup
}

function Backup-Directory([string]$Path) {
  if (-not (Test-Path -LiteralPath $Path -PathType Container)) { return $null }
  $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
  $guid = [guid]::NewGuid().ToString('N')
  $backup = "$Path.$stamp-$guid.bak"
  Copy-Item -LiteralPath $Path -Destination $backup -Recurse
  $backup
}

function Copy-DirectoryContentsAdditive([string]$Source, [string]$Destination) {
  $sourceRoot = [System.IO.Path]::GetFullPath($Source)
  if (-not (Test-Path -LiteralPath $Destination)) { New-Item -ItemType Directory -Path $Destination -Force | Out-Null }
  $added = @()
  foreach ($item in Get-ChildItem -LiteralPath $Source -Recurse -Force) {
    $relative = $item.FullName.Substring($sourceRoot.Length).TrimStart('\', '/')
    $target = Join-Path $Destination $relative
    if ($item.PSIsContainer) {
      if (-not (Test-Path -LiteralPath $target)) { New-Item -ItemType Directory -Path $target -Force | Out-Null }
      continue
    }
    if (Test-Path -LiteralPath $target) {
      Say "= .opencode\${relative}: локальный файл сохранён" 'DarkGray'
      continue
    }
    $parent = Split-Path -Parent $target
    if (-not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
    Copy-Item -LiteralPath $item.FullName -Destination $target
    $added += $relative
  }
  $added
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

function Expand-ArchiveSafe([string]$ArchivePath, [string]$Destination) {
  Add-Type -AssemblyName System.IO.Compression.FileSystem
  $archive = $null
  try {
    $archive = [System.IO.Compression.ZipFile]::OpenRead((Resolve-Path -LiteralPath $ArchivePath).Path)
    $root = [System.IO.Path]::GetFullPath($Destination).TrimEnd('\', '/') + [System.IO.Path]::DirectorySeparatorChar
    $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
    if ($archive.Entries.Count -gt 10000) { throw 'В ZIP больше 10000 элементов; распаковка отклонена.' }
    [long]$declaredTotal = 0
    foreach ($entry in $archive.Entries) {
      if ($entry.Length -gt 1GB) { throw "Элемент ZIP слишком велик: $($entry.FullName)" }
      $declaredTotal += $entry.Length
      if ($declaredTotal -gt 2GB) { throw 'Общий распакованный размер ZIP превышает 2 ГБ.' }
      if ($entry.Length -gt 10MB -and $entry.CompressedLength -gt 0 -and ($entry.Length / $entry.CompressedLength) -gt 1000) {
        throw "Подозрительная степень сжатия ZIP: $($entry.FullName)"
      }
      $name = $entry.FullName.Replace('\', '/')
      if ([string]::IsNullOrWhiteSpace($name) -or $name.StartsWith('/') -or $name -match '^[A-Za-z]:' -or $name.Contains(':')) {
        throw "Небезопасный путь в ZIP: $($entry.FullName)"
      }
      $segments = @($name -split '/')
      if ($segments -contains '..' -or $segments -contains '.') { throw "Небезопасный путь в ZIP: $($entry.FullName)" }
      $target = [System.IO.Path]::GetFullPath((Join-Path $root $name))
      if (-not $target.StartsWith($root, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "ZIP path traversal отклонён: $($entry.FullName)"
      }
      if (-not $seen.Add($target)) { throw "Повторяющийся путь в ZIP: $($entry.FullName)" }
    }
    [long]$actualTotal = 0
    foreach ($entry in $archive.Entries) {
      $target = [System.IO.Path]::GetFullPath((Join-Path $root $entry.FullName.Replace('\', '/')))
      if ($entry.FullName.EndsWith('/')) {
        New-Item -ItemType Directory -Path $target -Force | Out-Null
        continue
      }
      $parent = Split-Path -Parent $target
      if (-not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
      $input = $entry.Open()
      $output = [System.IO.File]::Create($target)
      try {
        $buffer = New-Object byte[] (1MB)
        while (($read = $input.Read($buffer, 0, $buffer.Length)) -gt 0) {
          $actualTotal += $read
          if ($actualTotal -gt 2GB) { throw 'Фактический распакованный размер ZIP превышает 2 ГБ.' }
          $output.Write($buffer, 0, $read)
        }
      } finally { $output.Dispose(); $input.Dispose() }
    }
  } finally {
    if ($null -ne $archive) { $archive.Dispose() }
  }
}

function Get-DesktopVersion {
  $exe = Join-Path $env:LOCALAPPDATA 'Programs\@opencode-aidesktop\OpenCode.exe'
  if (-not (Test-Path -LiteralPath $exe -PathType Leaf)) { return $null }
  try { return (Get-Item -LiteralPath $exe).VersionInfo.FileVersion } catch { return $null }
}

function Find-OpenCodeCli {
  if ($env:OPENCODE_PORT_CLI -and (Test-Path -LiteralPath $env:OPENCODE_PORT_CLI -PathType Leaf)) { return $env:OPENCODE_PORT_CLI }
  $command = Get-Command opencode -ErrorAction SilentlyContinue
  if ($command -and $command.Source) { return $command.Source }
  $desktop = Join-Path $env:LOCALAPPDATA 'Programs\@opencode-aidesktop\resources\opencode-cli.exe'
  if (Test-Path -LiteralPath $desktop -PathType Leaf) { return $desktop }
  throw 'Не найден opencode CLI. Установите OpenCode или задайте OPENCODE_PORT_CLI.'
}

function ConvertTo-NativeArgument([string]$Value) {
  if ($Value.Length -eq 0) { return '""' }
  if ($Value -notmatch '[\s"]') { return $Value }
  '"' + ($Value -replace '(\\+)"', '$1$1\"' -replace '(\\+)$', '$1$1' -replace '"', '\"') + '"'
}

function Invoke-OpenCodeNative {
  param(
    [string]$Cli,
    [string[]]$CliArgs,
    [string]$OutputFile,
    [string]$WorkingDirectory = (Get-Location).Path
  )
  $psi = New-Object System.Diagnostics.ProcessStartInfo
  $psi.FileName = $Cli
  $psi.Arguments = (@($CliArgs | ForEach-Object { ConvertTo-NativeArgument $_ }) -join ' ')
  $psi.WorkingDirectory = $WorkingDirectory
  $psi.UseShellExecute = $false
  $psi.RedirectStandardOutput = $true
  $psi.RedirectStandardError = $true
  $utf8 = New-Object System.Text.UTF8Encoding($false)
  $psi.StandardOutputEncoding = $utf8
  $psi.StandardErrorEncoding = $utf8
  $psi.CreateNoWindow = $true
  $process = New-Object System.Diagnostics.Process
  $process.StartInfo = $psi
  try {
    if (-not $process.Start()) { throw 'Не удалось запустить opencode CLI.' }
    $stdoutTask = $process.StandardOutput.ReadToEndAsync()
    $stderrTask = $process.StandardError.ReadToEndAsync()
    $process.WaitForExit()
    $stdout = $stdoutTask.GetAwaiter().GetResult()
    $null = $stderrTask.GetAwaiter().GetResult()
    if ($process.ExitCode -ne 0) {
      throw "opencode CLI завершился с кодом $($process.ExitCode). Подробности скрыты, чтобы не выводить секреты."
    }
    if ($OutputFile) {
      [System.IO.File]::WriteAllText($OutputFile, $stdout, (New-Object System.Text.UTF8Encoding($false)))
      return
    }
    $stdout
  } finally {
    $process.Dispose()
  }
}

function Get-OpenCodeMajor([string]$Cli) {
  $text = Invoke-OpenCodeNative -Cli $Cli -CliArgs @('--version')
  $match = [regex]::Match($text, 'v?(\d+)\.')
  if (-not $match.Success) { throw 'Не удалось определить версию opencode CLI.' }
  [int]$match.Groups[1].Value
}

function Get-OpenCodeSessions([string]$Cli, [int]$Major) {
  if ($Major -eq 1) {
    $raw = Invoke-OpenCodeNative -Cli $Cli -CliArgs @('session', 'list', '--format', 'json')
    if ([string]::IsNullOrWhiteSpace($raw)) { return @() }
    return @(($raw | ConvertFrom-Json))
  }
  $items = @()
  $cursor = $null
  $seen = New-Object 'System.Collections.Generic.HashSet[string]'
  do {
    $uri = '/api/session'
    if ($cursor) { $uri += '?cursor=' + [uri]::EscapeDataString($cursor) }
    $raw = Invoke-OpenCodeNative -Cli $Cli -CliArgs @('api', 'get', $uri, '--standalone')
    $response = $raw | ConvertFrom-Json
    $items += @(Get-Prop $response 'data' @())
    $cursorInfo = Get-Prop $response 'cursor' $null
    $next = if ($cursorInfo -is [System.Management.Automation.PSCustomObject]) { Get-Prop $cursorInfo 'next' $null } else { $cursorInfo }
    if ($next -and -not $seen.Add([string]$next)) { throw 'API /api/session вернул повторяющийся cursor.' }
    $cursor = $next
  } while ($cursor)
  $items
}

function New-EmptyTokens {
  [pscustomobject][ordered]@{ input = 0; output = 0; reasoning = 0; cache = [pscustomobject][ordered]@{ read = 0; write = 0 } }
}

function Convert-DataUriToAttachment($Part) {
  $url = [string](Get-Prop $Part 'url' '')
  $match = [regex]::Match($url, '^data:([^;,]+)?(;base64)?,(.*)$', [System.Text.RegularExpressions.RegexOptions]::Singleline)
  if (-not $match.Success -or -not $match.Groups[2].Success) {
    $external = [ordered]@{
      data = ''; mime = [string](Get-Prop $Part 'mime' 'application/octet-stream'); source = [pscustomobject][ordered]@{ type = 'uri'; uri = $url }
    }
    if (Get-Prop $Part 'filename' $null) { $external.name = $Part.filename }
    return [pscustomobject]$external
  }
  $result = [ordered]@{
    data = $match.Groups[3].Value
    mime = [string](Get-Prop $Part 'mime' $(if ($match.Groups[1].Success) { $match.Groups[1].Value } else { 'application/octet-stream' }))
    source = [pscustomobject][ordered]@{ type = 'inline' }
  }
  $filename = Get-Prop $Part 'filename' $null
  if ($filename) { $result.name = $filename }
  [pscustomobject]$result
}

function Convert-V1ToolStateToV2($State) {
  $status = [string](Get-Prop $State 'status' '')
  switch ($status) {
    'pending' { return [pscustomobject][ordered]@{ status = 'streaming'; input = [string](Get-Prop $State 'raw' '') } }
    'running' {
      return [pscustomobject][ordered]@{
        status = 'running'; input = (Get-Prop $State 'input' ([pscustomobject]@{})); metadata = (Get-Prop $State 'metadata' ([pscustomobject]@{}))
      }
    }
    'completed' {
      $content = @([pscustomobject][ordered]@{ type = 'text'; text = [string](Get-Prop $State 'output' '') })
      foreach ($attachment in @(Get-Prop $State 'attachments' @())) {
        $converted = Convert-DataUriToAttachment $attachment
        $uri = if ($converted.source.type -eq 'uri') { $converted.source.uri } else { 'data:' + $converted.mime + ';base64,' + $converted.data }
        $content += [pscustomobject][ordered]@{ type = 'file'; uri = $uri; mime = $converted.mime; name = (Get-Prop $converted 'name' $null) }
      }
      return [pscustomobject][ordered]@{ status = 'completed'; input = (Get-Prop $State 'input' ([pscustomobject]@{})); content = $content; metadata = (Get-Prop $State 'metadata' ([pscustomobject]@{})) }
    }
    'error' {
      $error = Get-Prop $State 'error' ''
      if ($error -is [string]) { $error = [pscustomobject][ordered]@{ name = 'UnknownError'; data = [pscustomobject][ordered]@{ message = $error } } }
      return [pscustomobject][ordered]@{ status = 'error'; input = (Get-Prop $State 'input' ([pscustomobject]@{})); error = $error; metadata = (Get-Prop $State 'metadata' ([pscustomobject]@{})) }
    }
    default { throw "Неизвестный статус инструмента V1: $status" }
  }
}

function Convert-V1SessionToV2($Data, [string]$Directory) {
  $source = Get-Prop $Data 'info' $null
  if ($null -eq $source) { throw 'В V1 transfer отсутствует info.' }
  $created = [double](Get-Prop (Get-Prop $source 'time' $null) 'created' ([DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()))
  $updated = [double](Get-Prop (Get-Prop $source 'time' $null) 'updated' $created)
  $info = [ordered]@{
    id = $source.id; projectID = [string](Get-Prop $source 'projectID' 'global'); cost = [double](Get-Prop $source 'cost' 0)
    tokens = (Get-Prop $source 'tokens' (New-EmptyTokens)); time = [pscustomobject][ordered]@{ created = $created; updated = $updated }
    title = [string](Get-Prop $source 'title' 'Imported session'); location = [pscustomobject][ordered]@{ directory = $Directory }
    metadata = [pscustomobject][ordered]@{ opencodePortV1 = $Data }
  }
  $parentID = Get-Prop $source 'parentID' $null
  if ($parentID) { $info.parentID = $parentID }
  $messages = @()
  foreach ($wrapper in @(Get-Prop $Data 'messages' @())) {
    $message = Get-Prop $wrapper 'info' $null
    if ($null -eq $message) { throw 'В V1 transfer сообщение без info.' }
    $parts = @(Get-Prop $wrapper 'parts' @())
    $messageCreated = [double](Get-Prop (Get-Prop $message 'time' $null) 'created' $created)
    $metadata = [pscustomobject][ordered]@{ opencodePortV1Info = $message; opencodePortV1Parts = $parts }
    if ($message.role -eq 'user') {
      $texts = @($parts | Where-Object { $_.type -eq 'text' } | ForEach-Object { $_.text })
      $files = @($parts | Where-Object { $_.type -eq 'file' } | ForEach-Object { Convert-DataUriToAttachment $_ })
      $item = [ordered]@{ id = $message.id; type = 'user'; time = [pscustomobject][ordered]@{ created = $messageCreated }; text = ($texts -join "`n"); metadata = $metadata }
      if ($files.Count) { $item.files = $files }
      $messages += [pscustomobject]$item
    } elseif ($message.role -eq 'assistant') {
      $content = @()
      foreach ($part in $parts) {
        if ($part.type -in 'text', 'reasoning') {
          $content += [pscustomobject][ordered]@{ type = $part.type; text = [string]$part.text }
        } elseif ($part.type -eq 'tool') {
          $stateTime = Get-Prop (Get-Prop $part 'state' $null) 'time' $null
          $start = [double](Get-Prop $stateTime 'start' $messageCreated)
          $end = [double](Get-Prop $stateTime 'end' $start)
          $content += [pscustomobject][ordered]@{
            type = 'tool'; id = [string]$part.callID; name = [string]$part.tool; state = (Convert-V1ToolStateToV2 $part.state)
            time = [pscustomobject][ordered]@{ created = $start; ran = $start; completed = $end }
          }
        }
      }
      $model = [ordered]@{ providerID = [string](Get-Prop $message 'providerID' 'unknown'); id = [string](Get-Prop $message 'modelID' 'unknown') }
      if (Get-Prop $message 'variant' $null) { $model.variant = $message.variant }
      $item = [ordered]@{
        id = $message.id; type = 'assistant'; agent = [string](Get-Prop $message 'agent' 'default'); model = [pscustomobject]$model
        content = $content; metadata = $metadata; cost = [double](Get-Prop $message 'cost' 0); tokens = (Get-Prop $message 'tokens' (New-EmptyTokens))
        time = [pscustomobject][ordered]@{ created = $messageCreated; completed = [double](Get-Prop (Get-Prop $message 'time' $null) 'completed' $messageCreated) }
      }
      if (Get-Prop $message 'finish' $null) { $item.finish = $message.finish }
      if (Get-Prop $message 'error' $null) { $item.error = $message.error }
      $messages += [pscustomobject]$item
    } else { throw "Неизвестная роль сообщения V1: $($message.role)" }
  }
  [pscustomobject][ordered]@{ info = [pscustomobject]$info; messages = $messages }
}

function Convert-V2ToolStateToV1($State, [string]$SessionID, [string]$MessageID, [string]$CallID) {
  $status = [string](Get-Prop $State 'status' '')
  $start = [double](Get-Prop (Get-Prop $State 'time' $null) 'start' 0)
  switch ($status) {
    'streaming' { return [pscustomobject][ordered]@{ status = 'pending'; input = [pscustomobject]@{}; raw = [string](Get-Prop $State 'input' ''); time = [pscustomobject][ordered]@{ start = $start; end = $start } } }
    'running' { return [pscustomobject][ordered]@{ status = 'running'; input = (Get-Prop $State 'input' ([pscustomobject]@{})); metadata = (Get-Prop $State 'metadata' ([pscustomobject]@{})); time = [pscustomobject][ordered]@{ start = $start } } }
    'completed' {
      $texts = @(); $attachments = @()
      foreach ($content in @(Get-Prop $State 'content' @())) {
        if ($content.type -eq 'text') { $texts += $content.text }
        elseif ($content.type -eq 'file') {
          $attachments += [pscustomobject][ordered]@{ id = "prt_$CallID$($attachments.Count)"; sessionID = $SessionID; messageID = $MessageID; type = 'file'; mime = $content.mime; filename = (Get-Prop $content 'name' $null); url = $content.uri }
        }
      }
      return [pscustomobject][ordered]@{ status = 'completed'; input = (Get-Prop $State 'input' ([pscustomobject]@{})); output = ($texts -join "`n"); title = ''; metadata = (Get-Prop $State 'metadata' ([pscustomobject]@{})); time = [pscustomobject][ordered]@{ start = $start; end = $start }; attachments = $attachments }
    }
    'error' {
      $error = Get-Prop $State 'error' 'Unknown error'
      if ($error -isnot [string]) { $error = [string](Get-Prop (Get-Prop $error 'data' $null) 'message' 'Unknown error') }
      return [pscustomobject][ordered]@{ status = 'error'; input = (Get-Prop $State 'input' ([pscustomobject]@{})); error = $error; metadata = (Get-Prop $State 'metadata' ([pscustomobject]@{})); time = [pscustomobject][ordered]@{ start = $start; end = $start } }
    }
    default { throw "Неизвестный статус инструмента V2: $status" }
  }
}

function Convert-V2SessionToV1($Data, [string]$Directory) {
  $source = Get-Prop $Data 'info' $null
  if ($null -eq $source) { throw 'В V2 transfer отсутствует info.' }
  $created = [double](Get-Prop (Get-Prop $source 'time' $null) 'created' ([DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()))
  $updated = [double](Get-Prop (Get-Prop $source 'time' $null) 'updated' $created)
  $info = [ordered]@{
    id = $source.id; projectID = [string](Get-Prop $source 'projectID' 'global'); slug = 'imported'; directory = $Directory
    title = [string](Get-Prop $source 'title' 'Imported session'); version = 'opencode-port'
    time = [pscustomobject][ordered]@{ created = $created; updated = $updated }
    metadata = [pscustomobject][ordered]@{ opencodePortV2 = $Data }
  }
  $parentID = Get-Prop $source 'parentID' $null
  if ($parentID) { $info.parentID = $parentID }
  $messages = @()
  $lastUserID = $null
  foreach ($message in @(Get-Prop $Data 'messages' @())) {
    $id = [string]$message.id
    $messageCreated = [double](Get-Prop (Get-Prop $message 'time' $null) 'created' $created)
    $parts = @()
    $role = if ($message.type -eq 'assistant') { 'assistant' } else { 'user' }
    if ($message.type -eq 'user') {
      if ($message.text) { $parts += [pscustomobject][ordered]@{ id = "prt_$($id)_text"; sessionID = $source.id; messageID = $id; type = 'text'; text = $message.text } }
      $index = 0
      foreach ($file in @(Get-Prop $message 'files' @())) {
        $fileSource = Get-Prop $file 'source' $null
        $url = if ((Get-Prop $fileSource 'type' '') -eq 'uri') { [string](Get-Prop $fileSource 'uri' '') } else { 'data:' + $file.mime + ';base64,' + [string](Get-Prop $file 'data' '') }
        if (-not $url) { throw 'Во вложении V2 отсутствуют данные и URI.' }
        $parts += [pscustomobject][ordered]@{ id = "prt_$($id)_file$index"; sessionID = $source.id; messageID = $id; type = 'file'; mime = $file.mime; filename = (Get-Prop $file 'name' $null); url = $url }
        $index++
      }
    } elseif ($message.type -eq 'assistant') {
      $index = 0
      foreach ($content in @(Get-Prop $message 'content' @())) {
        $partID = "prt_$($id)_$index"
        if ($content.type -in 'text', 'reasoning') {
          $part = [ordered]@{ id = $partID; sessionID = $source.id; messageID = $id; type = $content.type; text = $content.text }
          if ($content.type -eq 'reasoning') { $part.time = [pscustomobject][ordered]@{ start = $messageCreated; end = $messageCreated } }
          $parts += [pscustomobject]$part
        } elseif ($content.type -eq 'tool') {
          $start = [double](Get-Prop (Get-Prop $content 'time' $null) 'created' $messageCreated)
          $state = Convert-V2ToolStateToV1 $content.state $source.id $id $content.id
          $state.time = [pscustomobject][ordered]@{ start = $start; end = [double](Get-Prop (Get-Prop $content 'time' $null) 'completed' $start) }
          $parts += [pscustomobject][ordered]@{ id = $partID; sessionID = $source.id; messageID = $id; type = 'tool'; callID = $content.id; tool = $content.name; state = $state }
        }
        $index++
      }
    } else {
      $raw = $message | ConvertTo-Json -Depth 100 -Compress
      $parts += [pscustomobject][ordered]@{ id = "prt_$($id)_raw"; sessionID = $source.id; messageID = $id; type = 'text'; synthetic = $true; text = $raw }
    }
    if ($role -eq 'user') {
      $messageInfo = [pscustomobject][ordered]@{
        id = $id; sessionID = $source.id; role = 'user'; time = [pscustomobject][ordered]@{ created = $messageCreated }
        agent = 'default'; model = [pscustomobject][ordered]@{ providerID = 'unknown'; modelID = 'unknown' }
      }
      $lastUserID = $id
    } else {
      $model = Get-Prop $message 'model' $null
      $messageInfo = [ordered]@{
        id = $id; sessionID = $source.id; role = 'assistant'; parentID = $(if ($lastUserID) { $lastUserID } else { $id })
        time = [pscustomobject][ordered]@{ created = $messageCreated; completed = [double](Get-Prop (Get-Prop $message 'time' $null) 'completed' $messageCreated) }
        providerID = [string](Get-Prop $model 'providerID' 'unknown'); modelID = [string](Get-Prop $model 'id' 'unknown')
        mode = [string](Get-Prop $message 'agent' 'default'); agent = [string](Get-Prop $message 'agent' 'default')
        path = [pscustomobject][ordered]@{ cwd = $Directory; root = $Directory }; cost = [double](Get-Prop $message 'cost' 0); tokens = (Get-Prop $message 'tokens' (New-EmptyTokens))
      }
      if (Get-Prop $model 'variant' $null) { $messageInfo.variant = $model.variant }
      if (Get-Prop $message 'finish' $null) { $messageInfo.finish = $message.finish }
      if (Get-Prop $message 'error' $null) { $messageInfo.error = $message.error }
      $messageInfo = [pscustomobject]$messageInfo
    }
    $messages += [pscustomobject][ordered]@{ info = $messageInfo; parts = $parts }
  }
  [pscustomobject][ordered]@{ info = [pscustomobject]$info; messages = $messages }
}

function Backup-SessionStorage([string]$Cli, [int]$Major, $Paths) {
  $database = $null
  try {
    $debugArgs = @('debug', 'paths', 'db')
    if ($Major -eq 2) { $debugArgs += '--standalone' }
    $database = (Invoke-OpenCodeNative -Cli $Cli -CliArgs $debugArgs).Trim()
  } catch { }
  if (-not $database) { $database = Join-Path $Paths.DataDir 'opencode.db' }
  foreach ($suffix in @('', '-wal', '-shm')) {
    $file = $database + $suffix
    if (Test-Path -LiteralPath $file -PathType Leaf) { Backup-File $file | Out-Null }
  }
  $legacy = Join-Path $Paths.DataDir 'storage'
  if (Test-Path -LiteralPath $legacy -PathType Container) { Backup-Directory $legacy | Out-Null }
}

function Invoke-Export {
  param(
    [string]$OutputPath,
    [string]$SecretsMode = 'Auth',
    [string[]]$EnvNames = @(),
    [string]$HomeDir = $env:USERPROFILE,
    [switch]$SkipSessions,
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
    foreach ($name in 'provider', 'providers') {
      $prov = Get-Prop $parsed.Data $name $null
      if ($prov -is [System.Management.Automation.PSCustomObject]) { $providers += $prov }
    }
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

    $sessionManifest = [pscustomobject][ordered]@{ sourceMajor = $null; count = 0; files = @() }
    if (-not $SkipSessions) {
      $cli = Find-OpenCodeCli
      $major = Get-OpenCodeMajor $cli
      $sessions = @(Get-OpenCodeSessions $cli $major)
      $sessionRoot = Join-Path $filesRoot 'sessions'
      New-Item -ItemType Directory -Path $sessionRoot -Force | Out-Null
      $files = @()
      $ids = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::Ordinal)
      foreach ($session in $sessions) {
        $id = [string](Get-Prop $session 'id' '')
        if ($id -notmatch '^ses_[A-Za-z0-9_-]+$') { throw "CLI вернул некорректный session ID." }
        if (-not $ids.Add($id)) { continue }
        $destination = Join-Path $sessionRoot "$id.json"
        $cliArgs = if ($major -eq 1) { @('export', $id) } else { @('session', 'export', $id, '--standalone') }
        Invoke-OpenCodeNative -Cli $cli -CliArgs $cliArgs -OutputFile $destination
        $check = Read-JsonFile $destination
        if (-not $check.Ok -or [string](Get-Prop (Get-Prop $check.Data 'info' $null) 'id' '') -ne $id) {
          throw "Экспорт диалога $id вернул повреждённый JSON."
        }
        $files += "$id.json"
      }
      $sessionManifest = [pscustomobject][ordered]@{ sourceMajor = $major; count = $files.Count; files = $files }
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
      sessions       = $sessionManifest
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
  return [bool](Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.ProcessName -like 'opencode*' })
}

function Invoke-Import {
  param(
    [string]$ArchivePath,
    [string]$HomeDir = $env:USERPROFILE,
    [switch]$ApplyEnv,
    [switch]$ForceEnv,
    [string]$SessionDirectory = (Get-Location).Path,
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
    Expand-ArchiveSafe -ArchivePath $ArchivePath -Destination $staging
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

    # Все входные JSON проверяются до первого изменения целевой машины.
    $archiveAuth = Join-Path $root 'data\auth.json'
    $authMerged = $null
    $authIncomingNames = @()
    if (Test-Path -LiteralPath $archiveAuth -PathType Leaf) {
      $incomingAuth = Read-JsonFile $archiveAuth
      if (-not $incomingAuth.Ok -or $incomingAuth.Data -isnot [System.Management.Automation.PSCustomObject]) { throw 'data\auth.json в архиве повреждён или имеет неверный формат.' }
      $authMerged = [ordered]@{}
      if (Test-Path -LiteralPath $paths.AuthFile -PathType Leaf) {
        $currentAuth = Read-JsonFile $paths.AuthFile
        if (-not $currentAuth.Ok -or $currentAuth.Data -isnot [System.Management.Automation.PSCustomObject]) { throw "Локальный auth.json повреждён: $(Get-Prop $currentAuth 'Error' 'неверный формат'). Импорт остановлен." }
        foreach ($p in $currentAuth.Data.PSObject.Properties) { $authMerged[$p.Name] = $p.Value }
      }
      foreach ($p in $incomingAuth.Data.PSObject.Properties) {
        if (-not $authMerged.Contains($p.Name)) { $authMerged[$p.Name] = $p.Value }
        $authIncomingNames += $p.Name
      }
    }

    $envVars = @()
    $envFile = Join-Path $root 'env\env.json'
    if (Test-Path -LiteralPath $envFile -PathType Leaf) {
      $envData = Read-JsonFile $envFile
      if (-not $envData.Ok -or $envData.Data -isnot [System.Management.Automation.PSCustomObject]) { throw "env\env.json в архиве повреждён или имеет неверный формат: $(Get-Prop $envData 'Error' 'неверный формат')" }
      $envVars = @(Get-Prop $envData.Data 'vars' @())
      foreach ($v in $envVars) {
        $vname = [string](Get-Prop $v 'name' '')
        $vvalue = Get-Prop $v 'value' $null
        if ($vname -notmatch '^[A-Za-z_][A-Za-z0-9_]*$' -or ($null -ne $vvalue -and $vvalue -isnot [string])) {
          throw 'env\env.json содержит некорректное имя или нестроковое значение переменной.'
        }
        if ($vname -in 'Path', 'PATHEXT', 'COMSPEC', 'NODE_OPTIONS', 'PYTHONPATH', 'PYTHONHOME', 'LD_PRELOAD') {
          throw "Переменная $vname не разрешена для импорта из архива."
        }
      }
    }

    $sessionMeta = Get-Prop $meta 'sessions' $null
    $sessionFiles = @(Get-Prop $sessionMeta 'files' @())
    $pendingSessions = @()
    $targetCli = $null
    $targetMajor = $null
    if ($sessionFiles.Count -gt 0) {
      $sourceMajor = [int](Get-Prop $sessionMeta 'sourceMajor' 0)
      if ($sourceMajor -notin 1, 2) { throw 'manifest.sessions.sourceMajor отсутствует или не поддерживается.' }
      $targetCli = Find-OpenCodeCli
      $targetMajor = Get-OpenCodeMajor $targetCli
      $existingIDs = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::Ordinal)
      foreach ($item in @(Get-OpenCodeSessions $targetCli $targetMajor)) { [void]$existingIDs.Add([string]$item.id) }
      $archiveIDs = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::Ordinal)
      $candidates = @()
      foreach ($name in $sessionFiles) {
        if ([IO.Path]::GetFileName([string]$name) -ne [string]$name -or [string]$name -notmatch '^ses_[A-Za-z0-9_-]+\.json$') {
          throw "Небезопасное имя файла диалога: $name"
        }
        $file = Join-Path (Join-Path $root 'sessions') $name
        $parsed = Read-JsonFile $file
        if (-not $parsed.Ok) { throw "Диалог $name повреждён: $($parsed.Error)" }
        $data = $parsed.Data
        $info = Get-Prop $data 'info' $null
        $id = [string](Get-Prop $info 'id' '')
        if ($id + '.json' -ne $name -or -not $archiveIDs.Add($id)) { throw "Некорректный или повторяющийся диалог: $name" }
        if ($existingIDs.Contains($id)) {
          Say "= ${id}: уже существует, локальный диалог сохранён" 'DarkGray'
          continue
        }
        if ($sourceMajor -ne $targetMajor) {
          if ($sourceMajor -eq 1 -and $targetMajor -eq 2) { $data = Convert-V1SessionToV2 $data $SessionDirectory }
          elseif ($sourceMajor -eq 2 -and $targetMajor -eq 1) { $data = Convert-V2SessionToV1 $data $SessionDirectory }
          else { throw "Перенос диалогов V$sourceMajor -> V$targetMajor не поддерживается." }
          $convertedRoot = Join-Path $staging 'converted-sessions'
          New-Item -ItemType Directory -Path $convertedRoot -Force | Out-Null
          $file = Join-Path $convertedRoot $name
          Write-JsonFile $file $data
        }
        $candidates += [pscustomobject]@{ ID = $id; ParentID = [string](Get-Prop $info 'parentID' ''); File = $file }
      }
      while ($candidates.Count -gt 0) {
        $addedIDs = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::Ordinal)
        foreach ($item in $pendingSessions) { [void]$addedIDs.Add($item.ID) }
        $next = $candidates | Where-Object {
          -not $_.ParentID -or $existingIDs.Contains($_.ParentID) -or $addedIDs.Contains($_.ParentID)
        } | Select-Object -First 1
        if ($null -eq $next) { throw 'Не удалось упорядочить диалоги: отсутствует родительская сессия.' }
        $pendingSessions += $next
        $candidates = @($candidates | Where-Object { $_.ID -ne $next.ID })
      }
    }

    $archiveConfigDir = Join-Path $root 'config'
    $changes = @()
    if ($pendingSessions.Count -and -not $DryRun) { Backup-SessionStorage $targetCli $targetMajor $paths }

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
        if (-not $parsed.Ok) { throw "$name в архиве повреждён: $($parsed.Error)" }
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
        if (-not $parsed.Ok) { throw "Локальный $name повреждён: $($parsed.Error). Импорт остановлен, файл не изменён." }
        if ($null -ne $parsed.Data) {
          $base = Merge-JsonNode $base $parsed.Data
          $baseSources += $name
        }
      }

      $overlay = Select-ProviderConfig $overlay
      if ($overlay) {
        # Результат пишем в файл с наивысшим приоритетом, иначе старый файл
        # затенит добавленные ключи. Локальные конфликтующие значения сохраняем.
        $targetName = 'opencode.json'
        if (Test-Path -LiteralPath (Join-Path $paths.ConfigDir 'opencode.jsonc') -PathType Leaf) {
          $targetName = 'opencode.jsonc'
        }
        $targetPath = Join-Path $paths.ConfigDir $targetName

        $merged = Merge-JsonNodeAdditive $base $overlay
        $desc = "providers merge -> $targetName"
        if ($baseSources.Count) { $desc += " (локальные: $($baseSources -join ' + '))" }
        $desc += "; архив: $($overlaySources -join ' + ')"
        $changes += $desc
        Say "> Слияние провайдеров: $desc" 'Cyan'
        if ($targetName -eq 'opencode.jsonc') {
          Say '  (локальные комментарии в opencode.jsonc не сохраняются; оригинал — в .bak)' 'DarkGray'
        }
        if (-not $DryRun) {
          Backup-File $targetPath | Out-Null
          Write-JsonFile $targetPath $merged
        }
      }

      $archiveLocal = Join-Path $archiveConfigDir '.opencode'
      if (Test-Path -LiteralPath $archiveLocal -PathType Container) {
        $targetLocal = Join-Path $paths.ConfigDir '.opencode'
        $names = @(Get-ChildItem -LiteralPath $archiveLocal -Force | ForEach-Object { $_.Name })
        $changes += "copy .opencode ($($names -join ', '))"
        Say "> .opencode: $($names -join ', ')" 'Cyan'
        if (-not $DryRun) {
          Backup-Directory $targetLocal | Out-Null
          Copy-DirectoryContentsAdditive $archiveLocal $targetLocal | Out-Null
        }
      }
    }

    if ($null -ne $authMerged) {
      $changes += "auth.json += $($authIncomingNames -join ', ')"
      Say "> auth.json: провайдеры $($authIncomingNames -join ', ')" 'Cyan'
      if (-not $DryRun) {
        if (-not (Test-Path -LiteralPath $paths.DataDir)) { New-Item -ItemType Directory -Path $paths.DataDir -Force | Out-Null }
        Backup-File $paths.AuthFile | Out-Null
        Write-JsonFile $paths.AuthFile ([pscustomobject]$authMerged)
        # Права: только текущий пользователь.
        $icaclsOk = $false
        try {
          $null = icacls $paths.AuthFile /inheritance:r /grant:r "$($env:USERNAME):(F)" 2>&1
          $icaclsOk = ($LASTEXITCODE -eq 0)
        } catch { }
        if (-not $icaclsOk) { Say '! Не удалось ограничить права на auth.json (не критично).' 'Yellow' }
      }
    }

    if ($envVars.Count -gt 0) {
      foreach ($v in $envVars) {
        $vname = Get-Prop $v 'name' $null
        $vvalue = Get-Prop $v 'value' $null
        if ($null -eq $vvalue) { continue }

        $current = Get-EnvPath $vname
        if ((-not [string]::IsNullOrEmpty($current.Value)) -and -not $ForceEnv) {
          Say "= ${vname}: уже задана, оставлена текущая (используйте -OverwriteEnv)" 'DarkGray'
          continue
        }
        $changes += "env $vname"
        Say "> env $vname" 'Cyan'
        if (-not $DryRun -and $ApplyEnv) {
          # Архив не управляет областью записи и окружением последующего CLI.
          [Environment]::SetEnvironmentVariable($vname, $vvalue, 'User')
          Say '  записано в область: User (запущенные приложения увидят после перезапуска)' 'DarkGray'
        }
      }
      if (-not $ApplyEnv -and -not $DryRun) {
        Say '  (переменные не применены: добавьте -SetEnv)' 'Yellow'
      }
    }

    foreach ($session in $pendingSessions) {
      $changes += "session += $($session.ID)"
      Say "> Диалог: $($session.ID)" 'Cyan'
      if (-not $DryRun) {
        if (-not (Test-Path -LiteralPath $SessionDirectory -PathType Container)) {
          New-Item -ItemType Directory -Path $SessionDirectory -Force | Out-Null
        }
        $cliArgs = if ($targetMajor -eq 1) { @('import', $session.File) } else { @('session', 'import', $session.File, '--directory', $SessionDirectory, '--standalone') }
        Invoke-OpenCodeNative -Cli $targetCli -CliArgs $cliArgs
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
    Invoke-Export -OutputPath $Out -SecretsMode $Secrets -EnvNames $EnvVars -HomeDir $HomeDir -SkipSessions:$SkipSessions -DryRun:$DryRunExport | Out-Null
  }
  'import' {
    if ([string]::IsNullOrWhiteSpace($Zip)) {
      $found = Get-ChildItem -LiteralPath (Get-Location).Path -Filter 'opencode-port-*.zip' -File -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending | Select-Object -First 1 -ExpandProperty FullName
      if ([string]::IsNullOrWhiteSpace($found)) { throw 'Укажите архив: -Zip <путь>' }
      $Zip = $found
      Say "Архив по умолчанию: $Zip" 'DarkGray'
    }
    Invoke-Import -ArchivePath $Zip -HomeDir $HomeDir -ApplyEnv:$SetEnv -ForceEnv:$OverwriteEnv -SessionDirectory $SessionDirectory -DryRun:$DryRun
  }
  default { Show-Menu }
}
