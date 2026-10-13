# Installs sh1n1n-br1ght's Neovim (NvChad) setup natively on Windows: no WSL, no admin.
#
#   irm https://sh1n1n-br1ght.github.io/setup/w | iex      install or update
#   irm https://sh1n1n-br1ght.github.io/setup/x | iex      uninstall
#
# Existing Neovim configs (%LOCALAPPDATA%\nvim and nvim-data) are moved into
# %LOCALAPPDATA%\devkit\backup and put back by uninstall. Tools are pinned downloads
# (tools.lock) kept in %LOCALAPPDATA%\devkit; nvim, uv, pyrefly and rg are added to the
# user PATH. tmux has no native Windows build, so only Neovim is set up here.
# Works in Windows PowerShell 5.1 and PowerShell 7.
[CmdletBinding()]
param(
    [ValidateSet('Install', 'Uninstall', 'Status')]
    [string]$Action = 'Install',
    [string]$Ref = 'main',
    [string]$Repo = 'sh1n1n-br1ght/setup',
    [switch]$ConfigOnly
)

$ErrorActionPreference = 'Stop'
# Invoke-WebRequest is many times faster without its progress bar.
$ProgressPreference = 'SilentlyContinue'
$script:Warnings = 0
$script:Targets = @('nvim-config', 'nvim-data')
# An explicit -Ref or -Repo installs that version, even when run from a local checkout.
$script:SourceRequested = $PSBoundParameters.ContainsKey('Ref') -or $PSBoundParameters.ContainsKey('Repo')

function Write-Step([string]$Message) { Write-Host "`n==> $Message" }
function Write-Note([string]$Message) { Write-Host "  $Message" }
function Write-Problem([string]$Message) {
    $script:Warnings++
    Write-Host "warning: $Message" -ForegroundColor Yellow
}

function Initialize-Paths {
    if (-not $env:LOCALAPPDATA) { throw 'This installer is for Windows. On Linux, macOS or BSD use install.sh.' }
    $script:Root = Join-Path $env:LOCALAPPDATA 'devkit'
    $script:Tools = Join-Path $script:Root 'tools'
    $script:Backup = Join-Path $script:Root 'backup'
    $script:State = Join-Path $script:Root 'state'
    $script:SourceCopy = Join-Path $script:Root 'source'
    $configBase = if ($env:XDG_CONFIG_HOME) { $env:XDG_CONFIG_HOME } else { $env:LOCALAPPDATA }
    $dataBase = if ($env:XDG_DATA_HOME) { $env:XDG_DATA_HOME } else { $env:LOCALAPPDATA }
    $script:DefaultPaths = @{
        'nvim-config' = Join-Path $configBase 'nvim'
        'nvim-data'   = Join-Path $dataBase 'nvim-data'
    }
}

function Get-TargetPath([string]$Name) {
    # The location recorded at install time wins, in case XDG variables changed since.
    $recorded = Join-Path $script:State "$Name.path"
    if (Test-Path -LiteralPath $recorded) { return [IO.File]::ReadAllText($recorded) }
    return $script:DefaultPaths[$Name]
}

