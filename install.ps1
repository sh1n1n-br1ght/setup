[CmdletBinding()]
param(
    [ValidateSet('Install', 'Uninstall', 'Shell', 'Status', 'Doctor', 'Archives', 'Recover')]
    [string]$Action = 'Install',
    [string]$Repository = $(if ($env:DEVKIT_REPOSITORY) { $env:DEVKIT_REPOSITORY } else { 'https://github.com/sh1n1n-br1ght/setup.git' }),
    [string]$Ref = 'main',
    [string]$Distribution = 'Devkit-Ubuntu',
    [switch]$LibraryOnly
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$script:EntryDirectory = $PSScriptRoot
$script:DefaultRepository = 'https://github.com/sh1n1n-br1ght/setup.git'

function Get-Field($Object, [string]$Name, $Default = $null) {
    if ($null -ne $Object -and $Object.PSObject.Properties[$Name]) { return $Object.$Name }
    return $Default
}

function Set-Field($Object, [string]$Name, $Value) {
    $Object | Add-Member -NotePropertyName $Name -NotePropertyValue $Value -Force
}

function New-Id { return [Guid]::NewGuid().ToString('N') }
function Quote-PowerShell([string]$Text) { return "'" + $Text.Replace("'", "''") + "'" }
function Get-UserVariable([string]$Name) { return [Environment]::GetEnvironmentVariable($Name, 'User') }
function Set-UserVariable([string]$Name, $Value) { [Environment]::SetEnvironmentVariable($Name, $Value, 'User') }
function Get-CurrentSid { return [Security.Principal.WindowsIdentity]::GetCurrent().User.Value }

function Save-State($State) {
    $State.Updated = [DateTime]::UtcNow.ToString('o')
    $bytes = [Text.UTF8Encoding]::new($false).GetBytes(($State | ConvertTo-Json -Depth 32 -Compress) + "`n")
    $stream = [IO.File]::Open($script:Journal, [IO.FileMode]::Append, [IO.FileAccess]::Write, [IO.FileShare]::Read)
    try {
        # A leading newline makes the next complete record readable after a torn write.
        $stream.WriteByte(10)
        $stream.Write($bytes, 0, $bytes.Length)
        $stream.Flush($true)
    } finally { $stream.Dispose() }
}

function Get-State {
    if (-not (Test-Path -LiteralPath $script:Journal)) { return $null }
    $lines = [IO.File]::ReadAllLines($script:Journal)
    for ($i = $lines.Length - 1; $i -ge 0; $i--) {
        try {
            $record = $lines[$i] | ConvertFrom-Json -ErrorAction Stop
            if ((Get-Field $record 'Id') -and (Get-Field $record 'Status')) { return $record }
        } catch { }
    }
    throw "No valid state record in $script:Journal. Files were preserved; restore a saved journal before continuing."
}

function Invoke-Native([string]$File, [string[]]$Arguments, [switch]$Capture) {
    $global:LASTEXITCODE = 0
    if ($Capture) { $output = & $File @Arguments 2>&1 } else { & $File @Arguments | Out-Host }
    if ($LASTEXITCODE -ne 0) { throw "$File failed with exit code $LASTEXITCODE. Rerun -Action Recover after resolving the problem." }
    if ($Capture) { return ($output | Out-String).Trim() }
}

function Invoke-Wsl([string[]]$WslArguments, [switch]$Capture) {
    return Invoke-Native 'wsl.exe' $WslArguments -Capture:$Capture
}

function Get-Distributions {
    $key = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Lxss'
    if (-not (Test-Path -LiteralPath $key)) { return @() }
    return @(Get-ChildItem -LiteralPath $key | ForEach-Object {
        $item = Get-ItemProperty -LiteralPath $_.PSPath
        if (Get-Field $item 'DistributionName') { $item.DistributionName }
    })
}

function Get-WslRegistration([string]$Name) {
    $key = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Lxss'
    if (-not (Test-Path -LiteralPath $key)) { return $null }
    foreach ($item in Get-ChildItem -LiteralPath $key) {
        $values = Get-ItemProperty -LiteralPath $item.PSPath
        if ((Get-Field $values 'DistributionName') -eq $Name) {
            return [PSCustomObject]@{ Id = $item.PSChildName; BasePath = $values.BasePath }
        }
    }
    return $null
}

function Assert-OwnedDistribution($State) {
    $registration = Get-WslRegistration $State.Distribution
    if (-not $registration) { throw 'The setup distribution is no longer registered.' }
    $path = $registration.BasePath -replace '^\\\\\?\\', ''
    if (-not $State.DistroImportStarted -or [IO.Path]::GetFullPath($path).TrimEnd('\', '/') -ne [IO.Path]::GetFullPath($State.WslPath).TrimEnd('\', '/') -or ($State.DistroRegistration -and $State.DistroRegistration -ne $registration.Id)) {
        throw 'The distribution registration no longer matches setup ownership. Nothing in it will be removed.'
    }
    if (-not $State.DistroRegistration) { $State.DistroRegistration = $registration.Id; Save-State $State }
}

function Get-ScoopRoot {
    $command = Get-Command scoop -ErrorAction SilentlyContinue
    if (-not $command) { return $null }
    $prefix = Invoke-Native 'scoop' @('prefix', 'scoop') -Capture
    $root = Split-Path (Split-Path (Split-Path $prefix -Parent) -Parent) -Parent
    if (-not (Test-Path -LiteralPath (Join-Path $root 'apps/scoop'))) { throw 'Unable to determine the existing Scoop installation directory.' }
    return $root
}

function Get-ScoopApps([string]$Root) {
    if (-not $Root -or -not (Test-Path -LiteralPath (Join-Path $Root 'apps'))) { return @() }
    return @(Get-ChildItem -LiteralPath (Join-Path $Root 'apps') -Directory | Where-Object { $_.Name -ne 'scoop' } | ForEach-Object {
        $manifestPath = Join-Path $_.FullName 'current/manifest.json'
        if (-not (Test-Path -LiteralPath $manifestPath)) { throw "Incomplete Scoop app: $($_.FullName). Repair it with Scoop before continuing." }
        $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
        $installPath = Join-Path $_.FullName 'current/install.json'
        $identity = (Get-FileHash -LiteralPath $manifestPath -Algorithm SHA256).Hash
        if (Test-Path -LiteralPath $installPath) { $identity += ':' + (Get-FileHash -LiteralPath $installPath -Algorithm SHA256).Hash }
        $depends = @(Get-Field $manifest 'depends' @())
        $arch = Get-Field $manifest 'architecture'
        if ($arch) { foreach ($entry in $arch.PSObject.Properties) { $depends += @(Get-Field $entry.Value 'depends' @()) } }
        [PSCustomObject]@{ Name = $_.Name; Version = (Get-Field $manifest 'version' 'unknown'); Identity = $identity; Depends = @($depends | ForEach-Object { ($_ -split '/')[-1] } | Select-Object -Unique) }
    })
}

function Get-PathAdditions([string]$Before, [string]$After) {
    $counts = @{}
    foreach ($item in ($Before -split ';')) { if ($item) { $counts[$item] = 1 + [int]$counts[$item] } }
    $added = @()
    foreach ($item in ($After -split ';')) {
        if (-not $item) { continue }
        if ([int]$counts[$item] -gt 0) { $counts[$item]-- } else { $added += $item }
    }
    return $added
}

function Remove-OwnedPathEntries([string]$Current, [string[]]$Added) {
    $items = [Collections.Generic.List[string]]::new()
    foreach ($item in ($Current -split ';')) { $items.Add($item) }
    foreach ($item in $Added) {
        # Remove one occurrence only; keep any independent duplicate or later addition.
        for ($i = 0; $i -lt $items.Count; $i++) {
            if ([string]::Equals($items[$i], $item, [StringComparison]::OrdinalIgnoreCase)) { $items.RemoveAt($i); break }
        }
    }
    return ($items -join ';')
}

function Get-Download([string]$Url, [string]$ExpectedHash = '') {
    $downloads = Join-Path $script:StateRoot 'downloads'
    New-Item -ItemType Directory -Path $downloads -Force | Out-Null
    if ($ExpectedHash) {
        $cached = Join-Path $downloads $ExpectedHash
        if ((Test-Path -LiteralPath $cached) -and (Get-FileHash -LiteralPath $cached -Algorithm SHA256).Hash -eq $ExpectedHash) { return $cached }
    }
    for ($attempt = 1; $attempt -le 3; $attempt++) {
        $path = Join-Path $downloads (New-Id)
        try {
            Invoke-WebRequest -UseBasicParsing -Uri $Url -OutFile $path -TimeoutSec 180
            if ($ExpectedHash -and (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -ne $ExpectedHash) { throw 'Checksum mismatch.' }
            if ($ExpectedHash -and -not (Test-Path -LiteralPath $cached)) { Move-Item -LiteralPath $path -Destination $cached; return $cached }
            return $path
        } catch {
            if ($attempt -eq 3) { throw }
            Write-Warning "Download failed; retaining the incomplete file and retrying ($attempt/3)."
            Start-Sleep -Seconds ($attempt * 2)
        }
    }
}

function Expand-SafeZip([string]$Archive, [string]$Destination) {
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    New-Item -ItemType Directory -Path $Destination | Out-Null
    $base = [IO.Path]::GetFullPath($Destination).TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar
    $zip = [IO.Compression.ZipFile]::OpenRead($Archive)
    try {
        foreach ($entry in $zip.Entries) {
            $name = $entry.FullName.Replace('\', '/')
            if ($name.Contains(':') -or $name -match '(^|/)\.\.(/|$)' -or $name.StartsWith('/')) { throw 'Unsafe repository archive path.' }
            $target = [IO.Path]::GetFullPath((Join-Path $Destination $name))
            if (-not $target.StartsWith($base, [StringComparison]::OrdinalIgnoreCase)) { throw 'Repository archive escapes its directory.' }
            $kind = ($entry.ExternalAttributes -shr 16) -band 61440
            if ($kind -eq 40960) { throw 'Repository archives must not contain symbolic links.' }
            if ($name.EndsWith('/')) { New-Item -ItemType Directory -Path $target -Force | Out-Null; continue }
            New-Item -ItemType Directory -Path (Split-Path $target -Parent) -Force | Out-Null
            $inputStream = $entry.Open()
            $outputStream = [IO.File]::Open($target, [IO.FileMode]::CreateNew)
            try { $inputStream.CopyTo($outputStream); $outputStream.Flush($true) } finally { $inputStream.Dispose(); $outputStream.Dispose() }
        }
    } finally { $zip.Dispose() }
}

function Get-Source($State, [switch]$Force) {
    $previous = Get-Field $State 'Source'
    if (-not $Force -and $previous -and (Test-Path -LiteralPath (Join-Path $previous 'lib/devkit.py')) -and (Get-Field $State 'SourceRepository') -eq $State.Repository -and (Get-Field $State 'SourceRef') -eq $State.Ref) { return $previous }
    $stage = Join-Path $script:StateRoot ('sources/' + (New-Id))
    New-Item -ItemType Directory -Path $stage -Force | Out-Null
    if ($script:EntryDirectory -and (Test-Path -LiteralPath (Join-Path $script:EntryDirectory 'lib/devkit.py')) -and -not $Force) {
        $source = Join-Path $stage 'checkout'
        New-Item -ItemType Directory -Path $source | Out-Null
        Get-ChildItem -LiteralPath $script:EntryDirectory -Force | Where-Object { $_.Name -notin @('.git', '__pycache__') } | Copy-Item -Destination $source -Recurse
    } else {
        $uri = [Uri]$State.Repository
        if ($uri.Scheme -ne 'https' -or $uri.UserInfo -or $uri.Query -or $uri.Fragment) { throw 'Use a public HTTPS repository URL without credentials, query, or fragment.' }
        $path = $uri.AbsolutePath.TrimEnd('/') -replace '\.git$', ''
        if ($path -notmatch '^/[^/]+/[^/]+') { throw 'Repository URL must identify an owner and repository.' }
        $refPart = [Uri]::EscapeDataString($State.Ref)
        if ($uri.Host -eq 'github.com') { $url = "https://github.com$path/archive/$refPart.zip" }
        elseif ($uri.Host -eq 'gitlab.com') { $name = ($path -split '/')[-1]; $url = "https://gitlab.com$path/-/archive/$refPart/$name.zip" }
        else { throw 'Use a local checkout for repository hosts other than github.com and gitlab.com.' }
        $download = Get-Download $url
        $expanded = Join-Path $stage 'expanded'
        Expand-SafeZip $download $expanded
        $roots = @(Get-ChildItem -LiteralPath $expanded -Directory)
        if ($roots.Count -ne 1) { throw 'Expected one repository root in the downloaded archive.' }
        $source = $roots[0].FullName
    }
    foreach ($required in @('install.sh', 'install.ps1', 'lib/devkit.py', 'tools.lock.json', 'config/nvim/init.lua')) {
        if (-not (Test-Path -LiteralPath (Join-Path $source $required))) { throw "Incomplete checkout: $required is missing. Staging data is preserved at $stage." }
    }
    $State.Source = $source; $State.SourceRepository = $State.Repository; $State.SourceRef = $State.Ref
    Save-State $State
    return $source
}

function Update-SourceRequest($State, [hashtable]$Parameters) {
    $changed = $false
    foreach ($name in @('Repository', 'Ref')) {
        if ($Parameters.ContainsKey($name) -and $State.$name -ne $Parameters[$name]) { $State.$name = $Parameters[$name]; $changed = $true }
    }
    if ($changed) { Save-State $State }
    return $changed
}

function Update-Launcher($State) {
    $candidate = Join-Path $State.Source 'install.ps1'
    if (Test-Path -LiteralPath $script:Launcher) {
        if ((Get-FileHash -LiteralPath $script:Launcher).Hash -eq (Get-FileHash -LiteralPath $candidate).Hash) { return }
        $backup = Join-Path $script:StateRoot ('previous-launcher-' + (New-Id) + '.ps1')
        Move-Item -LiteralPath $script:Launcher -Destination $backup
    }
    Copy-Item -LiteralPath $candidate -Destination $script:Launcher
}

function Queue-Resume($State) {
    $key = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\RunOnce'
    $command = 'powershell.exe -NoProfile -ExecutionPolicy Bypass -File "' + $script:Launcher + '" -Action Recover'
    if ($command.Length -gt 260) { throw 'The automatic-resume command exceeds the Windows RunOnce limit. Restart, then rerun -Action Recover manually.' }
    $State.Status = 'restart-required'; $State.ResumeCommand = $command
    Save-State $State
    New-Item -Path $key -Force | Out-Null
    New-ItemProperty -Path $key -Name ('DevkitResume-' + $State.Id) -Value $command -PropertyType String -Force | Out-Null
    Write-Host 'Save your work and restart Windows. Setup resumes at your next login; -Action Recover also resumes manually.'
}

function Cancel-Resume($State) {
    $key = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\RunOnce'
    $name = 'DevkitResume-' + $State.Id
    $item = Get-ItemProperty -LiteralPath $key -Name $name -ErrorAction SilentlyContinue
    if ($item -and (Get-Field $item $name) -eq (Get-Field $State 'ResumeCommand')) { Remove-ItemProperty -LiteralPath $key -Name $name }
}

function Invoke-ElevatedScript([string]$Body) {
    $task = Join-Path $script:StateRoot ('admin-' + (New-Id))
    New-Item -ItemType Directory -Path $task | Out-Null
    $resultPath = Join-Path $task 'result.json'
    $scriptPath = Join-Path $task 'task.ps1'
    $bodyText = '$ErrorActionPreference = ''Stop''; try {' + "`n" + $Body + "`n" +
        '$result | ConvertTo-Json -Depth 24 | Set-Content -LiteralPath ' + (Quote-PowerShell $resultPath) + ' -Encoding UTF8; exit 0 } catch { $_ | Out-String | Set-Content -LiteralPath ' + (Quote-PowerShell (Join-Path $task 'error.txt')) + ' -Encoding UTF8; exit 1 }'
    [IO.File]::WriteAllText($scriptPath, $bodyText, [Text.UTF8Encoding]::new($true))
    $command = '& ' + (Quote-PowerShell $scriptPath)
    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($command))
    $process = Start-Process -FilePath 'powershell.exe' -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-EncodedCommand', $encoded) -Verb RunAs -Wait -PassThru
    if ($process.ExitCode -ne 0 -or -not (Test-Path -LiteralPath $resultPath)) { throw "Administrator operation failed. Details and scripts are preserved in $task." }
    return (Get-Content -LiteralPath $resultPath -Raw | ConvertFrom-Json)
}

function Get-WslMachineSnapshot {
    return Invoke-ElevatedScript @'
$features = @{}
foreach ($name in @('VirtualMachinePlatform', 'Microsoft-Windows-Subsystem-Linux', 'Microsoft-Hyper-V-All', 'HypervisorPlatform', 'Containers', 'Containers-DisposableClientVM')) {
    $feature = Get-WindowsOptionalFeature -Online -FeatureName $name -ErrorAction SilentlyContinue
    $features[$name] = if ($feature) { $feature.State.ToString() } else { 'Unavailable' }
}
$appx = @(Get-AppxPackage -AllUsers -Name MicrosoftCorporationII.WindowsSubsystemForLinux | Select-Object -ExpandProperty PackageFullName)
$consumers = @(Get-AppxPackage -AllUsers | Where-Object { $_.Name -match 'Ubuntu|Debian|KaliLinux|Pengwin|openSUSE|SUSELinux|Fedora.*WSL|ArchLinux|ArchWSL|AlpineWSL|WindowsSubsystemForAndroid|Docker|Podman|Rancher' } | Select-Object -ExpandProperty Name)
$programs = @(Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*', 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*' -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName -match 'Windows Subsystem for Linux|Docker|Podman|Rancher' } | Select-Object DisplayName, DisplayVersion)
$profiles = @(Get-CimInstance Win32_UserProfile | Where-Object { -not $_.Special } | Select-Object -ExpandProperty SID)
$result = @{ Features = $features; Appx = $appx; Consumers = $consumers; Programs = $programs; Profiles = $profiles }
'@
}

function Test-WslPresent($Snapshot) {
    if (Get-Field $Snapshot 'HadWorkingWsl' $false) { return $true }
    if (@($Snapshot.Appx).Count -gt 0 -or @($Snapshot.Programs | Where-Object { $_.DisplayName -match 'Windows Subsystem for Linux' }).Count -gt 0) { return $true }
    return (Get-Field $Snapshot.Features 'Microsoft-Windows-Subsystem-Linux') -in @('Enabled', 'EnablePending')
}

function Ensure-Wsl($State) {
    & wsl.exe --status *> $null
    if ($LASTEXITCODE -eq 0) {
        if (-not $State.PreWsl) {
            $State.PreWsl = [PSCustomObject]@{ HadWorkingWsl = $true; Appx = @(); Programs = @(); Features = [PSCustomObject]@{}; Profiles = @() }
            Save-State $State
        }
        return $true
    }
    if (-not $State.PreWsl) { $State.PreWsl = Get-WslMachineSnapshot; Save-State $State }
    $State.Step = 'install-wsl'; Save-State $State
    $result = Invoke-ElevatedScript @'
& wsl.exe --install --no-distribution --web-download
$code = $LASTEXITCODE
if ($code -notin @(0, 3010, 1641)) { throw "WSL install failed: $code" }
$result = @{ ExitCode = $code }
'@
    & wsl.exe --status *> $null
    if ($LASTEXITCODE -ne 0 -or $result.ExitCode -in @(3010, 1641)) { Queue-Resume $State; return $false }
    return $true
}

function Get-ScoopCandidates([string]$Package) {
    $pending = [Collections.Generic.Queue[string]]::new(); $pending.Enqueue($Package)
    $seen = @{}
    while ($pending.Count -gt 0) {
        $name = ($pending.Dequeue() -split '/')[-1]
        if ($seen.ContainsKey($name)) { continue }
        $seen[$name] = $true
        $manifest = Invoke-Native 'scoop' @('cat', $name) -Capture | ConvertFrom-Json
        foreach ($dep in @(Get-Field $manifest 'depends' @())) { if ($dep) { $pending.Enqueue($dep) } }
        $arch = Get-Field $manifest 'architecture'
        if ($arch) { foreach ($entry in $arch.PSObject.Properties) { foreach ($dep in @(Get-Field $entry.Value 'depends' @())) { if ($dep) { $pending.Enqueue($dep) } } } }
    }
    # Scoop can use 7zip to unpack otherwise undeclared archive dependencies.
    $seen['7zip'] = $true
    return @($seen.Keys)
}

function Resolve-PendingScoop($State) {
    $pending = $State.PendingScoop
    if (-not $pending) { return }
    foreach ($name in @($pending.Candidates)) {
        if ($name -in @($pending.Before)) { continue }
        $appPath = Join-Path $State.ScoopRoot ('apps/' + $name)
        if (-not (Test-Path -LiteralPath $appPath)) { continue }
        $complete = $false
        try {
            Get-Content -LiteralPath (Join-Path $appPath 'current/manifest.json') -Raw -Encoding UTF8 | ConvertFrom-Json | Out-Null
            $complete = Test-Path -LiteralPath (Join-Path $appPath 'current/install.json')
        } catch { }
        if (-not $complete) {
            $recovery = Join-Path $script:StateRoot ('recovery/' + $name + '-' + (New-Id))
            New-Item -ItemType Directory -Path (Split-Path $recovery -Parent) -Force | Out-Null
            $State.RecoveryFolders += $recovery; Save-State $State
            Move-Item -LiteralPath $appPath -Destination $recovery
            Write-Warning "Incomplete Scoop installation preserved at $recovery; the next install can retry."
        }
    }
    $current = @(Get-ScoopApps $State.ScoopRoot)
    $newApps = @($current | Where-Object { $_.Name -notin @($pending.Before) -and $_.Name -in @($pending.Candidates) })
    foreach ($app in $newApps) {
        if ($app.Name -notin @($State.OwnedApps | ForEach-Object { $_.Name })) { $State.OwnedApps = @($State.OwnedApps) + $app }
    }
    $afterPath = [Environment]::GetEnvironmentVariable('Path', 'User')
    $State.OwnedPath = @($State.OwnedPath) + @(Get-PathAdditions $pending.Path $afterPath | Where-Object { $_.StartsWith($State.ScoopRoot, [StringComparison]::OrdinalIgnoreCase) })
    $State.PendingScoop = $null
    Save-State $State
}

function Ensure-Scoop($State) {
    if (-not $State.ScoopRoot) {
        $State.ScoopRoot = Join-Path $script:StateRoot ('scoop-' + $State.Id)
        $State.Step = 'install-scoop'; Save-State $State
    }
    $scoopCommand = Join-Path $State.ScoopRoot 'shims/scoop.ps1'
    if (-not (Test-Path -LiteralPath $scoopCommand)) {
        if ($State.ScoopWasPresent) { throw 'The pre-existing Scoop installation is missing. Restore it before continuing.' }
        if (Test-Path -LiteralPath $State.ScoopRoot) {
            Move-Item -LiteralPath $State.ScoopRoot -Destination ($State.ScoopRoot + '-incomplete-' + (New-Id))
        }
        $downloadedInstaller = Get-Download 'https://get.scoop.sh'
        $installer = $downloadedInstaller + '.ps1'
        Copy-Item -LiteralPath $downloadedInstaller -Destination $installer
        $beforePath = [Environment]::GetEnvironmentVariable('Path', 'User')
        if (-not $State.ScoopInstallStarted) { $State.ScoopInstallPathBefore = $beforePath; $State.ScoopInstallStarted = $true; Save-State $State }
        # A subprocess keeps Scoop's `exit` from aborting this recoverable installer.
        $command = '& ' + (Quote-PowerShell $installer) + ' -ScoopDir ' + (Quote-PowerShell $State.ScoopRoot)
        $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($command))
        Invoke-Native 'powershell.exe' @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-EncodedCommand', $encoded)
        if (-not (Test-Path -LiteralPath $scoopCommand)) { throw 'Scoop did not install successfully.' }
    }
    $env:SCOOP = $State.ScoopRoot
    $env:Path = (Join-Path $State.ScoopRoot 'shims') + ';' + $env:Path
    if (-not $State.ScoopWasPresent -and $State.ScoopInstallPathBefore -ne $null) {
        $State.ManagerPath = @(Get-PathAdditions $State.ScoopInstallPathBefore ([Environment]::GetEnvironmentVariable('Path', 'User')) | Where-Object { $_.StartsWith($State.ScoopRoot, [StringComparison]::OrdinalIgnoreCase) })
        Save-State $State
    }
    Resolve-PendingScoop $State
    foreach ($package in @('7zip', 'git', 'curl', 'zip', 'unzip', 'ripgrep', 'coreutils')) {
        $apps = @(Get-ScoopApps $State.ScoopRoot)
        if ($package -in @($apps | ForEach-Object { $_.Name })) { continue }
        $State.PendingScoop = [PSCustomObject]@{ Package = $package; Before = @($apps | ForEach-Object { $_.Name }); Candidates = @(Get-ScoopCandidates $package); Path = [Environment]::GetEnvironmentVariable('Path', 'User') }
        Save-State $State
        try { Invoke-Native 'scoop' @('install', $package) } finally { Resolve-PendingScoop $State }
    }
}

function Get-RemovalPlan([object[]]$Apps, [object[]]$Owned) {
    $remove = @{}; $retained = @{}
    foreach ($app in $Apps) {
        $claim = @($Owned | Where-Object { $_.Name -eq $app.Name })
        if ($claim.Count -eq 1 -and $claim[0].Identity -eq $app.Identity) { $remove[$app.Name] = $true }
        else { $retained[$app.Name] = 'pre-existing, added later, or changed since setup' }
    }
    do {
        $changed = $false
        foreach ($app in $Apps) {
            if ($remove.ContainsKey($app.Name)) { continue }
            foreach ($dependency in @($app.Depends)) {
                if ($remove.ContainsKey($dependency)) { $remove.Remove($dependency); $retained[$dependency] = "needed by $($app.Name)"; $changed = $true }
            }
        }
    } while ($changed)
    return [PSCustomObject]@{ Remove = @($remove.Keys); Retain = $retained }
}

function Test-TarArchive([string]$Archive) {
    if (-not (Test-Path -LiteralPath $Archive) -or (Get-Item -LiteralPath $Archive).Length -lt 1024) { throw 'Archive is missing or too small; no removal is permitted.' }
    Invoke-Native 'tar.exe' @('-tf', $Archive) -Capture | Out-Null
    return (Get-FileHash -LiteralPath $Archive -Algorithm SHA256).Hash.ToLowerInvariant()
}

function New-ScoopArchive($State, [string]$Package) {
    $destination = Join-Path $State.Archive ('scoop-' + $Package + '-' + (New-Id) + '.tar')
    $paths = @('apps/' + $Package)
    if (Test-Path -LiteralPath (Join-Path $State.ScoopRoot ('persist/' + $Package))) { $paths += 'persist/' + $Package }
    Invoke-Native 'tar.exe' (@('-cf', $destination, '-C', $State.ScoopRoot) + $paths)
    $hash = Test-TarArchive $destination
    $State.Backups = @($State.Backups) + [PSCustomObject]@{ Path = $destination; SHA256 = $hash; Kind = 'scoop'; Package = $Package }
    Save-State $State
}

function Remove-OwnedScoop($State) {
    if (-not $State.ScoopRoot) { return }
    $managerArchive = Join-Path $State.Archive 'scoop-manager'
    if (-not (Test-Path -LiteralPath $State.ScoopRoot)) {
        if (-not $State.ScoopWasPresent -and (Test-Path -LiteralPath $managerArchive)) { Complete-ScoopManagerRemoval $State }
        return
    }
    $env:SCOOP = $State.ScoopRoot; $env:Path = (Join-Path $State.ScoopRoot 'shims') + ';' + $env:Path
    Resolve-PendingScoop $State
    $apps = @(Get-ScoopApps $State.ScoopRoot)
    $plan = Get-RemovalPlan $apps @($State.OwnedApps)
    foreach ($name in $plan.Retain.Keys) {
        if ($name -in @($State.OwnedApps | ForEach-Object { $_.Name })) { $State.Retained += "Scoop $name retained: $($plan.Retain[$name])." }
    }
    $remaining = @($plan.Remove)
    while ($remaining.Count -gt 0) {
        # Remove dependents first; never ask Scoop for recursive/purge removal.
        $name = @($remaining | Where-Object { $candidate = $_; @($apps | Where-Object { $_.Name -in $remaining -and $candidate -in @($_.Depends) }).Count -eq 0 } | Select-Object -First 1)
        if ($name.Count -eq 0) { throw 'Scoop dependency cycle prevents safe removal; all remaining files are preserved.' }
        $package = $name[0]
        New-ScoopArchive $State $package
        $State.Step = 'remove-scoop-' + $package; Save-State $State
        $pathBefore = [Environment]::GetEnvironmentVariable('Path', 'User')
        Invoke-Native 'scoop' @('uninstall', $package)
        # Scoop removes PATH entries itself; restore unrelated entries and only remove known additions.
        $ownedForPackage = @($State.OwnedPath | Where-Object { $_ -match ('[\\/]apps[\\/]' + [Regex]::Escape($package) + '[\\/]') })
        [Environment]::SetEnvironmentVariable('Path', (Remove-OwnedPathEntries $pathBefore $ownedForPackage), 'User')
        $State.RemovedApps = @($State.RemovedApps) + $package; Save-State $State
        $remaining = @($remaining | Where-Object { $_ -ne $package })
    }
    if ($State.ScoopWasPresent) { return }
    $remainingApps = @(Get-ScoopApps $State.ScoopRoot)
    $globalRoot = if ($env:SCOOP_GLOBAL) { $env:SCOOP_GLOBAL } else { Join-Path $env:ProgramData 'scoop' }
    $globalApps = @()
    if (Test-Path -LiteralPath (Join-Path $globalRoot 'apps')) { $globalApps = @(Get-ChildItem -LiteralPath (Join-Path $globalRoot 'apps') -Directory) }
    if ($remainingApps.Count -gt 0 -or $globalApps.Count -gt 0) { $State.Retained += 'Scoop manager retained because it still manages other apps.'; Save-State $State; return }
    $destination = Join-Path $State.Archive 'scoop-manager'
    $State.Step = 'archive-scoop-manager'; Save-State $State
    Move-Item -LiteralPath $State.ScoopRoot -Destination $destination
    Complete-ScoopManagerRemoval $State
}

function Complete-ScoopManagerRemoval($State) {
    if (-not $State.ManagerPathChange) {
        $before = Get-UserVariable 'Path'
        $State.ManagerPathChange = [PSCustomObject]@{ Before = $before; After = (Remove-OwnedPathEntries $before @($State.ManagerPath)); Applied = $false }
        Save-State $State
    }
    $change = $State.ManagerPathChange
    if (-not $change.Applied) {
        $current = Get-UserVariable 'Path'
        if ($current -eq $change.Before) { Set-UserVariable 'Path' $change.After; $change.Applied = $true }
        elseif ($current -eq $change.After) { $change.Applied = $true }
        else { $State.Retained += 'User PATH changed during interrupted Scoop removal; its remaining entries were preserved. Review them with -Action Status.' }
        Save-State $State
    }
    if ((Get-UserVariable 'SCOOP') -eq $State.ScoopRoot) { Set-UserVariable 'SCOOP' $State.OriginalUserScoop }
    $State.ScoopArchived = $true; Save-State $State
}

function Invoke-LinuxBackend($State, [string]$Command, [switch]$Capture) {
    $linuxSource = Invoke-Wsl @('--distribution', $State.Distribution, '--user', $State.LinuxUser, '--exec', 'wslpath', '-u', $State.Source) -Capture
    return Invoke-Wsl @('--distribution', $State.Distribution, '--user', $State.LinuxUser, '--exec', 'python3', "$linuxSource/lib/devkit.py", $Command) -Capture:$Capture
}

function Assert-NoLinuxProcesses($State) {
    $check = @'
import json,os
uid=os.getuid(); pids=[]
for p in os.listdir('/proc'):
    if not p.isdigit() or int(p)==os.getpid(): continue
    try:
        if os.stat('/proc/'+p).st_uid==uid: pids.append(p)
    except FileNotFoundError: pass
print(json.dumps(pids))
'@
    $pids = @(Invoke-Wsl @('--distribution', $State.Distribution, '--user', $State.LinuxUser, '--exec', 'python3', '-c', $check) -Capture | ConvertFrom-Json)
    if (@($pids).Count -gt 0) { throw "Close all processes in $($State.Distribution) before uninstalling (PIDs: $($pids -join ', '))." }
}

function Export-OwnedDistribution($State) {
    if ($State.Distribution -notin @(Get-Distributions)) { return }
    Assert-OwnedDistribution $State
    if ($State.LinuxInstallStarted) {
        if ($State.Source -and (Test-Path -LiteralPath (Join-Path $State.Source 'lib/devkit.py'))) { Invoke-LinuxBackend $State 'uninstall' }
        Assert-NoLinuxProcesses $State
    }
    Invoke-Wsl @('--terminate', $State.Distribution)
    $destination = Join-Path $State.Archive ('wsl-' + (New-Id) + '.tar')
    $State.Step = 'export-wsl'; Save-State $State
    Invoke-Wsl @('--export', $State.Distribution, $destination)
    $hash = Test-TarArchive $destination
    $State.Backups = @($State.Backups) + [PSCustomObject]@{ Path = $destination; SHA256 = $hash; Kind = 'wsl'; Distribution = $State.Distribution }
    $State.Step = 'unregister-wsl'; Save-State $State
    Invoke-Wsl @('--unregister', $State.Distribution)
    $State.DistroRemoved = $true; Save-State $State
}

function Get-WslRetentionReasons($State, $Current, [string[]]$Distros, [string]$CurrentSid) {
    $reasons = @()
    if (-not $State.PreWsl -or (Test-WslPresent $State.PreWsl)) { $reasons += 'WSL existed before setup, or its original state is unknown.' }
    if ($Distros.Count -gt 0) { $reasons += 'Other WSL distributions are registered.' }
    if (@($Current.Profiles | Where-Object { $_ -ne $CurrentSid }).Count -gt 0) { $reasons += 'Other Windows user profiles may use WSL.' }
    if (@($Current.Programs | Where-Object { $_.DisplayName -match 'Docker|Podman|Rancher' }).Count -gt 0) { $reasons += 'Installed virtualization software may use WSL.' }
    $consumers = @(Get-Field $Current 'Consumers' @())
    if ($consumers.Count -gt 0) { $reasons += ('Installed Linux or Android apps may use WSL or its virtualization platform: ' + ($consumers -join ', ') + '.') }
    foreach ($feature in @('Microsoft-Hyper-V-All', 'HypervisorPlatform', 'Containers', 'Containers-DisposableClientVM')) {
        if ((Get-Field $Current.Features $feature) -in @('Enabled', 'EnablePending')) { $reasons += "$feature may use the virtualization platform." }
    }
    return $reasons
}

function Remove-OwnedWslPlatform($State) {
    if (-not $State.PreWsl -or $State.WslRemoved) { return }
    if (Test-WslPresent $State.PreWsl) { return }
    $snapshot = Get-WslMachineSnapshot
    $sid = Get-CurrentSid
    $reasons = @(Get-WslRetentionReasons $State $snapshot @(Get-Distributions) $sid)
    if ($reasons.Count -gt 0) { $State.Retained += @($reasons | ForEach-Object { 'WSL retained: ' + $_ }); Save-State $State; return }
    $State.Step = 'remove-wsl-platform'; Save-State $State
    $features = @('Microsoft-Windows-Subsystem-Linux', 'VirtualMachinePlatform') | Where-Object { (Get-Field $State.PreWsl.Features $_) -eq 'Disabled' }
    $featureLiteral = '@(' + (($features | ForEach-Object { Quote-PowerShell $_ }) -join ',') + ')'
    $packagePresent = @($snapshot.Appx).Count -gt 0 -or @($snapshot.Programs | Where-Object { $_.DisplayName -match 'Windows Subsystem for Linux' }).Count -gt 0
    $removePackage = if ($packagePresent) { '$true' } else { '$false' }
    $result = Invoke-ElevatedScript ( "`$restart = `$false`nif ($removePackage) {`n" + @'
    & wsl.exe --uninstall
    if ($LASTEXITCODE -notin @(0, 3010, 1641)) { throw "WSL uninstall failed: $LASTEXITCODE" }
    $restart = $LASTEXITCODE -in @(3010, 1641)
}
'@ + "`nforeach (`$feature in $featureLiteral) {`n" + @'
    $state = Get-WindowsOptionalFeature -Online -FeatureName $feature
    if ($state.State -eq 'Enabled') {
        $change = Disable-WindowsOptionalFeature -Online -FeatureName $feature -NoRestart
        $restart = $restart -or $change.RestartNeeded
    }
    elseif ($state.State -eq 'DisablePending') { $restart = $true }
}
$result = @{ RestartNeeded = $restart }
'@ )
    $State.WslRemoved = $true; Save-State $State
    if ($result.RestartNeeded) { Write-Host 'Windows needs a restart to finish removing the WSL components installed by this setup.' }
}

