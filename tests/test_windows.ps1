$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot '../install.ps1') -LibraryOnly
$script:Fixture = Join-Path ([IO.Path]::GetTempPath()) ('devkit-windows-tests-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $script:Fixture | Out-Null
$script:Passed = 0
$script:Failed = 0

function Assert-True($Value, [string]$Message = 'Assertion failed') { if (-not $Value) { throw $Message } }
function Assert-Equal($Actual, $Expected) { if (($Actual | ConvertTo-Json -Depth 30 -Compress) -cne ($Expected | ConvertTo-Json -Depth 30 -Compress)) { throw "Expected [$Expected], got [$Actual]." } }
function Assert-Throws([scriptblock]$Body, [string]$Pattern = '') {
    try { & $Body } catch { if ($Pattern -and $_.Exception.Message -notmatch $Pattern) { throw }; return }
    throw 'Expected an exception.'
}
function Test-Case([string]$Name, [scriptblock]$Body) {
    $script:StateRoot = Join-Path $script:Fixture (New-Id)
    $script:ArchiveRoot = Join-Path $script:StateRoot 'archives'
    $script:Journal = Join-Path $script:StateRoot 'journal.jsonl'
    $script:Launcher = Join-Path $script:StateRoot 'devkit.ps1'
    New-Item -ItemType Directory -Path $script:StateRoot | Out-Null
    $oldScoop = $env:SCOOP; $oldPath = $env:Path
    try { & $Body; $script:Passed++; Write-Host "PASS $Name" }
    catch { $script:Failed++; Write-Host "FAIL $Name`: $_" -ForegroundColor Red; Write-Host $_.ScriptStackTrace }
    finally { $env:SCOOP = $oldScoop; $env:Path = $oldPath }
}
function New-TestState {
    function Get-ScoopRoot { return $null }
    $state = New-InstallationState 'https://github.com/sh1n1n-br1ght/setup.git' 'main' 'Devkit-Ubuntu'
    $state.Archive = Join-Path $script:StateRoot 'archive'
    New-Item -ItemType Directory -Path $state.Archive | Out-Null
    return $state
}
function New-TestSource([string]$Target) {
    foreach ($file in @('install.sh', 'install.ps1', 'lib/devkit.py', 'tools.lock.json', 'config/nvim/init.lua')) {
        $path = Join-Path $Target $file
        New-Item -ItemType Directory -Path (Split-Path $path -Parent) -Force | Out-Null
        [IO.File]::WriteAllText($path, 'fixture')
    }
}
function New-App([string]$Name, [string]$Identity = 'original', [string[]]$Depends = @()) {
    return [PSCustomObject]@{ Name = $Name; Identity = $Identity; Version = '1'; Depends = $Depends }
}

Test-Case 'journal recovers the last complete state after a torn write' {
    $state = New-TestState; Save-State $state
    [IO.File]::AppendAllText($script:Journal, '{"Id":"broken')
    Assert-Equal (Get-State).Id $state.Id
    $state.Status = 'ready'; Save-State $state
    Assert-Equal (Get-State).Status 'ready'
}

Test-Case 'invalid journals do not silently become a new installation' {
    [IO.File]::WriteAllText($script:Journal, 'invalid')
    Assert-Throws { Get-State } 'No valid state'
}

Test-Case 'PATH ownership preserves unrelated and duplicate entries' {
    $added = @(Get-PathAdditions 'C:\Owner;C:\Tools' 'C:\Devkit;C:\Owner;C:\Tools')
    Assert-Equal $added @('C:\Devkit')
    Assert-Equal (Remove-OwnedPathEntries 'C:\Later;C:\Devkit;C:\Owner;C:\Devkit;C:\Tools' $added) 'C:\Later;C:\Owner;C:\Devkit;C:\Tools'
}

Test-Case 'corrected repository and ref are persisted on retry' {
    $state = New-TestState; Save-State $state
    Assert-True (Update-SourceRequest $state @{ Repository = 'https://github.com/owner/fixed.git'; Ref = 'stable' })
    Assert-Equal (Get-State).Repository 'https://github.com/owner/fixed.git'
    Assert-Equal (Get-State).Ref 'stable'
    Assert-True (-not (Update-SourceRequest $state @{}))
}

Test-Case 'incomplete checkout cannot replace the last complete source' {
    $state = New-TestState
    $oldSource = Join-Path $script:StateRoot 'good'; New-TestSource $oldSource
    $state.Source = $oldSource; $state.SourceRepository = $state.Repository; $state.SourceRef = $state.Ref
    Save-State $state
    function Get-Download { return 'mock.zip' }
    function Expand-SafeZip([string]$Archive, [string]$Destination) {
        New-Item -ItemType Directory -Path (Join-Path $Destination 'checkout') -Force | Out-Null
        [IO.File]::WriteAllText((Join-Path $Destination 'checkout/install.sh'), 'partial')
    }
    Assert-Throws { Get-Source $state -Force } 'Incomplete checkout'
    Assert-Equal (Get-State).Source $oldSource
    Assert-True (Test-Path -LiteralPath (Join-Path $oldSource 'lib/devkit.py'))
}

Test-Case 'a failed download is retained and the verified retry is reusable' {
    $script:DownloadAttempts = 0
    function Invoke-WebRequest {
        param([switch]$UseBasicParsing, $Uri, $OutFile, $TimeoutSec)
        $script:DownloadAttempts++
        [IO.File]::WriteAllText($OutFile, $(if ($script:DownloadAttempts -eq 1) { 'partial' } else { 'complete' }))
        if ($script:DownloadAttempts -eq 1) { throw 'Network interrupted' }
    }
    function Start-Sleep { param($Seconds) }
    $hashPath = Join-Path $script:StateRoot 'expected'; [IO.File]::WriteAllText($hashPath, 'complete')
    $hash = (Get-FileHash -LiteralPath $hashPath -Algorithm SHA256).Hash
    $download = Get-Download 'https://example.test/file' $hash
    Assert-Equal $script:DownloadAttempts 2
    Assert-Equal (Get-Download 'https://example.test/file' $hash) $download
    Assert-Equal $script:DownloadAttempts 2
    Assert-Equal @(Get-ChildItem -LiteralPath (Join-Path $script:StateRoot 'downloads')).Count 2
}

Test-Case 'zip traversal cannot escape the staging directory' {
    Add-Type -AssemblyName System.IO.Compression
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $path = Join-Path $script:StateRoot 'bad.zip'
    $zip = [IO.Compression.ZipFile]::Open($path, [IO.Compression.ZipArchiveMode]::Create)
    $entry = $zip.CreateEntry('../owner.txt'); $writer = [IO.StreamWriter]::new($entry.Open()); $writer.Write('bad'); $writer.Dispose(); $zip.Dispose()
    Assert-Throws { Expand-SafeZip $path (Join-Path $script:StateRoot 'expanded') } 'Unsafe'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $script:StateRoot 'owner.txt')))
}

