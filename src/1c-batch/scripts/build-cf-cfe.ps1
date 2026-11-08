<#
.SYNOPSIS
    Собирает CF или CFE из полной XML-выгрузки 1С во временной файловой базе.
.DESCRIPTION
    Требуется Windows PowerShell 5.1+ и установленный Конфигуратор 1С (1cv8.exe).
    Исходники и существующие информационные базы не изменяются.
    Существующий файл не перезаписывается без параметра -Force.
    Вид артефакта определяется по Configuration.xml: расширение даёт .cfe, иначе .cf.
.EXAMPLE
    .\build-cf-cfe.ps1 -XmlDir 'C:\repo\ut\src\cf' -OutFile 'C:\build\ut.cf'
.EXAMPLE
    .\build-cf-cfe.ps1 -XmlDir 'C:\repo\ut\src\cfe_НЭПТ' -OutFile 'C:\build\nept.cfe'
.EXAMPLE
    .\build-cf-cfe.ps1 -XmlDir 'C:\repo\ut\src\cf' -OutCf 'C:\build\ut.cf' `
        -V8Path 'C:\Program Files\1cv8\<версия>\bin\1cv8.exe' -KeepBase
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$XmlDir,

    [Parameter(Mandatory = $true)]
    [Alias('OutCf', 'OutCfe')]
    [ValidateNotNullOrEmpty()]
    [string]$OutFile,

    [string]$V8Path,

    [string]$Extension,

    [switch]$Force,
    [switch]$KeepBase
)

$ErrorActionPreference = 'Stop'

function Find-V8 {
    param([string]$ExplicitPath)

    if ($ExplicitPath) { return [IO.Path]::GetFullPath($ExplicitPath) }
    if ($env:V8_PATH) {
        $fromEnv = $env:V8_PATH
        if (Test-Path -LiteralPath $fromEnv -PathType Container) {
            $fromEnv = Join-Path $fromEnv '1cv8.exe'
        }
        return [IO.Path]::GetFullPath($fromEnv)
    }

    $candidates = @()
    foreach ($programDir in @($env:ProgramFiles, ${env:ProgramFiles(x86)})) {
        if (-not $programDir) { continue }
        $root = Join-Path $programDir '1cv8'
        if (-not (Test-Path -LiteralPath $root -PathType Container)) { continue }

        foreach ($dir in (Get-ChildItem -LiteralPath $root -Directory)) {
            if ($dir.Name -notmatch '^\d+\.\d+\.\d+\.\d+$') { continue }
            $exe = Join-Path $dir.FullName 'bin\1cv8.exe'
            if (Test-Path -LiteralPath $exe -PathType Leaf) {
                $candidates += [pscustomobject]@{
                    Version = [version]$dir.Name
                    Path = $exe
                }
            }
        }
    }
    if ($candidates.Count -eq 0) {
        throw '1cv8.exe не найден. Укажите -V8Path или V8_PATH (EXE либо каталог bin).'
    }
    return ($candidates | Sort-Object Version -Descending | Select-Object -First 1).Path
}

function Read-SourceMetadata {
    param([string]$ConfigFile)

    $settings = New-Object System.Xml.XmlReaderSettings
    $settings.DtdProcessing = [System.Xml.DtdProcessing]::Prohibit
    $settings.XmlResolver = $null
    $reader = [System.Xml.XmlReader]::Create($ConfigFile, $settings)
    $formatVersion = $null
    $extension = $false
    $name = $null
    $inConfiguration = $false
    $inProperties = $false
    try {
        while ($reader.Read()) {
            if ($reader.NodeType -eq [System.Xml.XmlNodeType]::EndElement) {
                if ($reader.LocalName -eq 'Properties') { $inProperties = $false }
                if ($reader.LocalName -eq 'Configuration') { $inConfiguration = $false }
                continue
            }
            if ($reader.NodeType -ne [System.Xml.XmlNodeType]::Element) { continue }
            if (-not $formatVersion -and $reader.LocalName -eq 'MetaDataObject') {
                $formatVersion = $reader.GetAttribute('version')
            }
            if ($reader.LocalName -eq 'Configuration' -and -not $reader.IsEmptyElement) {
                $inConfiguration = $true
            }
            if ($inConfiguration -and $reader.LocalName -eq 'Properties' -and -not $reader.IsEmptyElement) {
                $inProperties = $true
            }
            if ($inProperties -and $reader.LocalName -eq 'Name' -and -not $name) {
                $name = $reader.ReadElementContentAsString()
                continue
            }
            if ($reader.LocalName -eq 'ConfigurationExtensionPurpose') {
                $extension = $true
            }
        }
    }
    finally {
        $reader.Dispose()
    }
    if (-not $formatVersion) {
        throw "Не обнаружена версия формата XML в корне: $ConfigFile"
    }
    if (-not $name) {
        throw "Не обнаружено имя конфигурации или расширения в Properties/Name: $ConfigFile"
    }
    return [pscustomobject]@{
        Format = $formatVersion
        IsExtension = $extension
        Name = $name
    }
}

function Check-PlatformFormat {
    param([string]$Executable, [string]$SourceFormat)

    $versionDir = Split-Path (Split-Path $Executable -Parent) -Leaf
    $parsed = $null
    if (-not [version]::TryParse($versionDir, [ref]$parsed)) { return }

    $supportedFormat = $null
    if ($parsed.Major -eq 8 -and $parsed.Minor -eq 3 -and
        $parsed.Build -ge 20 -and $parsed.Build -le 27) {
        $supportedFormat = [version]("2." + ($parsed.Build - 7))
    }
    elseif ($parsed.Major -eq 8 -and $parsed.Minor -eq 5 -and $parsed.Build -ge 1) {
        $supportedFormat = [version]'2.21'
    }

    $actual = $null
    if ($supportedFormat -and [version]::TryParse($SourceFormat, [ref]$actual) -and
        $actual -gt $supportedFormat) {
        throw "Формат XML $SourceFormat новее известного формата $supportedFormat для платформы $versionDir. " +
            'Укажите более новую платформу через -V8Path.'
    }
}

function Invoke-Designer {
    param(
        [string]$Step,
        [string[]]$Arguments,
        [string]$LogFile,
        [string]$ResultFile
    )

    $allArgs = @($Arguments) + @(
        '/Out', "`"$LogFile`"",
        '/DumpResult', "`"$ResultFile`""
    )

    $process = Start-Process -FilePath $script:V8 -ArgumentList $allArgs `
        -Wait -PassThru -NoNewWindow

    $logText = ''
    if (Test-Path -LiteralPath $LogFile -PathType Leaf) {
        $logText = Get-Content -LiteralPath $LogFile -Raw -Encoding UTF8
    }

    $batchResult = $null
    if (Test-Path -LiteralPath $ResultFile -PathType Leaf) {
        $batchResult = (Get-Content -LiteralPath $ResultFile -Raw).Trim().Trim([char]0xFEFF)
    }

    $logForDisplay = $logText.Trim()
    if ($logForDisplay.Length -gt 16000) {
        $logForDisplay = '[Показаны последние 16000 символов лога] ' +
            $logForDisplay.Substring($logForDisplay.Length - 16000)
    }

    if ($process.ExitCode -ne 0 -or $batchResult -ne '0') {
        Write-Host "--- Лог 1С: $Step ---"
        if ($logForDisplay) { Write-Host $logForDisplay }
        else { Write-Host '(Лог пуст или отсутствует)' }
        throw "Ошибка шага '$Step': код процесса = $($process.ExitCode), /DumpResult = '$batchResult'. " +
            "Лог: $LogFile"
    }
    if ($logForDisplay) { Write-Host $logForDisplay }
}