function Invoke-Uninstall($State) {
    if (-not $State.Archive) {
        $State.Archive = Join-Path $script:ArchiveRoot ($State.Id + '-' + (Get-Date -Format 'yyyyMMddTHHmmss'))
        New-Item -ItemType Directory -Path $State.Archive -Force | Out-Null
    }
    $State.Status = 'uninstalling'; $State.Retained = @(); Save-State $State
    Cancel-Resume $State
    Export-OwnedDistribution $State
    if (Test-Path -LiteralPath $State.WslPath) {
        $target = Join-Path $State.Archive ('wsl-registration-files-' + (New-Id))
        Move-Item -LiteralPath $State.WslPath -Destination $target
    }
    Remove-OwnedScoop $State
    Remove-OwnedWslPlatform $State
    $State.Status = if ($State.Retained.Count -gt 0) { 'removed-with-retained-tools' } else { 'removed' }
    $State.Step = 'complete'; Save-State $State
    Copy-Item -LiteralPath $script:Journal -Destination (Join-Path $State.Archive ('journal-' + (New-Id) + '.jsonl'))
    Write-Host "Your Linux files and removed Scoop apps are archived at $($State.Archive)."
    Write-Host "Recovery state and source checkouts remain at $script:StateRoot."
    foreach ($reason in $State.Retained) { Write-Warning $reason }
}

