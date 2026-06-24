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
    Jdk        = '25.0.3.9'     # winget: EclipseAdoptium.Temurin.25.JDK (winget uses dot-separated build, not '+9')
    Node       = '24.18.0'      # winget: OpenJS.NodeJS.LTS
    Maven      = '3.9.16'       # direct download from Apache (no longer published on winget) - see Install-Maven
    Vscode     = '1.125.1'      # winget: Microsoft.VisualStudioCode
    PgAdmin    = '9.16'         # winget: PostgreSQL.pgAdmin
    Git        = '2.54.0'       # winget: Git.Git
    Az         = '2.87.0'       # winget: Microsoft.AzureCLI
    AngularCli = '22.0.4'       # npm:    @angular/cli (engines require Node ^22.22.3 || ^24.15.0 - met by Node pin)
}

$Packages = @(
    @{ Id = 'EclipseAdoptium.Temurin.25.JDK'; Version = $Versions.Jdk;     Name = 'Eclipse Temurin JDK 25' }
    @{ Id = 'OpenJS.NodeJS.LTS';              Version = $Versions.Node;    Name = 'Node.js LTS' }
    @{ Id = 'Microsoft.VisualStudioCode';     Version = $Versions.Vscode;  Name = 'Visual Studio Code' }
    @{ Id = 'PostgreSQL.pgAdmin';             Version = $Versions.PgAdmin; Name = 'pgAdmin 4' }
    @{ Id = 'Git.Git';                        Version = $Versions.Git;     Name = 'Git' }
    @{ Id = 'Microsoft.AzureCLI';             Version = $Versions.Az;      Name = 'Azure CLI' }
)
# NOTE: Apache Maven is no longer published on the winget repository (the
# 'Apache.Maven' package was removed), so it is installed separately from the
# official Apache distribution by Install-Maven below - NOT via $Packages.
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
        --source winget `
        --silent `
        --disable-interactivity `
        --accept-source-agreements `
        --accept-package-agreements
    # winget exit codes worth tolerating:
    #   0           = success
    #  -1978335189  = already installed at this version (UPDATE_NOT_APPLICABLE)
    #  -1978335212  = no applicable upgrade found
    if ($LASTEXITCODE -eq 0 -or
        $LASTEXITCODE -eq -1978335189 -or
        $LASTEXITCODE -eq -1978335212) {
        return
    }

    # -1978335209 = pinned version no longer published in the winget repo.
    # Old manifests get pruned over time, so a once-valid pin can disappear.
    # Surface the still-available versions so the pin in $Versions can be updated.
    if ($LASTEXITCODE -eq -1978335209) {
        Write-Warning "Pinned version '$Version' of $Id is no longer in the winget repo."
        Write-Warning "Available versions (update the pin in `$Versions accordingly):"
        & winget show --id $Id --source winget --versions
        throw "Stale version pin for $Id (pinned '$Version'). Update `$Versions and re-run."
    }

    throw "winget install failed for $Id (exit code $LASTEXITCODE)"
}

function Install-Maven {
    param([string]$Version)
    Write-Step "Installing Apache Maven $Version (direct download from Apache)"

    $targetParent = 'C:\Program Files'
    $mvnHome = Join-Path $targetParent "apache-maven-$Version"

    if (Test-Path (Join-Path $mvnHome 'bin\mvn.cmd')) {
        Write-Host "Maven $Version already present at $mvnHome"
    } else {
        $zipName    = "apache-maven-$Version-bin.zip"
        $zipPath    = Join-Path $env:TEMP $zipName
        # dlcdn serves current releases; archive is the permanent fallback once superseded.
        $primaryUrl = "https://dlcdn.apache.org/maven/maven-3/$Version/binaries/$zipName"
        $archiveUrl = "https://archive.apache.org/dist/maven/maven-3/$Version/binaries/$zipName"

        Write-Host "Downloading $primaryUrl"
        try {
            Invoke-WebRequest -Uri $primaryUrl -OutFile $zipPath -UseBasicParsing
        } catch {
            Write-Warning "Primary mirror failed ($($_.Exception.Message)); falling back to archive.apache.org"
            Invoke-WebRequest -Uri $archiveUrl -OutFile $zipPath -UseBasicParsing
        }

        Write-Host "Extracting to $targetParent"
        Expand-Archive -Path $zipPath -DestinationPath $targetParent -Force
        Remove-Item $zipPath -Force -ErrorAction SilentlyContinue
    }

    # Put Maven's bin on the machine PATH (idempotent) so 'mvn' resolves.
    # winget used to do this for us; with a manual install we own it.
    $mvnBin = Join-Path $mvnHome 'bin'
    $machinePath = [Environment]::GetEnvironmentVariable('Path', 'Machine')
    if (($machinePath -split ';') -notcontains $mvnBin) {
        [Environment]::SetEnvironmentVariable('Path', "$machinePath;$mvnBin", 'Machine')
        Write-Host "Added $mvnBin to machine PATH"
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

# 2b. Install Maven separately (not available on winget)
Install-Maven -Version $Versions.Maven

# 3. Refresh PATH so freshly-installed tools are callable in this session
Update-SessionPath

# 4. Set JAVA_HOME and M2_HOME (machine-wide)
Write-Step 'Setting JAVA_HOME and M2_HOME (machine-wide)'

$javaHome = Get-ChildItem 'C:\Program Files\Eclipse Adoptium' -Directory -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -like 'jdk-25*' } |
            Select-Object -First 1 -ExpandProperty FullName
if (-not $javaHome) {
    throw 'Could not locate the Temurin JDK 25 installation directory under C:\Program Files\Eclipse Adoptium.'
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
Show-Version 'git'  'git'
Show-Version 'az'   'az'

Write-Host ''
Write-Host 'Setup complete.' -ForegroundColor Green
Write-Host "Log: $logFile"
Write-Host ''
Write-Host 'Open a NEW PowerShell window to pick up the updated PATH and environment variables.' -ForegroundColor Yellow

Stop-Transcript | Out-Null