function Move-BuiltArtifact {
    param([string]$StagePath, [string]$OutputPath, [switch]$AllowReplace)

    if (Test-Path -LiteralPath $OutputPath -PathType Leaf) {
        if (-not $AllowReplace) {
            throw "Во время сборки по пути '$OutputPath' появился файл. Без -Force перезапись запрещена."
        }
        [IO.File]::Replace($StagePath, $OutputPath, $null)
    }
    else {
        [IO.File]::Move($StagePath, $OutputPath)
    }
}

$source = (Resolve-Path -LiteralPath $XmlDir -ErrorAction Stop).ProviderPath
if (-not (Test-Path -LiteralPath $source -PathType Container)) {
    throw "Ожидался каталог XML-выгрузки: $source"
}
$configXml = Join-Path $source 'Configuration.xml'
if (-not (Test-Path -LiteralPath $configXml -PathType Leaf)) {
    throw "В каталоге '$source' нет Configuration.xml. Нужна полная XML-выгрузка 1С."
}

$meta = Read-SourceMetadata -ConfigFile $configXml
$kind = if ($meta.IsExtension) { 'cfe' } else { 'cf' }
$artifactLabel = if ($kind -eq 'cfe') { 'расширения' } else { 'конфигурации' }
$expectedExt = ".$kind"

Write-Host "Формат исходников: $($meta.Format)"
Write-Host "Объект: $($meta.Name) ($kind)"