function New-InstallationState([string]$Repo, [string]$Branch, [string]$DistroBase) {
    if ($DistroBase -notmatch '^[A-Za-z][A-Za-z0-9_-]{0,40}$') { throw 'Use a distribution name containing letters, digits, underscores, or hyphens.' }
    $id = (New-Id).Substring(0, 8)
    $root = Get-ScoopRoot
    return [PSCustomObject]@{
        Schema = 2; Id = $id; Status = 'installing'; Updated = ''; Step = 'snapshot'
        Repository = $Repo; Ref = $Branch; Source = $null; SourceRepository = $null; SourceRef = $null
        Distribution = "$DistroBase-$id"; LinuxUser = "devkit-$id"; LinuxUserCreated = $false; LinuxInstallStarted = $false; LinuxInstalled = $false
        WslPath = (Join-Path $script:StateRoot ('wsl/' + $id)); PreWsl = $null; DistroImportStarted = $false; DistroRegistration = $null; DistroRemoved = $false; WslRemoved = $false
        ScoopWasPresent = [bool]$root; ScoopRoot = $root; InitialApps = @(Get-ScoopApps $root); OwnedApps = @(); RemovedApps = @(); PendingScoop = $null
        OriginalUserScoop = [Environment]::GetEnvironmentVariable('SCOOP', 'User'); OriginalUserPath = [Environment]::GetEnvironmentVariable('Path', 'User')
        ScoopInstallStarted = $false; ScoopInstallPathBefore = $null; OwnedPath = @(); ManagerPath = @(); ManagerPathChange = $null; ScoopArchived = $false; RecoveryFolders = @()
        Archive = $null; Backups = @(); Retained = @(); ResumeCommand = $null
    }
}