function Get-Platform {
    $arch = $null
    try { $arch = [Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString() } catch { }
    if (-not $arch) { $arch = if ($env:PROCESSOR_ARCHITEW6432) { $env:PROCESSOR_ARCHITEW6432 } else { $env:PROCESSOR_ARCHITECTURE } }
    switch -Regex ($arch) {
        '^(X64|AMD64)$' { return 'windows-x86_64' }
        '^(Arm64|ARM64)$' { return 'windows-arm64' }
        default { throw "Neovim has no Windows build for this processor ($arch)." }
    }
}

function Read-Lock([string]$Path) {
    foreach ($line in [IO.File]::ReadAllLines($Path)) {
        if (-not $line -or $line.StartsWith('#')) { continue }
        $fields = $line.Split("`t")
        if ($fields.Count -ge 6) {
            [pscustomobject]@{ Name = $fields[0]; Version = $fields[1]; Platform = $fields[2]; Sha256 = $fields[4]; Url = $fields[5] }
        }
    }
}

function Get-Pin([string]$Name) {
    return $script:Lock | Where-Object { $_.Name -eq $Name -and ($_.Platform -eq $script:Platform -or $_.Platform -eq 'any') } | Select-Object -First 1
}

function Save-Url([string]$Url, [string]$File) {
    for ($attempt = 1; ; $attempt++) {
        try {
            Invoke-WebRequest -UseBasicParsing -Uri $Url -OutFile $File -TimeoutSec 600
            return
        } catch {
            if ($attempt -ge 3) { throw "Could not download $Url ($($_.Exception.Message))" }
            Start-Sleep -Seconds (2 * $attempt)
        }
    }
}

# Downloads, verifies and unzips a pinned tool; returns its directory (or $null if not pinned).
function Install-Pinned([string]$Name) {
    $pin = Get-Pin $Name
    if (-not $pin) { return $null }
    $dir = Join-Path $script:Tools "$Name-$($pin.Version)"
    if (Test-Path -LiteralPath (Join-Path $dir '.complete')) { return $dir }
    Write-Note "downloading $Name $($pin.Version)"
    $file = Join-Path $script:Work ([IO.Path]::GetFileName(([Uri]$pin.Url).AbsolutePath))
    Save-Url $pin.Url $file
    $hash = (Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash
    if ($hash -ne $pin.Sha256) { throw "Checksum mismatch for $($pin.Url)" }
    if (Test-Path -LiteralPath $dir) { Remove-Item -LiteralPath $dir -Recurse -Force }
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    [IO.Compression.ZipFile]::ExtractToDirectory($file, $dir)
    New-Item -ItemType File -Path (Join-Path $dir '.complete') | Out-Null
    return $dir
}

function Find-File([string]$Dir, [string]$Name) {
    $found = Get-ChildItem -LiteralPath $Dir -Recurse -Filter $Name -File -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($found) { return $found.FullName }
    return $null
}

function Invoke-Quiet([string]$File, [string[]]$Arguments) {
    # Native stderr must not become a terminating error in Windows PowerShell 5.1.
    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        & $File @Arguments *>> $script:Log
        return $LASTEXITCODE
    } finally { $ErrorActionPreference = $previous }
}

# The last line a native command prints, or $null if it fails.
function Get-Output([string]$File, [string[]]$Arguments) {
    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $lines = @(& $File @Arguments 2>$null)
        if ($LASTEXITCODE -eq 0 -and $lines.Count) { return ([string]$lines[-1]).Trim() }
    } finally { $ErrorActionPreference = $previous }
    return $null
}

function Get-Version([string]$File) {
    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    # Even `nvim --version` creates its state directory, which must not happen before the
    # owner's nvim-data is backed up.
    $state = $env:XDG_STATE_HOME
    $env:XDG_STATE_HOME = $script:Work
    try { $text = (& $File --version 2>$null | Select-Object -First 1) } catch { $text = '' }
    finally { $ErrorActionPreference = $previous; $env:XDG_STATE_HOME = $state }
    if ("$text" -match '(\d+)\.(\d+)(\.(\d+))?') { return [version]("$($Matches[1]).$($Matches[2]).$(if ($Matches[4]) { $Matches[4] } else { 0 })") }
    return $null
}