if ($Extension) {
    if (-not $meta.IsExtension) {
        throw 'Параметр -Extension задан, но в XML нет расширения (нет ConfigurationExtensionPurpose).'
    }
    if ($Extension -ne $meta.Name) {
        throw "Имя расширения '-Extension $Extension' не совпадает с Properties/Name '$($meta.Name)' в XML."
    }
}

$extensionName = $null
if ($meta.IsExtension) {
    $extensionName = $meta.Name
}

$output = [IO.Path]::GetFullPath($OutFile)
$outputExt = [IO.Path]::GetExtension($output)
if (-not $outputExt) {
    $output = $output + $expectedExt
    $outputExt = $expectedExt
}
if ($outputExt -ine $expectedExt) {
    throw "XML — это $artifactLabel, выходной файл должен иметь расширение $expectedExt, а не '$outputExt': $output"
}
if ((Test-Path -LiteralPath $output) -and -not $Force) {
    throw "Файл '$output' уже существует. Выберите другой путь или явно укажите -Force."
}
if ((Test-Path -LiteralPath $output -PathType Container)) {
    throw "Путь для артефакта занят каталогом: $output"
}

$script:V8 = Find-V8 -ExplicitPath $V8Path
if (-not (Test-Path -LiteralPath $script:V8 -PathType Leaf)) {
    throw "Не найден исполняемый файл 1С: $script:V8"
}
if ([IO.Path]::GetFileName($script:V8) -ine '1cv8.exe') {
    throw "Ожидался исполняемый файл 1cv8.exe: $script:V8"
}
Check-PlatformFormat -Executable $script:V8 -SourceFormat $meta.Format
Write-Host "Платформа: $script:V8"

$outDir = Split-Path $output -Parent
if (-not (Test-Path -LiteralPath $outDir)) {
    New-Item -ItemType Directory -Path $outDir -Force | Out-Null
}

$work = Join-Path ([IO.Path]::GetTempPath()) ('cfg-build-' + [guid]::NewGuid().ToString('N'))
$base = Join-Path $work 'base'
$stage = Join-Path $outDir ('.cfg-build-' + [guid]::NewGuid().ToString('N') + $expectedExt)
$succeeded = $false
New-Item -ItemType Directory -Path $base -Force | Out-Null

try {
    Write-Host '[1/3] Создание временной файловой базы...'
    Invoke-Designer -Step 'создание базы' `
        -Arguments @('CREATEINFOBASE', "File=`"$base`"") `
        -LogFile (Join-Path $work 'create.log') `
        -ResultFile (Join-Path $work 'create.result')

    $loadArgs = @(
        'DESIGNER', '/F', "`"$base`"",
        '/DisableStartupDialogs', '/DisableStartupMessages',
        '/LoadConfigFromFiles', "`"$source`""
    )
    if ($extensionName) {
        $loadArgs += @('-Extension', $extensionName)
    }

    Write-Host "[2/3] Загрузка XML $artifactLabel в конфигуратор..."
    Invoke-Designer -Step 'загрузка XML' -Arguments $loadArgs `
        -LogFile (Join-Path $work 'load.log') `
        -ResultFile (Join-Path $work 'load.result')

    $dumpArgs = @(
        'DESIGNER', '/F', "`"$base`"",
        '/DisableStartupDialogs', '/DisableStartupMessages',
        '/DumpCfg', "`"$stage`""
    )
    if ($extensionName) {
        $dumpArgs += @('-Extension', $extensionName)
    }

    Write-Host "[3/3] Сохранение $artifactLabel в $expectedExt..."
    Invoke-Designer -Step "выгрузка $kind" -Arguments $dumpArgs `
        -LogFile (Join-Path $work 'dump.log') `
        -ResultFile (Join-Path $work 'dump.result')

    if (-not (Test-Path -LiteralPath $stage -PathType Leaf) -or
        (Get-Item -LiteralPath $stage).Length -eq 0) {
        throw "Платформа не сформировала непустой ${kind}: $stage"
    }

    Move-BuiltArtifact -StagePath $stage -OutputPath $output -AllowReplace:$Force

    $bytes = (Get-Item -LiteralPath $output).Length
    Write-Host ("Готово: {0} ({1:N2} МБ; {2} байт)" -f $output, ($bytes / 1MB), $bytes)
    $succeeded = $true
}
finally {
    if (Test-Path -LiteralPath $stage -PathType Leaf) {
        Remove-Item -LiteralPath $stage -Force -ErrorAction SilentlyContinue
    }
    if ($KeepBase -or -not $succeeded) {
        Write-Host "Временная база и диагностические логи: $work"
    }
    else {
        Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
    }
}
