param(
    [switch]$Execute
)

$ErrorActionPreference = 'Stop'

function Invoke-Git {
    & git @args
    if ($LASTEXITCODE -ne 0) {
        throw "Git command failed: git $($args -join ' ')"
    }
}

function Get-Version {
    param([string]$Name)
    $match = [regex]::Match($Name, '_v(?<version>\d+\.\d+)')
    if ($match.Success) {
        return $match.Groups['version'].Value
    }
    return $null
}

function Remove-VersionMarker {
    param([string]$BaseName)
    return ($BaseName -replace '_v\d+\.\d+', '')
}

function Get-CanonicalRelativePath {
    param([string]$RelativePath)

    $directory = Split-Path -Parent $RelativePath
    $baseName = [System.IO.Path]::GetFileNameWithoutExtension($RelativePath)
    $cleanName = Remove-VersionMarker $baseName

    if ($directory -match '(^|\\)01_合稿$' -and $cleanName -notmatch '^README') {
        if ($RelativePath -match '01_第一册_大唐开国') {
            return '01_第一册_大唐开国\01_合稿\唐朝那些事儿_第一册_大唐开国.md'
        }
        if ($RelativePath -match '02_第二册_贞观君臣') {
            return '02_第二册_贞观君臣\01_合稿\唐朝那些事儿_第二册_贞观君臣.md'
        }
        if ($RelativePath -match '03_第三册_武后的天下') {
            return '03_第三册_武后的天下\01_合稿\唐朝那些事儿_第三册_武后的天下.md'
        }
    }

    if ($directory -match '旧_合稿$' -and $cleanName -notmatch '^README') {
        return '03_第三册_武后的天下\05_旧结构素材_649-683\旧_合稿\唐朝那些事儿_第三册_高宗与武后.md'
    }

    $chapterDraft = [regex]::Match(
        $cleanName,
        '^(?<chapter>第\d+章)_(?:重构初稿|初稿|故事化试改|故事化修订稿|扩写稿|深度扩写稿|总纲重写稿|总纲节奏修订稿)_(?<title>.+)$'
    )
    if ($chapterDraft.Success -and $directory -match '章节稿件$') {
        return Join-Path $directory "$($chapterDraft.Groups['chapter'].Value)_$($chapterDraft.Groups['title'].Value).md"
    }

    $revisedDraft = [regex]::Match(
        $cleanName,
        '^(?<chapter>第\d+章)_修订稿_(?<title>.+)$'
    )
    if ($revisedDraft.Success -and $directory -match '审校修订$') {
        $draftDirectory = $directory -replace '04_审校修订$', '02_章节稿件'
        if ($directory -match '旧_审校修订$') {
            $draftDirectory = $directory -replace '旧_审校修订$', '旧_章节稿件'
        }
        return Join-Path $draftDirectory "$($revisedDraft.Groups['chapter'].Value)_$($revisedDraft.Groups['title'].Value).md"
    }

    if ($directory -match '研究卡$') {
        $cleanName = $cleanName -replace '^(第\d+章)研究卡_', '$1_研究卡_'
        return Join-Path $directory "$cleanName.md"
    }

    if ($directory -match '审校修订$') {
        $singleReview = [regex]::Match(
            $cleanName,
            '^(?<chapter>第\d+章)_(?:总编辑_审稿意见|初稿_审校记录|总纲重写审读记录|精修说明|重构初稿自检)$'
        )
        if ($singleReview.Success) {
            return Join-Path $directory "$($singleReview.Groups['chapter'].Value)_审读记录.md"
        }
    }

    return Join-Path $directory "$cleanName.md"
}

function Get-SourcePriority {
    param([string]$Name)
    switch -Regex ($Name) {
        '合稿目录' { return 5 }
        '_初稿_' { return 10 }
        '_重构初稿_' { return 15 }
        '故事化试改' { return 20 }
        '故事化修订稿' { return 30 }
        '_修订稿_' { return 40 }
        '扩写稿' { return 50 }
        '深度扩写稿' { return 60 }
        '连续阅读合稿' { return 70 }
        '统一精修' { return 80 }
        '精修候选稿' { return 90 }
        '总纲节奏修订稿|总纲重写稿|总纲重写合稿' { return 100 }
        default { return 50 }
    }
}

$projectRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
if ((Split-Path $projectRoot -Leaf) -ne '唐朝那些事儿') {
    throw "Safety check failed: unexpected project root $projectRoot"
}
if (Test-Path -LiteralPath (Join-Path $projectRoot '.git')) {
    throw 'Root Git repository already exists. Refusing to rebuild history.'
}

$relativeRoots = @(
    '00_总纲与管理',
    '01_第一册_大唐开国',
    '02_第二册_贞观君臣',
    '03_第三册_武后的天下',
    '03_学习辅助'
)

$sourceFiles = foreach ($relativeRoot in $relativeRoots) {
    $absoluteRoot = Join-Path $projectRoot $relativeRoot
    Get-ChildItem -LiteralPath $absoluteRoot -Recurse -File -Filter '*.md'
}

$backupRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("tang-history-git-migration-" + (Get-Date -Format 'yyyyMMdd-HHmmss'))
New-Item -ItemType Directory -Path $backupRoot | Out-Null

foreach ($relativeRoot in $relativeRoots) {
    $sourceRoot = Join-Path $projectRoot $relativeRoot
    $destinationRoot = Join-Path $backupRoot $relativeRoot
    New-Item -ItemType Directory -Path (Split-Path -Parent $destinationRoot) -Force | Out-Null
    Copy-Item -LiteralPath $sourceRoot -Destination $destinationRoot -Recurse
}