Test-Case 'later apps retain their transitive owned dependencies' {
    $git = New-App 'git' 'git-v1' @('7zip'); $zip = New-App '7zip'; $new = New-App 'owner-tool' 'new' @('git'); $curl = New-App 'curl'
    $plan = Get-RemovalPlan @($git, $zip, $new, $curl) @($git, $zip, $curl)
    Assert-Equal @($plan.Remove) @('curl')
    Assert-True ($plan.Retain.ContainsKey('git'))
    Assert-True ($plan.Retain.ContainsKey('7zip'))
}

Test-Case 'a tool updated after installation is preserved' {
    $plan = Get-RemovalPlan @((New-App 'git' 'upgraded')) @((New-App 'git' 'original'))
    Assert-Equal @($plan.Remove).Count 0
    Assert-True ($plan.Retain.ContainsKey('git'))
}

Test-Case 'unknown or replaced WSL registrations are never removed' {
    $state = New-TestState; $state.DistroImportStarted = $true; $state.DistroRegistration = 'original'
    function Get-WslRegistration { return [PSCustomObject]@{ Id = 'replacement'; BasePath = $state.WslPath } }
    Assert-Throws { Assert-OwnedDistribution $state } 'ownership'
}

Test-Case 'active Linux sessions stop uninstall before export or unregister' {
    $state = New-TestState; $state.DistroImportStarted = $true; $state.LinuxUserCreated = $true; $state.LinuxInstallStarted = $true
    $state.Source = Join-Path $script:StateRoot 'source'; New-TestSource $state.Source
    function Get-Distributions { return @($state.Distribution) }
    function Assert-OwnedDistribution { }
    function Invoke-LinuxBackend { throw 'Live devkit sessions remain.' }
    function Invoke-Wsl { throw 'No WSL mutation should have run.' }
    Assert-Throws { Export-OwnedDistribution $state } 'Live devkit sessions'
}

