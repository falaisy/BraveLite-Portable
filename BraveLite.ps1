# Brave Lite Portable - core logic
# Main menu launcher for Brave, deployed from the official Brave Windows x64
# Stable ZIP (github.com/brave/brave-browser releases).
[CmdletBinding()]
param(
    [switch]$Menu,
    [switch]$Deploy,
    [switch]$Check
)

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$Root         = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$BrowserDir   = Join-Path $Root 'Browser'
$UserDataDir  = Join-Path $Root 'User Data'
$DownloadsDir = Join-Path $Root 'Downloads'
$UpdateTemp   = Join-Path $Root 'UpdateTemp'
$BraveExe     = Join-Path $BrowserDir 'brave.exe'
$RepoApi      = 'https://api.github.com/repos/brave/brave-browser/releases'
$VersionApi   = 'https://versions.brave.com/latest/release-windows-x64.version'
$DownloadRoot = 'https://github.com/brave/brave-browser/releases/download'

function Show-Info {
    param([string]$Text)
    [void][System.Windows.Forms.MessageBox]::Show($Text, 'Brave Lite Portable', 'OK', 'Information')
}

function Show-Error {
    param([string]$Text)
    try { Show-Info $Text } catch { Write-Host $Text -ForegroundColor Red }
}

function Test-Elevated {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    return (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-BrowserProcesses {
    $prefix = [System.IO.Path]::GetFullPath($BrowserDir).TrimEnd('\') + '\'
    $list = @()
    foreach ($p in @(Get-Process -Name 'brave' -ErrorAction SilentlyContinue)) {
        try {
            if ($p.Path -and ([System.IO.Path]::GetFullPath($p.Path)).StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) { $list += $p }
        } catch { }
    }
    return $list
}

function Get-UnreadableBraveCount {
    # A brave process whose path cannot be read is not treated as "not running".
    $count = 0
    foreach ($p in @(Get-Process -Name 'brave' -ErrorAction SilentlyContinue)) {
        try {
            if (-not $p.Path) { $count++ }
        } catch { $count++ }
    }
    return $count
}

function Get-DeployMutexName {
    return ('BLPDeploy-' + (Get-PathId $Root))
}

function Invoke-WithDeployLock {
    # Holds the same named mutex that Invoke-Deploy uses for the whole action, so
    # checking for a deployment and the guarded work cannot be split by another
    # process. A lock that cannot be taken is reported, never waited for.
    param([scriptblock]$Action)
    $mutex = $null
    $taken = $false
    try {
        $mutex = New-Object System.Threading.Mutex($false, (Get-DeployMutexName))
        try { $taken = $mutex.WaitOne(0) } catch [System.Threading.AbandonedMutexException] { $taken = $true }
        if (-not $taken) { return $false }
        & $Action | Out-Null
        return $true
    } finally {
        if ($taken -and $mutex) { try { $mutex.ReleaseMutex() } catch { } }
        if ($mutex) { $mutex.Dispose() }
    }
}

function Test-DeployRunning {
    # Uses the same named mutex as Invoke-Deploy; nothing new is locked.
    $mutex = $null
    $haveLock = $false
    try {
        $mutex = New-Object System.Threading.Mutex($false, (Get-DeployMutexName))
        try { $haveLock = $mutex.WaitOne(0) } catch [System.Threading.AbandonedMutexException] { $haveLock = $true }
    } finally {
        if ($haveLock -and $mutex) { try { $mutex.ReleaseMutex() } catch { } }
        if ($mutex) { $mutex.Dispose() }
    }
    return (-not $haveLock)
}

function Test-PathInside {
    param([string]$Child, [string]$Parent)
    if (-not $Child -or -not $Parent) { return $false }
    try {
        $childFull = [System.IO.Path]::GetFullPath($Child).TrimEnd('\') + '\'
        $parentFull = [System.IO.Path]::GetFullPath($Parent).TrimEnd('\') + '\'
        return $childFull.StartsWith($parentFull, [StringComparison]::OrdinalIgnoreCase)
    } catch { return $false }
}

function Get-BraveVersion {
    param([string]$ExePath)
    if (-not (Test-Path -LiteralPath $ExePath)) { return $null }
    return (Get-Item -LiteralPath $ExePath).VersionInfo.ProductVersion
}

function Get-VersionText {
    param([string]$Uri)
    $wc = New-Object System.Net.WebClient
    $wc.Headers.Add('User-Agent', 'BraveLite-Portable')
    return $wc.DownloadString($Uri)
}

function Get-ReleaseJson {
    param([string]$Uri)
    $headers = @{ 'User-Agent' = 'BraveLite-Portable' }
    return Invoke-RestMethod -Uri $Uri -Headers $headers -TimeoutSec 60
}

function Get-StableVersion {
    # The Stable version is read from the official Brave version endpoint. Only a
    # plain three-part version number is accepted; error pages, HTML or anything
    # unexpected stops the deployment, and there is no fallback to another channel.
    $raw = $null
    try { $raw = Get-VersionText $VersionApi } catch { throw ('Reading the official Stable version endpoint failed: ' + $_.Exception.Message + ' Deployment stopped; no other channel or source is used.') }
    if ($null -eq $raw) { throw 'The official Stable version endpoint returned no response. Deployment stopped.' }
    $text = $raw.Trim()
    if ($text.Length -eq 0) { throw 'The official Stable version endpoint returned an empty response. Deployment stopped.' }
    if ($text -notmatch '^\d{1,3}\.\d{1,4}\.\d{1,4}$') {
        if ($text.Length -gt 60) { $text = $text.Substring(0, 60) + '...' }
        throw ('The official Stable version endpoint returned an unexpected value: ' + $text + '. Deployment stopped.')
    }
    return $text
}

function Get-ReleaseByTag {
    param([string]$Version)
    $tag = 'v' + $Version
    try {
        $rel = Get-ReleaseJson ($RepoApi + '/tags/' + $tag)
    } catch {
        throw ('GitHub release lookup for tag ' + $tag + ' failed: ' + $_.Exception.Message + ' Deployment stopped; no other source is used.')
    }
    if (-not $rel) { throw ('No GitHub release found for the official Stable tag ' + $tag + '. Deployment stopped; no other source is used.') }
    if ($rel.draft) { throw ('GitHub release ' + $tag + ' is a draft. Deployment stopped.') }
    if ($rel.prerelease) { throw ('GitHub release ' + $tag + ' is a pre-release. Deployment stopped.') }
    if ($rel.tag_name -ne $tag) { throw ('GitHub release tag mismatch: expected ' + $tag + ', got ' + $rel.tag_name + '. Deployment stopped.') }
    if ($rel.name -notlike 'Release *') { throw ('GitHub release ' + $tag + ' is not a Brave Stable release (name: ' + $rel.name + '). Deployment stopped.') }
    $zipName = 'brave-v' + $Version + '-win32-x64.zip'
    $zip = @($rel.assets | Where-Object { $_.name -eq $zipName }) | Select-Object -First 1
    if (-not $zip) { throw ('GitHub release ' + $tag + ' has no ' + $zipName + ' asset. Deployment stopped; no other source is used.') }
    if ($zip.browser_download_url -notlike 'https://github.com/brave/brave-browser/releases/download/*') { throw ('GitHub asset ' + $zipName + ' does not point at the official download endpoint. Deployment stopped.') }
    if (-not $zip.size) { throw ('GitHub asset ' + $zipName + ' has no size information. Deployment stopped.') }
    $sum = @($rel.assets | Where-Object { $_.name -eq ($zipName + '.sha256') }) | Select-Object -First 1
    if (-not $sum) { throw ('GitHub release ' + $tag + ' has no ' + $zipName + '.sha256 asset. Deployment stopped.') }
    return [pscustomobject]@{
        Version   = $Version
        Tag       = $tag
        ZipName   = $zipName
        ZipSize   = [int64]$zip.size
        SumName   = ($zipName + '.sha256')
        Published = $rel.published_at
    }
}

function Get-TextContent {
    param([string]$Uri)
    $wc = New-Object System.Net.WebClient
    $wc.Headers.Add('User-Agent', 'BraveLite-Portable')
    return $wc.DownloadString($Uri)
}

function Format-Size {
    param([int64]$Bytes)
    if ($Bytes -ge 1073741824) { return ('{0:N2} GB' -f ($Bytes / 1073741824)) }
    return ('{0:N1} MB' -f ($Bytes / 1MB))
}

function Get-File {
    # Streams the download so the console can show progress. When the server sends
    # a reliable Content-Length the real percentage is shown; otherwise only the
    # amount received is shown and no percentage is invented. The file is written
    # straight to $OutFile, so the existing size, SHA-256 and cleanup checks are
    # unchanged.
    param([string]$Uri, [string]$OutFile)
    $request = [System.Net.HttpWebRequest]::Create($Uri)
    $request.UserAgent = 'BraveLite-Portable'
    $request.Timeout = 120000
    $response = $request.GetResponse()
    try {
        $total = [int64]$response.ContentLength
        $totalKnown = ($total -gt 0)
        $stream = $response.GetResponseStream()
        try {
            $file = [System.IO.File]::Create($OutFile)
            try {
                $buffer = New-Object byte[] 81920
                $received = [int64]0
                $lastPercent = -1
                $lastShown = [int64]0
                while (($read = $stream.Read($buffer, 0, $buffer.Length)) -gt 0) {
                    $file.Write($buffer, 0, $read)
                    $received += $read
                    if ($totalKnown) {
                        $percent = [int][math]::Floor(($received * 100) / $total)
                        if ($percent -ne $lastPercent) {
                            $lastPercent = $percent
                            Write-Host ('  ' + $percent + '%  ' + (Format-Size $received) + ' / ' + (Format-Size $total))
                        }
                    } elseif (($received - $lastShown) -ge 4194304) {
                        $lastShown = $received
                        Write-Host ('  Downloaded: ' + (Format-Size $received) + ' (total size not reported by the server)')
                    }
                }
            } finally { $file.Dispose() }
        } finally { $stream.Dispose() }
        if ($totalKnown) {
            Write-Host ('Download finished: ' + (Format-Size $received) + ' / ' + (Format-Size $total))
        } else {
            Write-Host ('Download finished: ' + (Format-Size $received) + ' received')
        }
    } finally { $response.Dispose() }
}

function Test-Signature {
    # The signer certificate thumbprint is pinned to the one observed on the
    # official Stable builds (1.99.57 and 1.100.58). The comparison is exact and
    # case-insensitive; if Brave rotates the certificate, deployment stops here
    # instead of silently accepting another signer.
    param([string]$ExePath)
    if (-not (Test-Path -LiteralPath $ExePath)) { return 'brave.exe is missing.' }
    $sig = Get-AuthenticodeSignature -LiteralPath $ExePath
    if ($sig.Status -ne 'Valid') { return ('signature status: ' + $sig.Status) }
    if (-not $sig.SignerCertificate) { return 'signer certificate is missing.' }
    if ($sig.SignerCertificate.Subject -notlike '*Brave Software, Inc.*') { return 'signer is not Brave Software, Inc.' }
    $approved = 'F8AC5F11DE7E26383B7A389FC19A2613835799D7'
    $actual = ([string]$sig.SignerCertificate.Thumbprint).Replace(' ', '').ToUpperInvariant()
    if ($actual -ne $approved) { return ('signer certificate thumbprint is not approved: ' + $actual) }
    return $null
}

function Test-Payload {
    param([string]$Dir, [string]$ExpectedVersion)
    $exe = Join-Path $Dir 'brave.exe'
    $problem = Test-Signature $exe
    if ($problem) { return ('payload ' + $problem) }
    $ver = Get-BraveVersion $exe
    if ($ExpectedVersion -and $ver -notlike ('*' + $ExpectedVersion)) { return ('payload version mismatch: ' + $ver) }
    return $null
}

function Test-BrowserFolder {
    # The acceptance check for an existing Browser folder (installed, restored or
    # kept in a backup): required files, exactly one version folder whose name is
    # identical to the ProductVersion read from brave.exe, readable version
    # information, and the pinned signature. A folder that only looks complete, or
    # whose version folder carries another version, is not treated as usable.
    param([string]$Dir)
    $problem = Test-Install $Dir
    if ($problem) { return $problem }
    $exe = Join-Path $Dir 'brave.exe'
    $version = Get-BraveVersion $exe
    if (-not (Test-VersionString $version)) { return 'brave.exe has no usable version information.' }
    $folders = @(Get-ChildItem -LiteralPath $Dir -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -match '^\d+(\.\d+)+$' })
    if ($folders.Count -ne 1) { return ('Expected exactly one Brave version folder, found ' + $folders.Count + ': ' + (($folders | ForEach-Object { $_.Name }) -join ', ')) }
    if ($folders[0].Name -ne $version) { return ('The version folder ' + $folders[0].Name + ' does not match brave.exe version ' + $version) }
    return (Test-Payload -Dir $Dir)
}

function Get-PathId {
    param([string]$Path)
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($Path.ToLowerInvariant())
    return ([System.BitConverter]::ToString([System.Security.Cryptography.MD5]::Create().ComputeHash($bytes))).Replace('-', '')
}

function Test-VersionString {
    param([string]$Text)
    if (-not $Text) { return $null }
    $clean = $Text.Trim()
    if ($clean -notmatch '^\d+(\.\d+){1,3}$') { return $null }
    try { return [version]$clean } catch { return $null }
}

function Get-VersionParts {
    param([string]$Text)
    $v = Test-VersionString $Text
    if (-not $v) { return $null }
    if ($v.Revision -lt 0) { return @([int64]$v.Major, [int64]$v.Minor, [int64]$v.Build) }
    $parts = @([int64]$v.Major, [int64]$v.Minor, [int64]$v.Build, [int64]$v.Revision)
    # Chromium-style 4-part version (for example 158.1.100.58) starts with the
    # Chromium major version; the release tag only carries the Brave version.
    if ($parts[0] -ge 100) { return @($parts[1], $parts[2], $parts[3]) }
    return $parts
}

function Compare-VersionParts {
    param($LocalParts, $RemoteParts)
    if (-not $LocalParts -or -not $RemoteParts) { return $null }
    $count = [math]::Max($LocalParts.Count, $RemoteParts.Count)
    for ($i = 0; $i -lt $count; $i++) {
        $l = if ($i -lt $LocalParts.Count) { $LocalParts[$i] } else { 0 }
        $r = if ($i -lt $RemoteParts.Count) { $RemoteParts[$i] } else { 0 }
        if ($l -lt $r) { return -1 }
        if ($l -gt $r) { return 1 }
    }
    return 0
}

function Move-BrowserAside {
    # Moves an unusable Browser folder into UpdateTemp\Failed so that nothing the
    # user might want to inspect is deleted. Returns $true when Browser is gone.
    param([string]$Reason)
    $failedRoot = Join-Path $UpdateTemp ('Failed-' + (Get-Date -Format 'yyyyMMdd-HHmmss'))
    try {
        New-Item -ItemType Directory -Path $failedRoot -Force | Out-Null
        $destination = Join-Path $failedRoot 'Browser'
        Move-Item -LiteralPath $BrowserDir -Destination $destination
        Write-Host ('The unusable Browser folder was moved to ' + $destination + ' (' + $Reason + ').') -ForegroundColor Yellow
        return $true
    } catch {
        Write-Host ('The unusable Browser folder could not be moved aside: ' + $_.Exception.Message) -ForegroundColor Yellow
        Write-Host ('It was left in place: ' + $BrowserDir)
        return $false
    }
}

function Restore-StaleBackup {
    # Runs while the deployment mutex is held. A backup is verified before any
    # existing Browser folder is touched. The browser itself must pass the same
    # acceptance check as a deployed payload (files, version, pinned signature);
    # a folder that is only structurally complete is not accepted. Every backup
    # folder is verified, not only the newest one, so a damaged newest backup does
    # not hide a usable older one. The chosen backup is copied, verified, moved
    # into place and verified again; on any failure all backups are kept.
    if (-not (Test-Path -LiteralPath $UpdateTemp)) { return }
    $backups = @(Get-ChildItem -LiteralPath (Join-Path $UpdateTemp 'Backup') -Directory -Filter 'Browser-*' -ErrorAction SilentlyContinue | Sort-Object Name -Descending)
    if ($backups.Count -eq 0) { return }
    $browserProblem = $null
    if (Test-Path -LiteralPath $BrowserDir) {
        $browserProblem = Test-BrowserFolder $BrowserDir
        if (-not $browserProblem) { return }
    }
    $source = $null
    $rejected = @()
    foreach ($candidate in $backups) {
        $problem = Test-BrowserFolder $candidate.FullName
        if (-not $problem) { $source = $candidate; break }
        $rejected += ($candidate.Name + ': ' + $problem)
    }
    if (-not $source) {
        throw ('A previous deployment did not finish and no usable backup was found (' + ($rejected -join '; ') + '). Nothing was changed. Browser: ' + $BrowserDir + ' Backups kept at: ' + (Join-Path $UpdateTemp 'Backup'))
    }
    if ($browserProblem) {
        Write-Host ('Browser is present but not usable (' + $browserProblem + '). A usable backup was found.') -ForegroundColor Yellow
        if (-not (Move-BrowserAside $browserProblem)) {
            throw ('The unusable Browser folder could not be moved aside, so the backup was not restored. Nothing was deleted. Backup kept at: ' + $source.FullName)
        }
    } else {
        Write-Host ('Browser is missing. Found backup: ' + $source.FullName) -ForegroundColor Yellow
    }
    $stage = Join-Path $UpdateTemp 'Restore'
    if (Test-Path -LiteralPath $stage) { Remove-Item -LiteralPath $stage -Recurse -Force }
    Copy-Item -LiteralPath $source.FullName -Destination $stage -Recurse -Force
    $problem = Test-BrowserFolder $stage
    if ($problem) {
        if (Test-Path -LiteralPath $stage) { Remove-Item -LiteralPath $stage -Recurse -Force }
        throw ('Copy of the backup failed verification (' + $problem + '). The original backup was kept at: ' + $source.FullName)
    }
    Move-Item -LiteralPath $stage -Destination $BrowserDir
    $problem = Test-BrowserFolder $BrowserDir
    if ($problem) {
        throw ('Restored Browser failed the integrity check (' + $problem + '). The restored folder was left in place at: ' + $BrowserDir + ' and the original backup is still kept at: ' + $source.FullName)
    }
    Write-Host 'Restored Browser from the previous backup; integrity check passed.' -ForegroundColor Green
}

function Invoke-Deploy {
    param([switch]$Automatic)
    Write-Host 'Brave Lite Portable - official ZIP deployment'
    if (Test-Elevated) { throw 'Refusing to run elevated. Run without administrator rights.' }

    $mutex = New-Object System.Threading.Mutex($false, (Get-DeployMutexName))
    $haveLock = $false
    try { $haveLock = $mutex.WaitOne(0) } catch [System.Threading.AbandonedMutexException] { $haveLock = $true }
    if (-not $haveLock) { $mutex.Dispose(); throw 'Another deployment of this copy is already running. Wait for it to finish, then retry.' }

    $success = $false
    $started = $false
    $zipPath = $null
    try {
        Restore-StaleBackup

        Write-Host 'Reading the official Stable version ...'
        $stableVersion = Get-StableVersion
        Write-Host ('Official Stable version: ' + $stableVersion)
        Write-Host ('Looking up the matching release tag: v' + $stableVersion)
        $rel = Get-ReleaseByTag $stableVersion
        Write-Host ('Release          : ' + $rel.Tag + ' (published ' + $rel.Published + ')')
        Write-Host ('Asset            : ' + $rel.ZipName + ' / ' + $rel.ZipSize + ' bytes')

        $localText = Get-BraveVersion $BraveExe
        $localVer = Test-VersionString $localText
        $remoteVer = Test-VersionString $rel.Version
        if (-not $remoteVer) { throw ('Official release version has an unexpected format: ' + $rel.Version + '. Deployment stopped.') }
        if ($localVer) {
            Write-Host ('Installed version: ' + $localVer)
            $cmp = Compare-VersionParts (Get-VersionParts $localText) (Get-VersionParts $rel.Version)
            if ($cmp -eq 0) {
                # The same version is not enough: the folder has to pass the same
                # complete acceptance check that options 1 and 3 use. A folder that
                # looks up to date but is not usable is backed up and replaced by a
                # fresh deployment instead of being reported as up to date.
                $folderProblem = Test-BrowserFolder $BrowserDir
                if (-not $folderProblem) {
                    Write-Host 'Already up to date. Nothing was downloaded or changed.'
                    return
                }
                Write-Host ('Installed version matches the official release, but the Browser folder failed the acceptance check: ' + $folderProblem) -ForegroundColor Yellow
                Write-Host 'The folder will be backed up and replaced by a fresh deployment.' -ForegroundColor Cyan
            }
            if ($cmp -gt 0) {
                Write-Host ('The official Stable release (' + $rel.Version + ') is older than the installed version. Downgrade is not allowed. Nothing was changed.') -ForegroundColor Yellow
                return
            }
            Write-Host ('Update available: ' + $localText + ' -> ' + $rel.Version) -ForegroundColor Cyan
        } else {
            Write-Host 'Browser is not installed yet; a fresh deployment will be performed.'
        }

        # The first run from menu option 1 deploys without asking. The manual
        # update (menu option 2) keeps its confirmation.
        if (-not $Automatic) {
            $answer = Read-Host 'Download and deploy this version? [y/N]'
            if ($null -eq $answer) { $answer = '' }
            if ($answer.Trim() -notmatch '^(?i)y(es)?$') {
                Write-Host 'Cancelled. Browser was not changed.'
                return
            }
        }

        $running = Get-BrowserProcesses
        if ($running.Count -gt 0) { throw ('Brave is running from ' + $BrowserDir + '. Close it and retry.') }

        $extractDir = Join-Path $UpdateTemp 'Extract'
        $backupDir  = Join-Path $UpdateTemp 'Backup'
        $downloadDir = Join-Path $UpdateTemp 'Download'

        # Recreate only the folders this run overwrites. UpdateTemp\Backup is not
        # cleared: it can still be the only copy of a previous Browser when an
        # earlier recovery has not completed. Isolated Failed-* folders and the
        # backups are kept until a deployment has been fully verified.
        foreach ($managed in @($extractDir, $downloadDir)) {
            if (Test-Path -LiteralPath $managed) { Remove-Item -LiteralPath $managed -Recurse -Force }
        }
        New-Item -ItemType Directory -Path $extractDir, $downloadDir -Force | Out-Null
        if (-not (Test-Path -LiteralPath $backupDir)) { New-Item -ItemType Directory -Path $backupDir -Force | Out-Null }
        $started = $true

        $runId = Get-Date -Format 'yyyyMMdd-HHmmss'
        $zipName = 'brave-v' + $rel.Version + '-win32-x64-' + $runId + '.zip'
        $zipPath = Join-Path $downloadDir $zipName
        if (Test-Path -LiteralPath $zipPath) { throw ('Download target already exists: ' + $zipPath + '. Nothing was overwritten.') }

        $sumUri = $DownloadRoot + '/' + $rel.Tag + '/' + $rel.SumName
        $zipUri = $DownloadRoot + '/' + $rel.Tag + '/' + $rel.ZipName
        Write-Host ('Fetching official checksum: ' + $sumUri)
        $sumText = (Get-TextContent $sumUri).Trim()
        $expected = ($sumText -split '\s+')[0].ToLower()
        if ($expected -notmatch '^[0-9a-f]{64}$') { throw 'Official checksum file is not a SHA-256 value.' }

        Write-Host ('Downloading to: ' + $zipPath)
        Get-File $zipUri $zipPath
        $size = (Get-Item -LiteralPath $zipPath).Length
        if ($size -ne $rel.ZipSize) { throw ('Size mismatch: ' + $size + ' vs official ' + $rel.ZipSize + '.') }
        $actual = (Get-FileHash -LiteralPath $zipPath -Algorithm SHA256).Hash.ToLower()
        Write-Host ('SHA-256 official : ' + $expected)
        Write-Host ('SHA-256 actual   : ' + $actual)
        if ($actual -ne $expected) { throw 'SHA-256 mismatch against official checksum. Deployment stopped.' }

        Write-Host 'Extracting ...'
        Expand-Archive -LiteralPath $zipPath -DestinationPath $extractDir -Force
        $problem = Test-Payload -Dir $extractDir -ExpectedVersion $rel.Version
        if ($problem) { throw ('Payload validation failed: ' + $problem) }
        Write-Host ('Payload validated: version ' + (Get-BraveVersion (Join-Path $extractDir 'brave.exe')))

        $backupPath = $null
        $running = Get-BrowserProcesses
        if ($running.Count -gt 0) { throw ('Brave started while the download was running. Close it and retry. Nothing was changed.') }
        $unreadable = Get-UnreadableBraveCount
        if ($unreadable -gt 0) { throw ('A Brave process was found but its program path could not be read, so it cannot be checked. Close every Brave window and retry.') }
        if (Test-Path -LiteralPath $BrowserDir) {
            $backupPath = Join-Path $backupDir ('Browser-' + (Get-Date -Format 'yyyyMMdd-HHmmss'))
            if (Test-Path -LiteralPath $backupPath) { throw ('The backup location already exists: ' + $backupPath + '. Nothing was moved or overwritten.') }
            Write-Host ('Backing up current Browser to ' + $backupPath)
            Move-Item -LiteralPath $BrowserDir -Destination $backupPath
        }
        try {
            $running = Get-BrowserProcesses
            if ($running.Count -gt 0) { throw 'Brave started while the deployment was running. Close it and retry.' }
            Move-Item -LiteralPath $extractDir -Destination $BrowserDir
            $problem = Test-Payload -Dir $BrowserDir -ExpectedVersion $rel.Version
            # The deployment only counts as successful after the complete
            # acceptance check; the backup is kept until this passes.
            if (-not $problem) { $problem = Test-BrowserFolder $BrowserDir }
            if ($problem) { throw ('Deployed payload validation failed: ' + $problem) }
        } catch {
            Write-Host 'Deployment failed, rolling back ...'
            if (Test-Path -LiteralPath $BrowserDir) { [void](Move-BrowserAside 'the new deployment failed validation') }
            $restored = $false
            $moveBackFailed = $false
            if (-not (Test-Path -LiteralPath $BrowserDir) -and $backupPath -and (Test-Path -LiteralPath $backupPath)) {
                try { Move-Item -LiteralPath $backupPath -Destination $BrowserDir; $restored = $true }
                catch { $moveBackFailed = $true; Write-Host ('The previous Browser could not be moved back: ' + $_.Exception.Message + '. Backup kept at: ' + $backupPath) -ForegroundColor Yellow }
            }
            if ($restored) {
                $check = Test-BrowserFolder $BrowserDir
                if ($check) {
                    Write-Host ('Rollback check failed: ' + $check + '. The folder was kept at: ' + $BrowserDir + ' ; backup kept at: ' + $backupPath + '. The next start retries recovery.') -ForegroundColor Yellow
                } else {
                    Write-Host 'Rollback verified: the previous Browser was restored.' -ForegroundColor Yellow
                }
            } elseif ((-not $moveBackFailed) -and $backupPath -and (Test-Path -LiteralPath $backupPath)) {
                Write-Host ('The previous Browser is still in the backup folder: ' + $backupPath + '. The current Browser folder was kept at: ' + $BrowserDir + '. The next start retries recovery.') -ForegroundColor Yellow
            }
            throw
        }

        if (-not (Test-Path -LiteralPath $UserDataDir)) { New-Item -ItemType Directory -Path $UserDataDir -Force | Out-Null }
        Write-Host ('Deployed: ' + $BraveExe + ' (version ' + (Get-BraveVersion $BraveExe) + ')')
        $success = $true
    } finally {
        if ($success) {
            $cleanupFailed = $false
            if ($zipPath -and (Test-Path -LiteralPath $zipPath)) {
                try { Remove-Item -LiteralPath $zipPath -Force }
                catch {
                    $cleanupFailed = $true
                    Write-Host ('Downloaded ZIP could not be removed: ' + $_.Exception.Message) -ForegroundColor Yellow
                    Write-Host ('Delete this file manually: ' + $zipPath) -ForegroundColor Yellow
                }
            }
            try {
                if (Test-Path -LiteralPath $UpdateTemp) { Remove-Item -LiteralPath $UpdateTemp -Recurse -Force }
            } catch {
                $cleanupFailed = $true
                Write-Host ('Temporary cleanup failed: ' + $_.Exception.Message) -ForegroundColor Yellow
                Write-Host ('Delete this folder manually: ' + $UpdateTemp) -ForegroundColor Yellow
            }
            if ($cleanupFailed) { Write-Host 'Deployment finished, but temporary cleanup was incomplete.' -ForegroundColor Yellow }
            else { Write-Host 'Deployment finished.' }
        } elseif ($started) {
            if (Test-Path -LiteralPath $UpdateTemp) {
                Write-Host ('Deployment did not complete. Recovery data kept in: ' + $UpdateTemp) -ForegroundColor Yellow
            }
            if ($zipPath -and (Test-Path -LiteralPath $zipPath)) {
                Write-Host ('Downloaded ZIP kept for reference: ' + $zipPath) -ForegroundColor Yellow
            }
        }
        if ($haveLock) { $mutex.ReleaseMutex() }
        $mutex.Dispose()
    }
}

function Invoke-Check {
    Write-Host 'Checking files and signature ...'
    $failures = 0

    $problem = Test-Install $BrowserDir
    if ($problem) { Write-Host ('  [FAIL] ' + $problem) -ForegroundColor Red; $failures++ }
    else { Write-Host '  [PASS] brave.exe, version folder and required payload files are present' -ForegroundColor Green }

    $ver = Get-BraveVersion $BraveExe
    if (-not $ver) {
        Write-Host '  [FAIL] Version information cannot be read from brave.exe' -ForegroundColor Red; $failures++
    } else {
        Write-Host ('  [PASS] Version information: ' + $ver) -ForegroundColor Green
        $folders = @(Get-ChildItem -LiteralPath $BrowserDir -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -match '^\d+(\.\d+)+$' })
        if ($folders.Count -eq 1 -and $folders[0].Name -eq $ver) {
            Write-Host ('  [PASS] Version folder matches executable: ' + $ver) -ForegroundColor Green
        } else {
            Write-Host ('  [FAIL] Version folder does not match executable version: ' + $ver) -ForegroundColor Red; $failures++
        }
        $sigProblem = Test-Signature $BraveExe
        if ($sigProblem) { Write-Host ('  [FAIL] Signature: ' + $sigProblem) -ForegroundColor Red; $failures++ }
        else { Write-Host '  [PASS] Signature is valid and signed by Brave Software, Inc.' -ForegroundColor Green }
    }

    if ($failures -eq 0) { Write-Host 'Result: PASS' -ForegroundColor Green }
    else { Write-Host ('Result: FAIL (' + $failures + ' problem(s))') -ForegroundColor Red }
}

function Test-Install {
    param([string]$Dir)
    $exe = Join-Path $Dir 'brave.exe'
    if (-not (Test-Path -LiteralPath $exe)) { return 'Browser\brave.exe is missing.' }
    $candidates = @()
    foreach ($d in @(Get-ChildItem -LiteralPath $Dir -Directory -ErrorAction SilentlyContinue)) {
        if ($d.Name -match '^\d+(\.\d+)+$') { $candidates += $d }
    }
    if ($candidates.Count -eq 0) { return 'The Brave version folder is missing.' }
    if ($candidates.Count -gt 1) {
        $ver = (Get-Item -LiteralPath $exe).VersionInfo.ProductVersion
        $candidates = @($candidates | Where-Object { $_.Name -eq $ver })
        if ($candidates.Count -ne 1) { return 'More than one Brave version folder was found and none matches brave.exe; remove the unused version folders.' }
    }
    $payload = Join-Path $Dir $candidates[0].Name
    foreach ($name in @('chrome.dll', 'chrome_elf.dll', 'resources.pak')) {
        if (-not (Test-Path -LiteralPath (Join-Path $payload $name))) { return ('Required Brave file is missing: ' + $name) }
    }
    return $null
}

function Skip-JsonString {
    # Returns the index just after the closing quote, or -1 when unterminated.
    param([string]$Json, [int]$Index)
    $i = $Index + 1
    while ($i -lt $Json.Length) {
        $c = $Json[$i]
        if ($c -eq '\') { $i += 2; continue }
        if ($c -eq '"') { return ($i + 1) }
        $i++
    }
    return -1
}

function Get-JsonValueEnd {
    param([string]$Json, [int]$Start)
    $c = $Json[$Start]
    if ($c -eq '{' -or $c -eq '[') {
        $close = '}'
        if ($c -eq '[') { $close = ']' }
        $depth = 0
        $i = $Start
        while ($i -lt $Json.Length) {
            $ch = $Json[$i]
            if ($ch -eq '"') {
                $i = Skip-JsonString $Json $i
                if ($i -lt 0) { return -1 }
                continue
            }
            if ($ch -eq $c) { $depth++ }
            elseif ($ch -eq $close) {
                $depth--
                if ($depth -eq 0) { return ($i + 1) }
            }
            $i++
        }
        return -1
    }
    if ($c -eq '"') { return (Skip-JsonString $Json $Start) }
    $i = $Start
    while ($i -lt $Json.Length -and $Json[$i] -ne ',' -and $Json[$i] -ne '}' -and $Json[$i] -ne ']') { $i++ }
    return $i
}

function Find-JsonMember {
    # Finds a member of the root object by name. String contents are skipped, so
    # braces inside paths or other values cannot confuse the search, and only
    # the root object is searched (not extension subtrees).
    param([string]$Json, [string]$Name)
    $depth = 0
    $i = 0
    while ($i -lt $Json.Length) {
        $c = $Json[$i]
        if ($c -eq '"') {
            $end = Skip-JsonString $Json $i
            if ($end -lt 0) { return $null }
            if ($depth -eq 1) {
                $key = $Json.Substring($i + 1, $end - $i - 2)
                $j = $end
                while ($j -lt $Json.Length -and [char]::IsWhiteSpace($Json[$j])) { $j++ }
                if ($j -lt $Json.Length -and $Json[$j] -eq ':' -and $key -eq $Name) {
                    $v = $j + 1
                    while ($v -lt $Json.Length -and [char]::IsWhiteSpace($Json[$v])) { $v++ }
                    if ($v -ge $Json.Length) { return $null }
                    $vend = Get-JsonValueEnd $Json $v
                    if ($vend -lt 0) { return $null }
                    return [pscustomobject]@{ ValueStart = $v; ValueEnd = $vend; Text = $Json.Substring($v, $vend - $v) }
                }
            }
            $i = $end
            continue
        }
        if ($c -eq '{') { $depth++; $i++; continue }
        if ($c -eq '}') { $depth--; $i++; continue }
        $i++
    }
    return $null
}

function Get-StoredDownloadDirectory {
    param([string]$PrefsPath)
    try {
        $json = [IO.File]::ReadAllText($PrefsPath)
        $download = Find-JsonMember $json 'download'
        if (-not $download) { return '' }
        if ($download.Text.Length -lt 2) { return '' }
        if ($download.Text[0] -ne '{') { return '' }
        $inner = Find-JsonMember $download.Text 'default_directory'
        if (-not $inner) { return '' }
        $text = $inner.Text
        if ($text.Length -lt 2) { return '' }
        if ($text[0] -ne '"') { return '' }
        return [regex]::Unescape($text.Substring(1, $text.Length - 2))
    } catch {
        return ''
    }
}

function Set-DownloadDirectory {
    # Keeps the download folder the user already picked in Brave. The setting is
    # only changed when the stored folder is empty, points inside the managed
    # Browser/UpdateTemp folders, or no longer exists on a drive that is
    # available. A folder on a temporarily disconnected drive is left alone.
    if ((Get-BrowserProcesses).Count -gt 0) { return }
    $profileDir = Join-Path $UserDataDir 'Default'
    $prefs = Join-Path $profileDir 'Preferences'
    $target = $DownloadsDir.TrimEnd('\')
    if (Test-Path -LiteralPath $prefs) {
        $current = (Get-StoredDownloadDirectory -PrefsPath $prefs).Trim()
        if ($current) {
            if ((Test-PathInside $current $BrowserDir) -or (Test-PathInside $current $UpdateTemp)) {
                Write-Host ('Stored download folder points inside the managed Browser folder; it will be changed to ' + $target) -ForegroundColor Yellow
            } elseif (Test-Path -LiteralPath $current -PathType Container) {
                return
            } elseif (-not (Test-Path -LiteralPath ([IO.Path]::GetPathRoot($current)))) {
                Write-Host ('Stored download folder is on a drive that is not available right now: ' + $current + '. The setting was kept.') -ForegroundColor Yellow
                return
            }
        }
    }
    if (-not (Test-Path -LiteralPath $target -PathType Container)) {
        try { New-Item -ItemType Directory -Path $target -Force | Out-Null }
        catch { Write-Host ('Warning: Downloads folder could not be created: ' + $_.Exception.Message) -ForegroundColor Yellow; return }
    }
    $escaped = $target.Replace('\', '\\').Replace('"', '\"')
    $valueText = '"' + $escaped + '"'
    $replacement = '"default_directory":' + $valueText
    $tempPath = $prefs + '.blp-tmp'
    $backupPath = $prefs + '.blp-bak'
    if (-not (Test-Path -LiteralPath $prefs)) {
        try {
            New-Item -ItemType Directory -Path $profileDir -Force | Out-Null
            [IO.File]::WriteAllText($tempPath, '{"download":{' + $replacement + '}}')
            $parsed = [IO.File]::ReadAllText($tempPath) | ConvertFrom-Json
            if ($parsed.download.default_directory -ne $target) { throw 'the new Preferences did not keep the expected download folder' }
            [IO.File]::Move($tempPath, $prefs)
            Write-Host ('Download folder set to: ' + $target)
        } catch {
            Write-Host ('Warning: download folder could not be set: ' + $_.Exception.Message) -ForegroundColor Yellow
            try { if (Test-Path -LiteralPath $tempPath) { Remove-Item -LiteralPath $tempPath -Force } } catch { }
        }
        return
    }
    $json = $null
    try { $json = [IO.File]::ReadAllText($prefs) }
    catch { Write-Host ('Warning: Preferences could not be read: ' + $_.Exception.Message) -ForegroundColor Yellow; return }
    $updated = $null
    $download = Find-JsonMember $json 'download'
    if ($download -and $download.Text.Length -gt 0 -and $download.Text[0] -eq '{') {
        $block = $download.Text
        $inner = Find-JsonMember $block 'default_directory'
        if ($inner) {
            $newBlock = $block.Substring(0, $inner.ValueStart) + $valueText + $block.Substring($inner.ValueEnd)
        } else {
            $body = $block.Substring(1)
            if ($body.TrimStart().StartsWith('}')) { $newBlock = '{' + $replacement + '}' }
            else { $newBlock = '{' + $replacement + ',' + $body }
        }
        $updated = $json.Substring(0, $download.ValueStart) + $newBlock + $json.Substring($download.ValueEnd)
    } elseif ($download) {
        # A root "download" member exists but is not an object (null, string,
        # array, number). Replace that value; never add a second member with the
        # same name.
        $updated = $json.Substring(0, $download.ValueStart) + '{' + $replacement + '}' + $json.Substring($download.ValueEnd)
    } else {
        $rootStart = $json.IndexOf('{')
        if ($rootStart -lt 0) { return }
        $rootEnd = Get-JsonValueEnd $json $rootStart
        if ($rootEnd -lt 0) { return }
        $before = $json.Substring(0, $rootEnd - 1)
        $after = $json.Substring($rootEnd - 1)
        if ($before.TrimEnd().EndsWith('{')) { $updated = $before + '"download":{' + $replacement + '}' + $after }
        else { $updated = $before + ',"download":{' + $replacement + '}' + $after }
    }
    if ($updated -eq $json) { return }
    try {
        # The new content is validated in a temporary file first. The atomic
        # replacement also keeps the original Preferences as $backupPath, so a
        # failure can be undone without a half-written file.
        [IO.File]::WriteAllText($tempPath, $updated)
        $parsed = [IO.File]::ReadAllText($tempPath) | ConvertFrom-Json
        if ($parsed.download.default_directory -ne $target) { throw 'the rewritten Preferences did not keep the expected download folder' }
        if (Test-Path -LiteralPath $backupPath) { Remove-Item -LiteralPath $backupPath -Force }
        [IO.File]::Replace($tempPath, $prefs, $backupPath)
        $check = [IO.File]::ReadAllText($prefs) | ConvertFrom-Json
        if ($check.download.default_directory -ne $target) { throw 'the written Preferences did not read back with the expected download folder' }
        try { if (Test-Path -LiteralPath $backupPath) { Remove-Item -LiteralPath $backupPath -Force } } catch { }
        Write-Host ('Download folder set to: ' + $target)
    } catch {
        Write-Host ('Warning: download folder could not be set: ' + $_.Exception.Message) -ForegroundColor Yellow
        try { if (Test-Path -LiteralPath $tempPath) { Remove-Item -LiteralPath $tempPath -Force } } catch { }
        $restored = $false
        if (Test-Path -LiteralPath $backupPath) {
            try { [IO.File]::WriteAllText($prefs, [IO.File]::ReadAllText($backupPath)); $restored = $true } catch { }
        }
        if ($restored) {
            try { Remove-Item -LiteralPath $backupPath -Force } catch { }
        } elseif (Test-Path -LiteralPath $backupPath) {
            Write-Host ('The original Preferences were not restored automatically. Original copy kept at: ' + $backupPath) -ForegroundColor Yellow
        }
    }
}

function Invoke-Launch {
    # The deploy lock is held from the "is a deployment running" check until the
    # Brave process exists, so another deployment cannot replace the Browser in
    # between. The check inside the lock replaces the earlier racy probe.
    $launched = Invoke-WithDeployLock {
        Invoke-LaunchCore
    }
    if (-not $launched) {
        Write-Host 'An update or deployment is still running. Wait for it to finish, then choose 1 again.' -ForegroundColor Yellow
    }
}

function Invoke-LaunchCore {
    # The same complete acceptance check that option 3 reports, so a Browser that
    # option 3 rejects is never started from here.
    $problem = Test-BrowserFolder $BrowserDir
    if ($problem) {
        if (Test-Path -LiteralPath $BrowserDir) {
            Write-Host ('Cannot start Brave. Problem: ' + $problem) -ForegroundColor Red
            Write-Host ('Location: ' + $BrowserDir)
            Write-Host 'Fix: choose 2 (Update Brave). A usable backup from the last attempt is restored automatically; otherwise the official Stable build is downloaded again.'
            Write-Host 'Your User Data folder has not been changed.'
            return
        }
        # First run: no Browser folder at all, so reuse the existing official
        # deployment flow (endpoint, exact tag, SHA-256, signature, rollback).
        Write-Host 'Brave is not installed yet. The official Brave Stable build will be downloaded and deployed now (about 260 MB); no confirmation is needed.' -ForegroundColor Cyan
        Write-Host ('Install location: ' + $BrowserDir)
        try {
            Invoke-Deploy -Automatic
        } catch {
            Write-Host ('First-run installation stopped: ' + $_.Exception.Message) -ForegroundColor Red
            if (Test-Path -LiteralPath $BrowserDir) {
                Write-Host ('Incomplete data may remain at ' + $BrowserDir + '. Use option 2 to retry.') -ForegroundColor Yellow
            } else {
                Write-Host 'No Brave was installed. Nothing else was changed.'
            }
            return
        }
        $problem = Test-BrowserFolder $BrowserDir
        if ($problem) {
            Write-Host ('Brave was not installed: ' + $problem) -ForegroundColor Yellow
            Write-Host 'Nothing else was changed. Use option 2 to try again.'
            return
        }
        if (-not (Test-Path -LiteralPath $UserDataDir)) { New-Item -ItemType Directory -Path $UserDataDir -Force | Out-Null }
        if (-not (Test-Path -LiteralPath $DownloadsDir)) { New-Item -ItemType Directory -Path $DownloadsDir -Force | Out-Null }
        Write-Host ('Brave was installed successfully (version ' + (Get-BraveVersion $BraveExe) + ').') -ForegroundColor Green
    }
    if (-not (Test-Path -LiteralPath $UserDataDir)) { New-Item -ItemType Directory -Path $UserDataDir -Force | Out-Null }
    Set-DownloadDirectory
    $argLine = '--user-data-dir="' + $UserDataDir + '" --no-first-run --no-default-browser-check'
    try {
        $proc = Start-Process -FilePath $BraveExe -ArgumentList $argLine -WorkingDirectory $BrowserDir -PassThru
    } catch {
        Write-Host ('Brave could not be started: ' + $_.Exception.Message) -ForegroundColor Red
        Write-Host ('Location: ' + $BraveExe)
        Write-Host 'This window stays open. Your User Data folder has not been changed.'
        return
    }
    if (-not $proc -or -not $proc.Id) {
        Write-Host 'Brave was not started: the process could not be created.' -ForegroundColor Red
        Write-Host 'This window stays open. Your User Data folder has not been changed.'
        return
    }
    Write-Host ('Brave is starting (process ID ' + $proc.Id + '). This window closes now; Brave keeps running.') -ForegroundColor Green
    $script:CloseAfterLaunch = $true
}

function Show-MenuText {
    Write-Host ''
    Write-Host '=========================================='
    Write-Host ' Brave Lite Portable'
    Write-Host '=========================================='
    Write-Host '  1  Start Brave'
    Write-Host '  2  Update Brave'
    Write-Host '  3  Check files and signature'
    Write-Host '  0  Exit'
    Write-Host ''
}

function Invoke-Menu {
    try { Clear-Host } catch { }
    $script:CloseAfterLaunch = $false
    while ($true) {
        Show-MenuText
        $choice = Read-Host 'Select [1]'
        if ($null -eq $choice) { return }
        $choice = $choice.Trim()
        Write-Host ''
        if ($choice -eq '0') { return }
        if ($choice -eq '' -or $choice -eq '1') {
            try { Invoke-Launch } catch { Write-Host ('ERROR: ' + $_.Exception.Message) -ForegroundColor Red }
            # Only a successful start from option 1 closes the window; every other
            # menu action keeps the menu open.
            if ($script:CloseAfterLaunch) { return }
        } elseif ($choice -eq '2') {
            try { Invoke-Deploy } catch { Write-Host ('ERROR: ' + $_.Exception.Message) -ForegroundColor Red }
        } elseif ($choice -eq '3') {
            try { Invoke-Check } catch { Write-Host ('ERROR: ' + $_.Exception.Message) -ForegroundColor Red }
        } else {
            Write-Host ('Invalid input: ' + $choice + '. Enter 1, 2, 3 or 0.') -ForegroundColor Yellow
        }
    }
}

Add-Type -AssemblyName System.Windows.Forms

try {
    if ($Deploy) { Invoke-Deploy }
    elseif ($Check) { Invoke-Check }
    else { Invoke-Menu }
} catch {
    if ($Deploy -or $Check) {
        Write-Host ('ERROR: ' + $_.Exception.Message) -ForegroundColor Red
        exit 1
    }
    Write-Host ('ERROR: ' + $_.Exception.Message) -ForegroundColor Red
}