function Move-Path([string]$From, [string]$To) {
    $parent = Split-Path -Parent $To
    if (-not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
    if ([IO.Path]::GetPathRoot($From) -eq [IO.Path]::GetPathRoot($To)) {
        Move-Item -LiteralPath $From -Destination $To
    } else {
        # Directories cannot be moved across drives.
        Copy-Item -LiteralPath $From -Destination $To -Recurse -Force
        Remove-Item -LiteralPath $From -Recurse -Force
    }
}

# Move the owner's copy into the backup and mark the path as ours. The marker is written
# right after the move, so an interrupted run can be resumed or undone.
function Use-Target([string]$Name) {
    $path = Get-TargetPath $Name
    [IO.File]::WriteAllText((Join-Path $script:State "$Name.path"), $path)
    $marker = Join-Path $script:State "$Name.ours"
    if (Test-Path -LiteralPath $marker) { return }
    $saved = Join-Path $script:Backup $Name
    if (Test-Path -LiteralPath $path) {
        if (Test-Path -LiteralPath $saved) { throw "Both $path and its backup $saved exist; move one of them away and run this again." }
        Move-Path $path $saved
        Write-Note "backed up $path"
    }
    New-Item -ItemType File -Path $marker -Force | Out-Null
}

function Restore-Target([string]$Name) {
    $path = Get-TargetPath $Name
    $marker = Join-Path $script:State "$Name.ours"
    if (Test-Path -LiteralPath $marker) {
        if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Recurse -Force }
        Remove-Item -LiteralPath $marker -Force
    }
    $saved = Join-Path $script:Backup $Name
    if (-not (Test-Path -LiteralPath $saved)) { return }
    if (Test-Path -LiteralPath $path) {
        Write-Problem "$path appeared while devkit was installed, so the original stays at $saved"
        return
    }
    Move-Path $saved $path
    Write-Note "restored $path"
}