Test-Case 'failed WSL export never unregisters the distribution' {
    $state = New-TestState; $state.DistroImportStarted = $true
    $script:WslCalls = @()
    function Get-Distributions { return @($state.Distribution) }
    function Assert-OwnedDistribution { }
    function Invoke-Wsl([string[]]$WslArguments) {
        $script:WslCalls += $WslArguments[0]
        if ($WslArguments[0] -eq '--export') { throw 'Disk full' }
    }
    Assert-Throws { Export-OwnedDistribution $state } 'Disk full'
    Assert-True ('--unregister' -notin $script:WslCalls)
}

Test-Case 'unverified WSL export never permits unregister' {
    $state = New-TestState; $state.DistroImportStarted = $true
    $script:WslCalls = @()
    function Get-Distributions { return @($state.Distribution) }
    function Assert-OwnedDistribution { }
    function Invoke-Wsl([string[]]$WslArguments) { $script:WslCalls += $WslArguments[0] }
    function Test-TarArchive { throw 'Corrupt export' }
    Assert-Throws { Export-OwnedDistribution $state } 'Corrupt export'
    Assert-True ('--unregister' -notin $script:WslCalls)
}

Test-Case 'retry makes a new verified export before attempting unregister again' {
    $state = New-TestState; $state.DistroImportStarted = $true
    $script:WslCalls = @(); $script:UnregisterAttempts = 0
    function Get-Distributions { return @($state.Distribution) }
    function Assert-OwnedDistribution { }
    function Invoke-Wsl([string[]]$WslArguments) {
        $script:WslCalls += $WslArguments[0]
        if ($WslArguments[0] -eq '--export') { [IO.File]::WriteAllText($WslArguments[2], 'mock archive') }
        if ($WslArguments[0] -eq '--unregister') {
            Assert-Equal (Get-State).Step 'unregister-wsl'
            Assert-True ((Get-State).Backups.Count -gt 0)
            $script:UnregisterAttempts++
            if ($script:UnregisterAttempts -eq 1) { throw 'Simulated interruption' }
        }
    }
    function Test-TarArchive { return ('a' * 64) }
    Assert-Throws { Export-OwnedDistribution $state } 'Simulated interruption'
    Export-OwnedDistribution $state
    Assert-Equal @($state.Backups).Count 2
    Assert-True ($state.Backups[0].Path -ne $state.Backups[1].Path)
    Assert-Equal @($script:WslCalls | Where-Object { $_ -eq '--export' }).Count 2
    Assert-True $state.DistroRemoved
}

Test-Case 'a removed distribution is not unregistered twice' {
    $state = New-TestState; $state.DistroRemoved = $true
    function Get-Distributions { return @('Owners-Ubuntu') }
    function Invoke-Wsl { throw 'Owner distribution must not be touched.' }
    Export-OwnedDistribution $state
}

Test-Case 'Scoop archive failure stops package removal' {
    $state = New-TestState; $state.ScoopRoot = Join-Path $script:StateRoot 'scoop'; $state.ScoopWasPresent = $true
    New-Item -ItemType Directory -Path $state.ScoopRoot | Out-Null
    $app = New-App 'git'; $state.OwnedApps = @($app)
    function Get-ScoopApps { return @($app) }
    function New-ScoopArchive { throw 'Archive failed' }
    function Invoke-Native { throw 'No package should be removed.' }
    Assert-Throws { Remove-OwnedScoop $state } 'Archive failed'
}

Test-Case 'Scoop-manager move interrupted before PATH cleanup can resume' {
    $state = New-TestState; $state.ScoopRoot = Join-Path $script:StateRoot 'already-moved'; $state.ScoopWasPresent = $false
    New-Item -ItemType Directory -Path (Join-Path $state.Archive 'scoop-manager') | Out-Null
    $script:CompletedManagerRemoval = $false
    function Complete-ScoopManagerRemoval { $script:CompletedManagerRemoval = $true }
    Remove-OwnedScoop $state
    Assert-True $script:CompletedManagerRemoval
}

Test-Case 'empty Linux process output is safe but another process blocks removal' {
    $state = New-TestState
    function Invoke-Wsl { return '[]' }
    Assert-NoLinuxProcesses $state
    function Invoke-Wsl { return '[123]' }
    Assert-Throws { Assert-NoLinuxProcesses $state } 'Close all processes'
}

