#Requires -Version 5.1
<#
.SYNOPSIS
    Bootstrap script for Java + Angular training laptops.

.DESCRIPTION
    Installs a pinned set of developer tools (JDK, Maven, Node.js, VSCode,
    pgAdmin) via winget, installs Angular CLI globally via npm, configures
    JAVA_HOME and M2_HOME system-wide, and optionally creates a T: drive
    alias pointing at a training workspace folder (persisted across reboots
    via a scheduled task).

.PARAMETER WorkspacePath
    Folder to use as the training workspace and as the target for subst T:.
    Default: C:\TrainingWorkspace

.PARAMETER SkipTDrive
    Skip creating the T: drive alias and the logon scheduled task.

.NOTES
    Requires Administrator privileges. Self-elevates if launched non-elevated.
    Versions are pinned in the $Versions hashtable below - update yearly.
#>
[CmdletBinding()]
param(
    [string]$WorkspacePath = 'C:\TrainingWorkspace',
    [switch]$SkipTDrive
)

$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# Self-elevate if not running as Administrator
# ---------------------------------------------------------------------------
$currentPrincipal = [Security.Principal.WindowsPrincipal]::new(
    [Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $currentPrincipal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host 'Re-launching as Administrator...' -ForegroundColor Yellow
    $relaunchArgs = "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`""
    if ($PSBoundParameters.ContainsKey('WorkspacePath')) {
        $relaunchArgs += " -WorkspacePath `"$WorkspacePath`""
    }
    if ($SkipTDrive) {
        $relaunchArgs += ' -SkipTDrive'
    }
    Start-Process powershell -Verb RunAs -ArgumentList $relaunchArgs
    exit
}

# ===========================================================================
# PINNED VERSIONS - review and update yearly before training.
# To list available versions for a winget package:
#     winget show --id <PackageId> --versions
# ===========================================================================
$Versions = @{
    Jdk        = '21.0.5+11'    # winget: EclipseAdoptium.Temurin.21.JDK
    Node       = '22.11.0'      # winget: OpenJS.NodeJS.LTS
    Maven      = '3.9.9'        # winget: Apache.Maven
    Vscode     = '1.96.2'       # winget: Microsoft.VisualStudioCode
    PgAdmin    = '8.13'         # winget: PostgreSQL.pgAdmin
    AngularCli = '18.2.12'      # npm:    @angular/cli
}

$Packages = @(
    @{ Id = 'EclipseAdoptium.Temurin.21.JDK'; Version = $Versions.Jdk;     Name = 'Eclipse Temurin JDK 21' }
    @{ Id = 'OpenJS.NodeJS.LTS';              Version = $Versions.Node;    Name = 'Node.js LTS' }
    @{ Id = 'Apache.Maven';                   Version = $Versions.Maven;   Name = 'Apache Maven' }
    @{ Id = 'Microsoft.VisualStudioCode';     Version = $Versions.Vscode;  Name = 'Visual Studio Code' }
    @{ Id = 'PostgreSQL.pgAdmin';             Version = $Versions.PgAdmin; Name = 'pgAdmin 4' }
)
# ===========================================================================

$logFile = Join-Path $env:TEMP "training-setup-$(Get-Date -Format 'yyyyMMdd-HHmmss').log"
Start-Transcript -Path $logFile -Force | Out-Null

function Write-Step {
    param([string]$Message)
    Write-Host ''
    Write-Host "==> $Message" -ForegroundColor Cyan
}

function Install-WingetPackage {
    param(
        [string]$Id,
        [string]$Version,
        [string]$Name
    )
    Write-Step "Installing $Name ($Id $Version)"
    & winget install `
        --id $Id `
        --version $Version `
        --exact `
        --silent `
        --accept-source-agreements `
        --accept-package-agreements
    # winget exit codes worth tolerating:
    #   0           = success
    #  -1978335189  = already installed at this version (UPDATE_NOT_APPLICABLE)
    #  -1978335212  = no applicable upgrade found
    if ($LASTEXITCODE -ne 0 -and
        $LASTEXITCODE -ne -1978335189 -and
        $LASTEXITCODE -ne -1978335212) {
        throw "winget install failed for $Id (exit code $LASTEXITCODE)"
    }
}

function Update-SessionPath {
    $env:Path = [Environment]::GetEnvironmentVariable('Path', 'Machine') + ';' +
                [Environment]::GetEnvironmentVariable('Path', 'User')
}

# 1. Verify winget is available
Write-Step 'Verifying winget'
if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
    throw 'winget is not available. Install "App Installer" from the Microsoft Store and retry.'
}

# 2. Install all winget packages
foreach ($pkg in $Packages) {
    Install-WingetPackage @pkg
}

# 3. Refresh PATH so freshly-installed tools are callable in this session
Update-SessionPath

# 4. Set JAVA_HOME and M2_HOME (machine-wide)
Write-Step 'Setting JAVA_HOME and M2_HOME (machine-wide)'

$javaHome = Get-ChildItem 'C:\Program Files\Eclipse Adoptium' -Directory -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -like 'jdk-21*' } |
            Select-Object -First 1 -ExpandProperty FullName
if (-not $javaHome) {
    throw 'Could not locate the Temurin JDK 21 installation directory under C:\Program Files\Eclipse Adoptium.'
}
[Environment]::SetEnvironmentVariable('JAVA_HOME', $javaHome, 'Machine')
Write-Host "JAVA_HOME = $javaHome"

$mavenHome = Get-ChildItem 'C:\Program Files\' -Directory -ErrorAction SilentlyContinue |
             Where-Object { $_.Name -like 'apache-maven-*' } |
             Select-Object -First 1 -ExpandProperty FullName
if (-not $mavenHome) {
    $mavenHome = Get-ChildItem 'C:\ProgramData\chocolatey\lib\maven\apache-maven-*' -Directory -ErrorAction SilentlyContinue |
                 Select-Object -First 1 -ExpandProperty FullName
}
if ($mavenHome) {
    [Environment]::SetEnvironmentVariable('M2_HOME', $mavenHome, 'Machine')
    [Environment]::SetEnvironmentVariable('MAVEN_HOME', $mavenHome, 'Machine')
    Write-Host "M2_HOME    = $mavenHome"
} else {
    Write-Warning 'Could not locate the Maven installation directory; M2_HOME not set.'
}

# 5. Install Angular CLI globally via npm (pinned)
Write-Step "Installing Angular CLI $($Versions.AngularCli) globally via npm"
Update-SessionPath
if (-not (Get-Command npm -ErrorAction SilentlyContinue)) {
    throw 'npm is not on PATH after Node.js install. Open a new shell or verify the Node.js installation.'
}
& npm install -g "@angular/cli@$($Versions.AngularCli)"
if ($LASTEXITCODE -ne 0) {
    throw "npm install -g @angular/cli failed (exit code $LASTEXITCODE)"
}

# 6. Workspace folder + optional T: drive alias
if (-not $SkipTDrive) {
    Write-Step "Creating workspace at $WorkspacePath and mapping T:"
    if (-not (Test-Path $WorkspacePath)) {
        New-Item -ItemType Directory -Path $WorkspacePath | Out-Null
    }

    # Map T: now (subst is per-session, hence the scheduled task below for reboot persistence)
    if (Test-Path 'T:\') {
        & subst T: /D | Out-Null
    }
    & subst T: $WorkspacePath

    $taskName = 'TrainingMapTDrive'
    $action = New-ScheduledTaskAction -Execute 'subst.exe' -Argument "T: $WorkspacePath"
    $trigger = New-ScheduledTaskTrigger -AtLogOn
    $principal = New-ScheduledTaskPrincipal -GroupId 'Users' -RunLevel Limited
    $settings = New-ScheduledTaskSettingsSet `
        -AllowStartIfOnBatteries `
        -DontStopIfGoingOnBatteries `
        -StartWhenAvailable
    Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
    Register-ScheduledTask `
        -TaskName $taskName `
        -Action $action `
        -Trigger $trigger `
        -Principal $principal `
        -Settings $settings `
        -Description 'Maps T: to the training workspace at user logon.' | Out-Null
    Write-Host "T: mapped to $WorkspacePath (persisted via scheduled task '$taskName')"
}

# 7. Summary
Write-Step 'Verifying installed versions'
Update-SessionPath

function Show-Version {
    param([string]$Label, [string]$Command, [string[]]$Arguments = @('--version'))
    try {
        $output = & $Command @Arguments 2>&1 | Select-Object -First 1
        Write-Host ('{0,-8} {1}' -f $Label, $output)
    } catch {
        Write-Warning "$Label not callable: $_"
    }
}

Show-Version 'java' 'java'
Show-Version 'mvn'  'mvn'
Show-Version 'node' 'node'
Show-Version 'npm'  'npm'
Show-Version 'ng'   'ng'
Show-Version 'code' 'code'

Write-Host ''
Write-Host 'Setup complete.' -ForegroundColor Green
Write-Host "Log: $logFile"
Write-Host ''
Write-Host 'Open a NEW PowerShell window to pick up the updated PATH and environment variables.' -ForegroundColor Yellow

Stop-Transcript | Out-Null
