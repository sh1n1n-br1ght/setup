# Tests for install.ps1 in a throwaway %LOCALAPPDATA%:
#   powershell -NoProfile -ExecutionPolicy Bypass -File tests\test_windows.ps1          config round trip
#   powershell -NoProfile -ExecutionPolicy Bypass -File tests\test_windows.ps1 -Full    real install + editor checks
# Both edit the user PATH of the running account (uninstall restores it, which the test checks);
# -Full also downloads everything. Run them on a disposable machine such as a CI runner.
# -Ref <pushed commit> runs the installer the way `irm ... | iex` does, downloading that commit.
param(
    [switch]$Full,
    [string]$Ref = $env:DEVKIT_TEST_REF,
    [string]$Repo = $(if ($env:DEVKIT_TEST_REPO) { $env:DEVKIT_TEST_REPO } else { 'sh1n1n-br1ght/setup' })
)

$ErrorActionPreference = 'Stop'
$repoDir = Split-Path -Parent $PSScriptRoot
$installer = Join-Path $repoDir 'install.ps1'
$script:Failures = 0

function Invoke-Installer([hashtable]$Arguments) {
    if ($Ref) {
        # Like `irm .../w | iex`: script text without a file, so it downloads the commit.
        $Arguments.Ref = $Ref
        $Arguments.Repo = $Repo
        & ([scriptblock]::Create([IO.File]::ReadAllText($installer))) @Arguments
    } else {
        & $installer @Arguments
    }
}

function Fail([string]$Message) {
    Write-Host "FAIL: $Message" -ForegroundColor Red
    $script:Failures++
}

function Get-TreeState([string]$Dir) {
    if (-not (Test-Path -LiteralPath $Dir)) { return @() }
    $base = (Resolve-Path -LiteralPath $Dir).Path
    return @(Get-ChildItem -LiteralPath $base -Recurse -Force | Sort-Object FullName | ForEach-Object {
        $relative = $_.FullName.Substring($base.Length)
        if ($_.PSIsContainer) { "$relative\" } else { "$relative $((Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash)" }
    } | Where-Object {
        # Visual Studio's compiler, which builds the parsers, keeps telemetry here. It belongs
        # to Visual Studio, and on a real machine this folder exists anyway.
        -not $_.StartsWith('\Microsoft\')
    })
}

function Get-Text([string]$File) { return [IO.File]::ReadAllText($File).Replace("`r`n", "`n") }

function Get-RawUserPath {
    $key = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Environment')
    try { return [string]$key.GetValue('Path', '', [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames) } finally { $key.Close() }
}

function Invoke-Nvim([string]$Nvim, [string]$Script) {
    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try { & $Nvim --headless -i NONE -c "lua dofile('$($Script.Replace('\', '/'))')" | Out-Host; return $LASTEXITCODE }
    finally { $ErrorActionPreference = $previous }
}

$sandbox = Join-Path ([IO.Path]::GetTempPath()) ('devkit-test-' + [Guid]::NewGuid().ToString('N'))
$appData = Join-Path $sandbox 'AppData\Local'
# The machine owner's own setup, which must come back unchanged.
New-Item -ItemType Directory -Path (Join-Path $appData 'nvim\lua'), (Join-Path $appData 'nvim-data\lazy\owner-plugin') -Force | Out-Null
[IO.File]::WriteAllText((Join-Path $appData 'nvim\init.lua'), "print('owner config')`n")
[IO.File]::WriteAllText((Join-Path $appData 'nvim\lua\owner.lua'), "return {}`n")
[IO.File]::WriteAllText((Join-Path $appData 'nvim-data\lazy\owner-plugin\init.lua'), "owner plugin`n")
$ownerFiles = Get-TreeState $appData
$userPath = Get-RawUserPath
$realAppData = $env:LOCALAPPDATA
$env:LOCALAPPDATA = $appData

try {
    $arguments = @{}
    if (-not $Full) { $arguments.ConfigOnly = $true }
    Invoke-Installer $arguments
    $config = Join-Path $appData 'nvim\init.lua'
    # Line endings differ between a Windows checkout and the downloaded archive.
    if ((Get-Text $config) -ne (Get-Text (Join-Path $repoDir 'config\nvim\init.lua'))) { Fail 'the Neovim config was not installed' }
    if (-not (Test-Path -LiteralPath (Join-Path $appData 'devkit\backup\nvim-config\lua\owner.lua'))) { Fail "the owner's config is not in the backup" }

    # Reinstalling keeps the backup and moves local edits aside.
    Add-Content -LiteralPath $config -Value '-- local edit'
    Invoke-Installer $arguments
    if (-not (Select-String -LiteralPath (Join-Path $appData 'devkit\state\previous-config\init.lua') -Pattern 'local edit' -Quiet)) { Fail 'reinstall dropped local edits' }

    if ($Full) {
        $nvim = (Get-ChildItem -LiteralPath (Join-Path $appData 'devkit\tools') -Recurse -Filter nvim.exe | Select-Object -First 1).FullName
        if ((Get-Command nvim).Source -ne $nvim) { Fail "this session does not run devkit's nvim (got $((Get-Command nvim).Source))" }
        if (-not ((Get-RawUserPath) -split ';' -contains (Split-Path -Parent $nvim))) { Fail 'nvim is not on the user PATH' }
        if ((Invoke-Nvim $nvim (Join-Path $repoDir 'tests\check_editor.lua')) -ne 0) { Fail 'editor checks failed' }
        $pinned = (Get-Content (Join-Path $repoDir 'tools.lock') | Where-Object { $_ -match "^python`t" } | Select-Object -First 1).Split("`t")[1]
        foreach ($name in 'python', 'python3') {
            $command = Get-Command $name -ErrorAction SilentlyContinue
            if (-not $command -or -not $command.Source.StartsWith((Join-Path $appData 'devkit'))) { Fail "$name is not devkit's Python (got $(if ($command) { $command.Source }))"; continue }
            $version = & $command.Source -c "import sys; print(sys.version_info[0], sys.version_info[1], sep='.')"
            if ($version -ne $pinned) { Fail "$name is Python $version, expected $pinned" }
        }
        if ((Invoke-Nvim $nvim (Join-Path $repoDir 'tests\nvim_completion.lua')) -ne 0) { Fail 'Python import completion test failed' }
        if ((Invoke-Nvim $nvim (Join-Path $repoDir 'tests\python_imports.lua')) -ne 0) { Fail "completion in import lists offers more than the module's members" }
        if ((Invoke-Nvim $nvim (Join-Path $repoDir 'tests\python_indent.lua')) -ne 0) { Fail 'Python brackets are not indented like black formats them' }
    }

    & $installer -Action Status
    & $installer -Action Uninstall
    $after = Get-TreeState $appData
    $diff = Compare-Object $ownerFiles $after
    if ($diff) { Fail ("files differ after uninstall:`n" + ($diff | Out-String)) }
    if ((Get-RawUserPath) -ne $userPath) { Fail "the user PATH was not restored:`n  before: $userPath`n  after:  $(Get-RawUserPath)" }
} catch {
    Fail ($_ | Out-String)
} finally {
    $env:LOCALAPPDATA = $realAppData
}

if ($script:Failures) {
    Write-Host "$($script:Failures) failure(s); sandbox kept at $sandbox"
    exit 1
}
Remove-Item -LiteralPath $sandbox -Recurse -Force
Write-Host "Windows tests passed ($(if ($Full) { 'full install' } else { 'config round trip' }), PowerShell $($PSVersionTable.PSVersion))"