$sourceHash = @{}
foreach ($file in $sourceFiles) {
    $relative = [System.IO.Path]::GetRelativePath($projectRoot, $file.FullName)
    $sourceHash[$relative] = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash
}

$backupFiles = foreach ($relativeRoot in $relativeRoots) {
    Get-ChildItem -LiteralPath (Join-Path $backupRoot $relativeRoot) -Recurse -File -Filter '*.md'
}
if ($backupFiles.Count -ne $sourceFiles.Count) {
    throw "Backup count mismatch: source=$($sourceFiles.Count), backup=$($backupFiles.Count)"
}
foreach ($file in $backupFiles) {
    $relative = [System.IO.Path]::GetRelativePath($backupRoot, $file.FullName)
    $hash = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash
    if (-not $sourceHash.ContainsKey($relative) -or $sourceHash[$relative] -ne $hash) {
        throw "Backup hash mismatch: $relative"
    }
}

Write-Output "Verified backup: $backupRoot"
Write-Output "Markdown files: $($sourceFiles.Count)"

if (-not $Execute) {
    Write-Output 'Dry run complete. Re-run with -Execute to rebuild Git history.'
    exit 0
}

foreach ($file in $sourceFiles) {
    $resolved = [System.IO.Path]::GetFullPath($file.FullName)
    if (-not $resolved.StartsWith($projectRoot + [System.IO.Path]::DirectorySeparatorChar, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Refusing to remove file outside project: $resolved"
    }
    Remove-Item -LiteralPath $resolved
}

Push-Location $projectRoot
try {
    Invoke-Git init -b main

    $records = foreach ($file in $backupFiles) {
        $relative = [System.IO.Path]::GetRelativePath($backupRoot, $file.FullName)
        [pscustomobject]@{
            Source = $file.FullName
            Relative = $relative
            Version = Get-Version $file.Name
            Target = Get-CanonicalRelativePath $relative
            Priority = Get-SourcePriority $file.Name
            Modified = $file.LastWriteTime
        }
    }

    $stages = @(
        @{ Version = '0.1'; Message = '稿件 v0.1：初稿、研究卡与首轮记录' },
        @{ Version = '0.2'; Message = '稿件 v0.2：首轮修订与故事化试写' },
        @{ Version = '0.3'; Message = '稿件 v0.3：章节扩写' },
        @{ Version = '0.4'; Message = '稿件 v0.4：深度扩写' },
        @{ Version = '1.0'; Message = '稿件 v1.0：写作包、审校与阶段合稿' },
        @{ Version = '1.1'; Message = '稿件 v1.1：扩写合稿与统一精修' },
        @{ Version = '1.2'; Message = '稿件 v1.2：深度扩写合稿' },
        @{ Version = '1.3'; Message = '稿件 v1.3：突厥关系线修订' },
        @{ Version = '1.4'; Message = '稿件 v1.4：第一册史实核校与精修' },
        @{ Version = '1.5'; Message = '稿件 v1.5：第一册精修候选' },
        @{ Version = '2.0'; Message = '稿件 v2.0：总纲重写与第三册结构重建' }
    )

    foreach ($stage in $stages) {
        $stageRecords = @($records | Where-Object Version -eq $stage.Version | Sort-Object Target, Priority, Modified)
        if ($stageRecords.Count -eq 0) {
            continue
        }
        foreach ($record in $stageRecords) {
            $destination = Join-Path $projectRoot $record.Target
            $destinationDirectory = Split-Path -Parent $destination
            New-Item -ItemType Directory -Path $destinationDirectory -Force | Out-Null
            Copy-Item -LiteralPath $record.Source -Destination $destination -Force
        }

        if ($stage.Version -eq '2.0') {
            $legacyRoot = Join-Path $projectRoot '03_第三册_武后的天下\05_旧结构素材_649-683'
            if (Test-Path -LiteralPath $legacyRoot) {
                Get-ChildItem -LiteralPath $legacyRoot -Recurse -File | ForEach-Object { Remove-Item -LiteralPath $_.FullName }
                Get-ChildItem -LiteralPath $legacyRoot -Recurse -Directory | Sort-Object FullName -Descending | ForEach-Object {
                    if (-not (Get-ChildItem -LiteralPath $_.FullName -Force)) { Remove-Item -LiteralPath $_.FullName }
                }
                if (-not (Get-ChildItem -LiteralPath $legacyRoot -Force)) { Remove-Item -LiteralPath $legacyRoot }
            }
        }

        Invoke-Git add -A
        Invoke-Git commit -m $stage.Message
        Invoke-Git tag -a ("v" + $stage.Version) -m $stage.Message
    }

    $unversioned = @($records | Where-Object { -not $_.Version } | Sort-Object Target, Priority, Modified)
    foreach ($record in $unversioned) {
        if ($record.Relative -eq 'README_项目索引.md') {
            continue
        }
        if ($record.Relative -match '05_旧结构素材_649-683') {
            continue
        }
        $destination = Join-Path $projectRoot $record.Target
        $destinationDirectory = Split-Path -Parent $destination
        New-Item -ItemType Directory -Path $destinationDirectory -Force | Out-Null
        Copy-Item -LiteralPath $record.Source -Destination $destination -Force
    }

    Invoke-Git add -A
    $pending = & git status --porcelain
    if ($pending) {
        Invoke-Git commit -m 'docs: 保留当前结构说明与状态文件'
    }

    Write-Output '--- reconstructed history ---'
    & git log --oneline --decorate --reverse
    Write-Output '--- status ---'
    & git status --short --branch
}
finally {
    Pop-Location
}

Write-Output "Migration source backup retained at: $backupRoot"