function Invoke-Install($State, [switch]$RefreshSource) {
    $source = Get-Source $State -Force:$RefreshSource
    Update-Launcher $State
    if ($State.Status -eq 'ready') { Write-Host 'Already installed. Use -Action Shell to enter, or -Action Doctor to check it.'; return }
    $drive = [IO.DriveInfo]::new([IO.Path]::GetPathRoot($script:StateRoot))
    if ($drive.AvailableFreeSpace -lt 8GB) { throw 'At least 8 GiB of free disk space is required before installing. More is needed when exporting a large distro.' }
    $State.Status = 'installing'; Save-State $State
    Ensure-Scoop $State
    if (-not (Ensure-Wsl $State)) { return }
    if ($State.Distribution -notin @(Get-Distributions)) {
        $architecture = if ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64' -or $env:PROCESSOR_ARCHITEW6432 -eq 'ARM64') { 'arm64' } else { 'amd64' }
        if ($architecture -eq 'arm64') {
            $imageUrl = 'https://cdimage.ubuntu.com/releases/noble/release/ubuntu-24.04.5-wsl-arm64.wsl'
            $imageHash = '74478b5024d9047397ba79d17c27f73caf85ada4988f88cffc2892d65e6a806b'
        } else {
            $imageUrl = 'https://releases.ubuntu.com/noble/ubuntu-24.04.5-wsl-amd64.wsl'
            $imageHash = 'bb415d824822c4b878125729af451a5d18fb13d1cf5cbed9a7393ad64ac6039e'
        }
        $image = Get-Download $imageUrl $imageHash
        if ((Test-Path -LiteralPath $State.WslPath) -and @(Get-ChildItem -LiteralPath $State.WslPath -Force).Count -gt 0) {
            Move-Item -LiteralPath $State.WslPath -Destination ($State.WslPath + '-incomplete-' + (New-Id))
        }
        New-Item -ItemType Directory -Path $State.WslPath -Force | Out-Null
        $State.DistroImportStarted = $true; $State.Step = 'import-wsl'; Save-State $State
        Invoke-Wsl @('--import', $State.Distribution, $State.WslPath, $image, '--version', '2')
    }
    Assert-OwnedDistribution $State
    if ($State.LinuxUser -notmatch '^devkit-[a-f0-9]{8}$') { throw 'Unexpected Linux account in state file.' }
    & wsl.exe --distribution $State.Distribution --user root --exec id -u $State.LinuxUser *> $null
    if ($LASTEXITCODE -ne 0) { Invoke-Wsl @('--distribution', $State.Distribution, '--user', 'root', '--exec', 'useradd', '--create-home', '--shell', '/bin/bash', $State.LinuxUser) }
    $State.LinuxUserCreated = $true; Save-State $State
    Invoke-Wsl @('--distribution', $State.Distribution, '--user', 'root', '--exec', 'apt-get', 'update')
    $packages = @('git', 'curl', 'ca-certificates', 'zip', 'unzip', 'ripgrep', 'build-essential', 'cmake', 'ninja-build', 'gettext', 'pkg-config', 'python3', 'nodejs', 'npm', 'tar', 'gzip', 'bzip2', 'xz-utils', 'coreutils', 'findutils', 'grep', 'sed', 'gawk')
    Invoke-Wsl (@('--distribution', $State.Distribution, '--user', 'root', '--exec', 'apt-get', 'install', '-y') + $packages)
    $linuxState = Invoke-LinuxBackend $State 'status' -Capture | ConvertFrom-Json
    if ((Get-Field $linuxState 'status') -ne 'ready') {
        if ((Get-Field $linuxState 'status') -in @('installing', 'activating', 'failed', 'uninstalling', 'removing', 'cleanup-pending') -or @(Get-Field $linuxState 'pending_cleanup' @()).Count -gt 0) { Invoke-LinuxBackend $State 'recover' }
        $linuxSource = Invoke-Wsl @('--distribution', $State.Distribution, '--user', $State.LinuxUser, '--exec', 'wslpath', '-u', $source) -Capture
        $State.LinuxInstallStarted = $true; Save-State $State
        Invoke-Wsl @('--distribution', $State.Distribution, '--user', $State.LinuxUser, '--exec', 'bash', "$linuxSource/install.sh", '--no-system-packages')
    }
    Invoke-LinuxBackend $State 'doctor'
    $State.LinuxInstalled = $true; $State.Status = 'ready'; $State.Step = 'complete'; Save-State $State
    Cancel-Resume $State
    Write-Host "Installed. Enter with: & `"$script:Launcher`" -Action Shell"
    Write-Host "Uninstall with: & `"$script:Launcher`" -Action Uninstall"
}