Test-Case 'Windows PowerShell non-enumerated empty JSON arrays do not block cleanup' {
    $state = New-TestState
    function Invoke-Wsl { return '[]' }
    function ConvertFrom-Json {
        param([Parameter(ValueFromPipeline = $true)]$InputObject)
        process { Write-Output -NoEnumerate @() }
    }
    Assert-NoLinuxProcesses $state
}

Test-Case 'PATH cleanup interrupted after its registry write never removes a duplicate twice' {
    $state = New-TestState; $state.ScoopRoot = 'C:\Devkit\scoop'; $state.ManagerPath = @('C:\Devkit\scoop\shims')
    $state.ManagerPathChange = [PSCustomObject]@{ Before = 'C:\Devkit\scoop\shims;C:\Owner;C:\Devkit\scoop\shims'; After = 'C:\Owner;C:\Devkit\scoop\shims'; Applied = $false }
    $script:UserVariables = @{ Path = $state.ManagerPathChange.After; SCOOP = $state.ScoopRoot }
    function Get-UserVariable([string]$Name) { return $script:UserVariables[$Name] }
    function Set-UserVariable([string]$Name, $Value) { $script:UserVariables[$Name] = $Value }
    Complete-ScoopManagerRemoval $state
    Assert-Equal $script:UserVariables.Path 'C:\Owner;C:\Devkit\scoop\shims'
    Assert-True $state.ManagerPathChange.Applied
    Complete-ScoopManagerRemoval $state
    Assert-Equal $script:UserVariables.Path 'C:\Owner;C:\Devkit\scoop\shims'
}

Test-Case 'PATH edits made during interrupted cleanup are not overwritten' {
    $state = New-TestState; $state.ScoopRoot = 'C:\Devkit\scoop'
    $state.ManagerPathChange = [PSCustomObject]@{ Before = 'C:\Devkit;C:\Owner'; After = 'C:\Owner'; Applied = $false }
    $script:UserVariables = @{ Path = 'C:\New;C:\Owner'; SCOOP = 'C:\OwnerScoop' }
    function Get-UserVariable([string]$Name) { return $script:UserVariables[$Name] }
    function Set-UserVariable { throw 'No owner variable should be changed.' }
    Complete-ScoopManagerRemoval $state
    Assert-Equal $script:UserVariables.Path 'C:\New;C:\Owner'
    Assert-True (@($state.Retained).Count -gt 0)
}

Test-Case 'incomplete newly started Scoop package files are preserved for retry' {
    $state = New-TestState; $state.ScoopRoot = Join-Path $script:StateRoot 'scoop'
    $partial = Join-Path $state.ScoopRoot 'apps/git'
    New-Item -ItemType Directory -Path $partial -Force | Out-Null
    [IO.File]::WriteAllText((Join-Path $partial 'valuable.txt'), 'keep this')
    $state.PendingScoop = [PSCustomObject]@{ Before = @(); Candidates = @('git'); Package = 'git'; Path = '' }
    Resolve-PendingScoop $state
    Assert-Equal @($state.RecoveryFolders).Count 1
    Assert-Equal ([IO.File]::ReadAllText((Join-Path $state.RecoveryFolders[0] 'valuable.txt'))) 'keep this'
    Assert-True (-not (Test-Path -LiteralPath $partial))
    Assert-True ($null -eq $state.PendingScoop)
}

Test-Case 'pre-existing WSL, other users, distros and consumers are retained' {
    $state = New-TestState
    $snapshot = [PSCustomObject]@{ Appx = @(); Programs = @(); Features = [PSCustomObject]@{ 'Microsoft-Windows-Subsystem-Linux' = 'Disabled' }; Profiles = @('owner') }
    $state.PreWsl = $snapshot
    Assert-Equal @(Get-WslRetentionReasons $state $snapshot @() 'owner').Count 0
    Assert-True (@(Get-WslRetentionReasons $state $snapshot @('Owner-Ubuntu') 'owner').Count -gt 0)
    $snapshot.Profiles = @('owner', 'other')
    Assert-True (@(Get-WslRetentionReasons $state $snapshot @() 'owner').Count -gt 0)
    $snapshot.Profiles = @('owner'); $snapshot.Programs = @([PSCustomObject]@{ DisplayName = 'Docker Desktop' })
    Assert-True (@(Get-WslRetentionReasons $state $snapshot @() 'owner').Count -gt 0)
    $snapshot.Programs = @(); $snapshot.Appx = @('Existing-WSL')
    Assert-True (@(Get-WslRetentionReasons $state $snapshot @() 'owner').Count -gt 0)
}