# The raw user PATH (with %VARIABLES% unexpanded), its registry type and whether it exists.
function Get-UserPath {
    $path = @{ Exists = $false; Value = ''; Kind = [Microsoft.Win32.RegistryValueKind]::ExpandString }
    $key = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Environment')
    if (-not $key) { return $path }
    try {
        if ($key.GetValueNames() -contains 'Path') {
            $path.Exists = $true
            $path.Value = [string]$key.GetValue('Path', '', [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
            $path.Kind = $key.GetValueKind('Path')
        }
    } finally { $key.Close() }
    return $path
}

function Set-UserPath([string]$Value, $Kind, [switch]$Delete) {
    $key = [Microsoft.Win32.Registry]::CurrentUser.CreateSubKey('Environment')
    try {
        if ($Delete) { $key.DeleteValue('Path', $false) } else { $key.SetValue('Path', $Value, $Kind) }
    } finally { $key.Close() }
    # Setting any user variable through .NET broadcasts the change to Explorer and new terminals.
    [Environment]::SetEnvironmentVariable('DEVKIT_PATH_CHANGED', '1', 'User')
    [Environment]::SetEnvironmentVariable('DEVKIT_PATH_CHANGED', $null, 'User')
}

# Entries are added to and removed from the raw value, so everything else in it
# (order, %VARIABLES%, empty entries, a trailing ';') stays exactly as it was.
function Add-ToPath([string[]]$Dirs) {
    $path = Get-UserPath
    $current = @($path.Value -split ';')
    $added = @($Dirs | Where-Object { $current -notcontains $_ })
    if ($added.Count) {
        $value = ($added -join ';') + $(if ($path.Value) { ';' + $path.Value } else { '' })
        Set-UserPath $value $path.Kind
        if (-not $path.Exists) { New-Item -ItemType File -Path (Join-Path $script:State 'path-created') -Force | Out-Null }
        Add-Content -LiteralPath (Join-Path $script:State 'path-entries') -Value $added -Encoding UTF8
        foreach ($dir in $added) { Write-Note "added $dir to your user PATH" }
    }
    # This PowerShell window can use the commands right away.
    $env:Path = ((@($Dirs) + @($env:Path -split ';' | Where-Object { $_ -and $Dirs -notcontains $_ })) -join ';')
}

function Remove-FromPath([switch]$Quiet) {
    $record = Join-Path $script:State 'path-entries'
    $created = Join-Path $script:State 'path-created'
    if (-not (Test-Path -LiteralPath $record)) { return }
    $ours = @(Get-Content -LiteralPath $record -Encoding UTF8 | Where-Object { $_ })
    $path = Get-UserPath
    $parts = @($path.Value -split ';')
    $kept = @($parts | Where-Object { $ours -notcontains $_ })
    if ($path.Exists -and $kept.Count -ne $parts.Count) {
        $value = $kept -join ';'
        if (-not $value -and (Test-Path -LiteralPath $created)) { Set-UserPath -Delete } else { Set-UserPath $value $path.Kind }
        if (-not $Quiet) { Write-Note 'removed devkit from your user PATH' }
    }
    $env:Path = (@($env:Path -split ';' | Where-Object { $_ -and $ours -notcontains $_ }) -join ';')
    Remove-Item -LiteralPath $record -Force
    if (Test-Path -LiteralPath $created) { Remove-Item -LiteralPath $created -Force }
}

function Write-DevkitCommand {
    # `devkit uninstall`, `devkit status` and `devkit update` from cmd or PowerShell. The
    # call and `exit` share one line because cmd rereads batch files, and uninstall deletes this one.
    $bin = Join-Path $script:Root 'bin'
    New-Item -ItemType Directory -Path $bin -Force | Out-Null
    $command = "@echo off`r`n" +
        "set `"action=Install`"`r`n" +
        "if /i `"%~1`"==`"uninstall`" set `"action=Uninstall`"`r`n" +
        "if /i `"%~1`"==`"status`" set `"action=Status`"`r`n" +
        "powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"%~dp0..\source\install.ps1`" -Action %action% & exit /b`r`n"
    [IO.File]::WriteAllText((Join-Path $bin 'devkit.cmd'), $command)
    return $bin
}

function Get-Source {
    # Set when an earlier installer downloaded this source and handed over to it.
    if ($env:DEVKIT_SOURCE_READY -and (Test-Path -LiteralPath (Join-Path $script:SourceCopy 'install.ps1'))) { return }
    $local = $null
    if ($PSScriptRoot -and -not $script:SourceRequested -and (Test-Path -LiteralPath (Join-Path $PSScriptRoot 'config\nvim\init.lua'))) {
        $local = (Resolve-Path -LiteralPath $PSScriptRoot).Path
    }
    if (-not $local -or $local -eq $script:SourceCopy) {
        $url = "https://github.com/$Repo/archive/$Ref.zip"
        Write-Note "downloading $url"
        $zip = Join-Path $script:Work 'source.zip'
        Save-Url $url $zip
        $unpacked = Join-Path $script:Work 'source'
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        [IO.Compression.ZipFile]::ExtractToDirectory($zip, $unpacked)
        $local = (Get-ChildItem -LiteralPath $unpacked -Directory | Select-Object -First 1).FullName
        if (-not (Test-Path -LiteralPath (Join-Path $local 'config\nvim\init.lua'))) { throw "$url does not contain config\nvim" }
    }
    # A private copy lets uninstall work offline.
    $next = "$($script:SourceCopy).new"
    if (Test-Path -LiteralPath $next) { Remove-Item -LiteralPath $next -Recurse -Force }
    New-Item -ItemType Directory -Path $next | Out-Null
    foreach ($item in @('install.ps1', 'tools.lock', 'lib', 'config')) {
        Copy-Item -LiteralPath (Join-Path $local $item) -Destination $next -Recurse
    }
    if (Test-Path -LiteralPath $script:SourceCopy) { Remove-Item -LiteralPath $script:SourceCopy -Recurse -Force }
    Move-Item -LiteralPath $next -Destination $script:SourceCopy
}

function Test-Compiler {
    foreach ($name in @('cl', 'gcc', 'clang', 'zig', 'cc')) {
        if (Get-Command $name -ErrorAction SilentlyContinue) { return $true }
    }
    # tree-sitter finds Visual Studio's C++ tools without a developer prompt.
    if (-not ${env:ProgramFiles(x86)}) { return $false }
    $vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
    if (Test-Path -LiteralPath $vswhere) {
        $found = & $vswhere -latest -products '*' -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath 2>$null
        if ($found) { return $true }
    }
    return $false
}

# Returns the directories to put on PATH; helper directories go into $script:Helpers.
function Install-Tools {
    Write-Step "Installing tools into $($script:Tools)"
    New-Item -ItemType Directory -Path $script:Tools -Force | Out-Null
    $script:Helpers = @()
    $userDirs = @()

    $nvimDir = Install-Pinned 'nvim'
    $script:Nvim = Find-File $nvimDir 'nvim.exe'
    $version = Get-Version $script:Nvim
    if (-not $version -or $version -lt [version]'0.12.0') { throw 'The downloaded Neovim does not run on this machine.' }
    $userDirs += Split-Path -Parent $script:Nvim

    if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
        $gitDir = Install-Pinned 'git'
        if (-not $gitDir) { throw 'git is required for Neovim plugins; install Git for Windows and run this again.' }
        $script:Helpers += Join-Path $gitDir 'cmd'
    }

    $tsDir = Install-Pinned 'tree-sitter'
    if ($tsDir) { $script:Helpers += Split-Path -Parent (Find-File $tsDir 'tree-sitter.exe') }

    $node = Get-Command node -ErrorAction SilentlyContinue
    $nodeVersion = if ($node) { Get-Version $node.Source } else { $null }
    if (-not $nodeVersion -or $nodeVersion -lt [version]'18.0.0' -or -not (Get-Command npm -ErrorAction SilentlyContinue)) {
        $nodeDir = Install-Pinned 'node'
        if ($nodeDir) { $script:Helpers += Split-Path -Parent (Find-File $nodeDir 'node.exe') }
        else { Write-Problem 'no Node.js 18+, so the HTML/CSS language servers are skipped' }
    }

    $rgDir = Install-Pinned 'ripgrep'
    if ($rgDir) { $userDirs += Split-Path -Parent (Find-File $rgDir 'rg.exe') }

    $uvDir = Install-Pinned 'uv'
    if ($uvDir) {
        $uv = Find-File $uvDir 'uv.exe'
        $userDirs += Split-Path -Parent $uv
        # Everything uv writes stays under the tools directory.
        $saved = @{}
        $uvEnv = @{
            UV_TOOL_DIR = Join-Path $script:Tools 'uv-tools'; UV_TOOL_BIN_DIR = Join-Path $script:Tools 'uv-bin'
            UV_PYTHON_INSTALL_DIR = Join-Path $script:Tools 'python'; UV_PYTHON_BIN_DIR = Join-Path $script:Tools 'python-bin'
            UV_CACHE_DIR = Join-Path $script:Tools 'uv-cache'; UV_NO_CONFIG = '1'
        }
        foreach ($name in $uvEnv.Keys) { $saved[$name] = [Environment]::GetEnvironmentVariable($name); [Environment]::SetEnvironmentVariable($name, $uvEnv[$name]) }
        try {
            # The newest Python release of the pinned line that uv knows, from its standalone builds.
            # --no-bin keeps uv from adding commands elsewhere; its folder goes on the user PATH instead.
            $pythonPin = Get-Pin 'python'
            Write-Note "installing Python $($pythonPin.Version)"
            $python = $null
            if ((Invoke-Quiet $uv @('python', 'install', '--no-bin', $pythonPin.Version)) -eq 0) {
                $python = Get-Output $uv @('python', 'find', '--managed-python', '--no-project', $pythonPin.Version)
            }
            if ($python -and (Test-Path -LiteralPath $python)) {
                $pythonDir = Split-Path -Parent $python
                # The build has no python3.exe, and without one the Microsoft Store alias answers instead.
                $python3 = Join-Path $pythonDir 'python3.exe'
                if (-not (Test-Path -LiteralPath $python3)) { New-Item -ItemType HardLink -Path $python3 -Value $python | Out-Null }
                $userDirs += $pythonDir
            } else {
                $python = $null
                Write-Problem "could not install Python $($pythonPin.Version) with uv (see $($script:Log))"
            }
            $pyrefly = Get-Pin 'pyrefly'
            Write-Note "installing pyrefly $($pyrefly.Version)"
            $toolArguments = @('tool', 'install', '--force')
            if ($python) { $toolArguments += @('--python', $python) }
            $code = Invoke-Quiet $uv ($toolArguments + "pyrefly==$($pyrefly.Version)")
        } finally { foreach ($name in $uvEnv.Keys) { [Environment]::SetEnvironmentVariable($name, $saved[$name]) } }
        if ($code -eq 0) { $userDirs += $uvEnv.UV_TOOL_BIN_DIR } else { Write-Problem "could not install pyrefly (see $($script:Log))" }
    } else {
        Write-Problem 'no uv build for this machine, so Python and pyrefly are skipped'
    }

    if (-not (Test-Compiler)) {
        $env:DEVKIT_NO_COMPILER = '1'
        Write-Problem 'no C compiler, so syntax parsers cannot be built; install Visual Studio Build Tools (C++ workload) or MinGW-w64 gcc, then run :TSInstall in Neovim'
    }

    # Helpers stay visible to Neovim only: its sysinit.vim (loaded before the config) adds them.
    # npm (used by Mason) keeps its cache here instead of in the owner's npm-cache.
    $vimDir = Join-Path (Split-Path -Parent (Split-Path -Parent $script:Nvim)) 'share\nvim'
    $entries = @($script:Helpers + $userDirs | ForEach-Object { $_.Replace("'", "''") })
    $npmCache = (Join-Path $script:Root 'cache\npm').Replace("'", "''")
    $sysinit = "`" Added by sh1n1n-br1ght/setup: tools for plugins, visible to Neovim only.`r`n" +
        "let `$PATH = '" + ($entries -join ';') + "' . ';' . `$PATH`r`n" +
        "let `$npm_config_cache = '$npmCache'`r`n"
    [IO.File]::WriteAllText((Join-Path $vimDir 'sysinit.vim'), $sysinit)

    # Remove tool versions left behind by updates.
    foreach ($dir in Get-ChildItem -LiteralPath $script:Tools -Directory) {
        if (-not (Test-Path -LiteralPath (Join-Path $dir.FullName '.complete'))) { continue }
        if (-not ($script:Lock | Where-Object { "$($_.Name)-$($_.Version)" -eq $dir.Name })) { Remove-Item -LiteralPath $dir.FullName -Recurse -Force }
    }
    return $userDirs
}

function Install-Configs {
    Write-Step "Installing the Neovim config (an existing one is moved to $($script:Backup))"
    foreach ($name in $script:Targets) { Use-Target $name }
    $config = Get-TargetPath 'nvim-config'
    if (Test-Path -LiteralPath $config) {
        $previous = Join-Path $script:State 'previous-config'
        if (Test-Path -LiteralPath $previous) { Remove-Item -LiteralPath $previous -Recurse -Force }
        Move-Item -LiteralPath $config -Destination $previous
    }
    New-Item -ItemType Directory -Path (Split-Path -Parent $config) -Force | Out-Null
    Copy-Item -LiteralPath (Join-Path $script:SourceCopy 'config\nvim') -Destination $config -Recurse
    Write-Note "Neovim config: $config"
}

function Assert-NoLegacy {
    if (Test-Path -LiteralPath (Join-Path $script:Root 'journal.jsonl')) {
        $old = Join-Path $script:Root 'devkit.ps1'
        throw ("$($script:Root) holds an installation from the previous (WSL-based) version of this script. " +
            "Remove it first with: powershell -NoProfile -ExecutionPolicy Bypass -File `"$old`" -Action Uninstall " +
            "and then delete $($script:Root) and $($script:Root)-archives.")
    }
}

function Invoke-Install {
    Assert-NoLegacy
    $script:Platform = Get-Platform
    New-Item -ItemType Directory -Path $script:State -Force | Out-Null
    # The tree-sitter CLI leaves an empty lock directory behind; uninstall removes it if it is new.
    $created = Join-Path $script:State 'created-dirs'
    if (-not (Test-Path -LiteralPath $created)) {
        $treeSitter = Join-Path $env:LOCALAPPDATA 'tree-sitter'
        [IO.File]::WriteAllLines($created, [string[]]@(@($treeSitter, (Join-Path $treeSitter 'lock')) | Where-Object { -not (Test-Path -LiteralPath $_) }))
    }
    $script:Log = Join-Path $script:State 'install.log'
    Set-Content -LiteralPath $script:Log -Value $null
    if (-not $env:DEVKIT_SOURCE_READY) { Write-Step "Preparing $Repo ($Ref) for $($script:Platform)" }
    Get-Source
    # Continue with the installer that came with this source, so an update runs its new steps
    # rather than those of the older copy that started it. A script block runs even where the
    # execution policy blocks script files, as with irm | iex.
    $downloaded = Join-Path $script:SourceCopy 'install.ps1'
    if (-not $env:DEVKIT_SOURCE_READY -and -not ($PSCommandPath -and
            (Get-FileHash -LiteralPath $PSCommandPath).Hash -eq (Get-FileHash -LiteralPath $downloaded).Hash)) {
        Remove-Item -LiteralPath $script:Work -Recurse -Force -ErrorAction SilentlyContinue
        $env:DEVKIT_SOURCE_READY = '1'
        try { & ([scriptblock]::Create([IO.File]::ReadAllText($downloaded))) -Action Install -Ref $Ref -Repo $Repo -ConfigOnly:$ConfigOnly }
        finally { Remove-Item Env:DEVKIT_SOURCE_READY -ErrorAction SilentlyContinue }
        return
    }
    $script:Lock = @(Read-Lock (Join-Path $script:SourceCopy 'tools.lock'))
    $userDirs = @()
    if (-not $ConfigOnly) { $userDirs = @(Install-Tools) }
    Install-Configs
    Write-Step 'Adding devkit to your user PATH'
    # Entries from an earlier version are replaced, not piled up.
    Remove-FromPath -Quiet
    Add-ToPath (@(Write-DevkitCommand) + $userDirs)
    if ($script:Nvim) {
        # The system PATH comes before the user PATH in new terminals.
        $machinePath = @([string][Environment]::GetEnvironmentVariable('Path', 'Machine') -split ';')
        $other = Get-Command nvim -All -ErrorAction SilentlyContinue |
            Where-Object { $_.Source -ne $script:Nvim -and $machinePath -contains (Split-Path -Parent $_.Source) } | Select-Object -First 1
        if ($other) { Write-Problem "another Neovim ($($other.Source)) is on the system PATH and wins in new terminals; this setup's Neovim is $($script:Nvim)" }
    }
    [IO.File]::WriteAllText((Join-Path $script:State 'installed'), "repo=$Repo`r`nref=$Ref`r`nplatform=$($script:Platform)`r`nconfig_only=$([bool]$ConfigOnly)`r`ninstalled=$((Get-Date).ToUniversalTime().ToString('s'))Z`r`n")
    if (-not $ConfigOnly) {
        Write-Step 'Installing Neovim plugins, language servers and parsers (a few minutes)'
        $env:DEVKIT_BOOTSTRAP = Join-Path $script:SourceCopy 'lib\bootstrap-nvim.lua'
        $previous = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        try { & $script:Nvim --headless --cmd 'lua dofile(vim.env.DEVKIT_BOOTSTRAP)' >> $script:Log; $code = $LASTEXITCODE }
        finally { $ErrorActionPreference = $previous }
        if ($code -ne 0) { throw "Neovim plugins were not installed (details in $($script:Log)). Run the installer again to retry, or uninstall." }
    }
    Write-Host ''
    Write-Host 'Done. Start Neovim with: nvim   (new terminals pick up the PATH change; this one already has it)'
    if (Test-Path -LiteralPath $script:Backup) { Write-Host "Your previous setup is saved in $($script:Backup); 'devkit uninstall' puts it back." }
    if ($script:Warnings) { Write-Host "$($script:Warnings) warning(s) above; full log: $($script:Log)" }
}

function Invoke-Uninstall {
    if (-not (Test-Path -LiteralPath $script:Root)) { Write-Host "devkit is not installed (no $($script:Root))."; return }
    Assert-NoLegacy
    Write-Step 'Removing devkit and restoring the previous setup'
    Remove-FromPath
    foreach ($name in $script:Targets) { Restore-Target $name }
    if ((Test-Path -LiteralPath $script:Backup) -and @(Get-ChildItem -LiteralPath $script:Backup -Force).Count) {
        foreach ($item in Get-ChildItem -LiteralPath $script:Root -Force | Where-Object { $_.FullName -ne $script:Backup }) {
            Remove-Item -LiteralPath $item.FullName -Recurse -Force
        }
        Write-Host "Kept $($script:Backup) because something could not be restored (see the warnings above)."
    } else {
        $createdFile = Join-Path $script:State 'created-dirs'
        $created = if (Test-Path -LiteralPath $createdFile) { @([IO.File]::ReadAllLines($createdFile) | Where-Object { $_ }) } else { @() }
        try { Remove-Item -LiteralPath $script:Root -Recurse -Force }
        catch { throw "Could not delete $($script:Root); close Neovim and run uninstall again. ($($_.Exception.Message))" }
        foreach ($dir in ($created | Sort-Object Length -Descending)) {
            if ((Test-Path -LiteralPath $dir) -and -not @(Get-ChildItem -LiteralPath $dir -Force).Count) { Remove-Item -LiteralPath $dir -Force }
        }
    }
    Write-Host 'devkit is removed. Open a new terminal so PATH no longer includes it.'
}

function Show-Status {
    $installed = Join-Path $script:State 'installed'
    if (-not (Test-Path -LiteralPath $installed)) {
        Write-Host 'devkit is not installed.'
        if (Test-Path -LiteralPath $script:Root) { Write-Host "An interrupted installation left files in $($script:Root); run install again or uninstall." }
        return
    }
    Write-Host "devkit is installed in $($script:Root)"
    Get-Content -LiteralPath $installed | ForEach-Object { Write-Host "  $_" }
    foreach ($name in $script:Targets) {
        if (Test-Path -LiteralPath (Join-Path $script:Backup $name)) { Write-Host "  backed-up original: $(Get-TargetPath $name)" }
    }
}

function Invoke-Devkit {
    if ($PSVersionTable.PSVersion.Major -ge 6 -and -not $IsWindows) { throw 'This installer is for Windows. On Linux, macOS or BSD use install.sh.' }
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    Initialize-Paths
    $mutex = New-Object Threading.Mutex($false, 'Local\devkit-sh1n1n-br1ght-setup')
    $locked = $false
    $script:Work = $null
    try {
        try { $locked = $mutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $locked = $true }
        if (-not $locked) { throw 'Another devkit install or uninstall is running.' }
        $script:Work = Join-Path ([IO.Path]::GetTempPath()) ('devkit-' + [Guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:Work | Out-Null
        switch ($Action) {
            'Install' { Invoke-Install }
            'Uninstall' { Invoke-Uninstall }
            'Status' { Show-Status }
        }
    } finally {
        if ($script:Work -and (Test-Path -LiteralPath $script:Work)) { Remove-Item -LiteralPath $script:Work -Recurse -Force -ErrorAction SilentlyContinue }
        if ($locked) { $mutex.ReleaseMutex() }
        $mutex.Dispose()
    }
}

Invoke-Devkit