function Invoke-DevkitMain([hashtable]$Parameters) {
    if (-not $env:LOCALAPPDATA -or -not $env:WINDIR) { throw 'Run install.ps1 in Windows PowerShell. Use install.sh on Linux/macOS.' }
    if ($PSVersionTable.PSVersion.Major -lt 5) { throw 'PowerShell 5.1 or newer is required.' }
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $script:StateRoot = Join-Path $env:LOCALAPPDATA 'Devkit'
    $script:ArchiveRoot = Join-Path $env:LOCALAPPDATA 'Devkit-archives'
    $script:Journal = Join-Path $script:StateRoot 'journal.jsonl'
    $script:Launcher = Join-Path $script:StateRoot 'devkit.ps1'
    $sid = Get-CurrentSid
    $mutex = [Threading.Mutex]::new($false, ('Global\Devkit-' + $sid))
    $locked = $false
    try {
        try { $locked = $mutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $locked = $true }
        if (-not $locked) { throw 'Another devkit operation is running in this Windows account.' }
        $state = Get-State
        if ($state -and (Get-Field $state 'Schema' 1) -lt 2) { throw 'This state predates ownership tracking. Keep the old installation intact and use its original archive-only uninstall before reinstalling.' }
        if ($Action -eq 'Status') { if ($state) { $state | ConvertTo-Json -Depth 32 } else { Write-Host 'Not installed.' }; return }
        if ($Action -eq 'Archives') { if (Test-Path -LiteralPath $script:ArchiveRoot) { Get-ChildItem -LiteralPath $script:ArchiveRoot -Directory | Select-Object -ExpandProperty FullName }; return }
        if ($Action -eq 'Shell') {
            if (-not $state -or $state.Status -ne 'ready') { throw 'Finish installation first.' }
            # Shell sessions are protected by Linux leases; release the Windows mutation mutex.
            $mutex.ReleaseMutex(); $locked = $false
            Invoke-LinuxBackend $state 'shell'
            return
        }
        if ($Action -eq 'Doctor') {
            if (-not $state) { throw 'Not installed.' }
            Write-Host "State: $($state.Status); current step: $($state.Step)"
            if ($state.Distribution -in @(Get-Distributions)) { Invoke-LinuxBackend $state 'doctor' }
            foreach ($backup in $state.Backups) {
                if (-not (Test-Path -LiteralPath $backup.Path) -or (Get-FileHash -LiteralPath $backup.Path -Algorithm SHA256).Hash -ne $backup.SHA256) { throw "Missing or modified archive: $($backup.Path)" }
            }
            foreach ($reason in $state.Retained) { Write-Warning $reason }
            Write-Host 'Recorded archives are intact.'
            return
        }
        $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
        $principal = [Security.Principal.WindowsPrincipal]::new($identity)
        if ($principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { throw 'Start in normal PowerShell. Setup requests elevation for WSL operations separately.' }
        Set-ExecutionPolicy -ExecutionPolicy Bypass -Scope Process -Force
        if ($Action -eq 'Uninstall' -or ($Action -eq 'Recover' -and $state -and $state.Status -in @('uninstalling', 'removed-with-retained-tools'))) {
            if (-not $state -or $state.Status -eq 'removed') { Write-Host 'Already removed; archives are preserved.'; return }
            Invoke-Uninstall $state; return
        }
        if ($Action -eq 'Recover' -and $state -and $state.Status -eq 'removed') { Write-Host 'Removal is complete. Use -Action Install for a new setup.'; return }
        if ($state -and $state.Status -eq 'uninstalling') { throw 'An uninstall is unfinished. Run -Action Recover before starting a new installation.' }
        if (-not $state -or $state.Status -in @('removed', 'removed-with-retained-tools')) {
            if ($state -and $state.Status -eq 'removed-with-retained-tools') {
                Write-Host 'The previous removal retained tools used elsewhere. They are treated as pre-existing in this new setup; the previous ownership journal remains archived.'
            }
            if (-not $state -and (Test-Path -LiteralPath $script:StateRoot) -and @(Get-ChildItem -LiteralPath $script:StateRoot -Force).Count -gt 0) { throw "$script:StateRoot contains unrelated files. Nothing was changed." }
            New-Item -ItemType Directory -Path $script:StateRoot -Force | Out-Null
            $state = New-InstallationState $Repository $Ref $Distribution
            Save-State $state
        }
        $changed = Update-SourceRequest $state $Parameters
        Invoke-Install $state -RefreshSource:$changed
    } finally {
        if ($locked) { $mutex.ReleaseMutex() }
        $mutex.Dispose()
    }
}

if (-not $LibraryOnly) { Invoke-DevkitMain $PSBoundParameters }