Test-Case 'working pre-existing WSL never requires an elevated inventory or reinstall' {
    $state = New-TestState
    function wsl.exe { $global:LASTEXITCODE = 0 }
    function Get-WslMachineSnapshot { throw 'No administrator inventory should be needed.' }
    Assert-True (Ensure-Wsl $state)
    Assert-True (Test-WslPresent $state.PreWsl)
    Assert-True (Get-State).PreWsl.HadWorkingWsl
}

Test-Case 'unregistered Linux apps, Android and the hypervisor protect WSL infrastructure' {
    $state = New-TestState
    $state.PreWsl = [PSCustomObject]@{ Appx = @(); Programs = @(); Features = [PSCustomObject]@{}; Profiles = @('owner') }
    $current = [PSCustomObject]@{ Appx = @(); Consumers = @('CanonicalGroupLimited.Ubuntu'); Programs = @(); Features = [PSCustomObject]@{}; Profiles = @('owner') }
    Assert-True (@(Get-WslRetentionReasons $state $current @() 'owner').Count -gt 0)
    $current.Consumers = @('MicrosoftCorporationII.WindowsSubsystemForAndroid')
    Assert-True (@(Get-WslRetentionReasons $state $current @() 'owner').Count -gt 0)
    $current.Consumers = @(); $current.Features = [PSCustomObject]@{ HypervisorPlatform = 'Enabled' }
    Assert-True (@(Get-WslRetentionReasons $state $current @() 'owner').Count -gt 0)
}

Test-Case 'WSL platform retry disables only originally disabled features after its package was removed' {
    $state = New-TestState
    $state.PreWsl = [PSCustomObject]@{ Appx = @(); Programs = @(); Features = [PSCustomObject]@{ 'Microsoft-Windows-Subsystem-Linux' = 'Disabled'; VirtualMachinePlatform = 'Enabled' }; Profiles = @('owner') }
    $current = [PSCustomObject]@{ Appx = @(); Programs = @(); Features = [PSCustomObject]@{ 'Microsoft-Windows-Subsystem-Linux' = 'Enabled'; VirtualMachinePlatform = 'Enabled' }; Profiles = @('owner') }
    function Get-WslMachineSnapshot { return $current }
    function Get-CurrentSid { return 'owner' }
    function Get-Distributions { return @() }
    function Invoke-ElevatedScript([string]$Body) {
        $tokens = $null; $errors = $null
        [Management.Automation.Language.Parser]::ParseInput($Body, [ref]$tokens, [ref]$errors) | Out-Null
        Assert-Equal @($errors).Count 0
        Assert-True ($Body.Contains('if ($false)'))
        Assert-True ($Body.Contains("@('Microsoft-Windows-Subsystem-Linux')"))
        Assert-True (-not $Body.Contains("'VirtualMachinePlatform'"))
        return [PSCustomObject]@{ RestartNeeded = $false }
    }
    Remove-OwnedWslPlatform $state
    Assert-True $state.WslRemoved
}

Test-Case 'an interrupted uninstall resumes without moving restored owner files' {
    $state = New-TestState; Save-State $state
    $script:CleanupAttempts = 0; $script:LinuxExports = 0
    function Cancel-Resume { }
    function Export-OwnedDistribution($State) { if (-not $State.DistroRemoved) { $script:LinuxExports++; $State.DistroRemoved = $true; Save-State $State } }
    function Remove-OwnedScoop {
        $script:CleanupAttempts++
        if ($script:CleanupAttempts -eq 1) { throw 'Interrupted cleanup' }
    }
    function Remove-OwnedWslPlatform { }
    Assert-Throws { Invoke-Uninstall $state } 'Interrupted cleanup'
    Assert-Equal (Get-State).Status 'uninstalling'
    $retry = Get-State; Invoke-Uninstall $retry
    Assert-Equal (Get-State).Status 'removed'
    Assert-Equal $script:LinuxExports 1
}

Write-Host "$script:Passed passed, $script:Failed failed. Retained fixtures: $script:Fixture"
if ($script:Failed -gt 0) { exit 1 }
