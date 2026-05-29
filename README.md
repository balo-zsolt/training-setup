# Training Laptop Setup

One-shot bootstrap for the annual Java + Angular training. Installs a pinned
toolchain on a fresh Windows 10/11 laptop:

- Eclipse Temurin JDK 21
- Apache Maven
- Node.js LTS
- Angular CLI (global via npm)
- Visual Studio Code
- pgAdmin 4

Sets `JAVA_HOME` and `M2_HOME` system-wide, and (by default) creates a `T:`
drive alias pointing at `C:\TrainingWorkspace` for course materials.

## Participant usage

Open an **Administrator PowerShell** and run:

```powershell
# 1. Authenticate to GitHub (paste the trainer-provided PAT when prompted)
git clone https://github.com/<your-user>/training-setup.git C:\training-setup

# 2. Run the bootstrap
cd C:\training-setup
.\setup.ps1
```

The script self-elevates if you forget to start PowerShell as admin. Expect
5-10 minutes for all packages to download and install. When it finishes,
**open a new PowerShell window** so the updated `PATH` / `JAVA_HOME` are
picked up.

### Why clone instead of `iwr | iex`?

Because this repo is private. The `iwr -useb ... | iex` one-liner only works
cleanly for public repos; for private repos the PAT would leak into shell
history. Cloning once is the safest path. (If you flip the repo to public
later, replace the two commands above with a single `iwr` call.)

### Skipping the T: drive

If a participant already has a `T:` drive (mapped network drive, etc.):

```powershell
.\setup.ps1 -SkipTDrive
```

### Custom workspace path

```powershell
.\setup.ps1 -WorkspacePath 'D:\Training'
```

## Yearly update workflow (trainer)

The script is the **single source of truth** for what gets installed. The
versions are pinned in one block at the top of [setup.ps1](setup.ps1):

```powershell
$Versions = @{
    Jdk        = '21.0.5+11'
    Node       = '22.11.0'
    Maven      = '3.9.9'
    Vscode     = '1.96.2'
    PgAdmin    = '8.13'
    AngularCli = '18.2.12'
}
```

To bump versions for next year's training:

1. **Discover available versions** for each winget package:
   ```powershell
   winget show --id EclipseAdoptium.Temurin.21.JDK --versions
   winget show --id OpenJS.NodeJS.LTS              --versions
   winget show --id Apache.Maven                   --versions
   winget show --id Microsoft.VisualStudioCode     --versions
   winget show --id PostgreSQL.pgAdmin             --versions
   ```
   For Angular CLI: `npm view @angular/cli versions --json`.

2. **Edit** the `$Versions` block in `setup.ps1` to pin the new values.

3. **Test on a clean Windows VM** (Hyper-V / VirtualBox / Azure DevBox).
   Verify each tool reports the expected version at the end of the script.

4. **Commit and tag** with the training year:
   ```powershell
   git commit -am 'pin versions for 2027 training'
   git tag training-2027
   git push origin main --tags
   ```

5. **Share the tag URL** with participants so they always clone the tested
   revision:
   ```
   git clone --branch training-2027 https://github.com/<your-user>/training-setup.git
   ```

## Re-test ~1 week before training

winget's manifest repo occasionally drops or renames old versions. Re-run the
script on a clean VM about a week before training to confirm every pinned
version still resolves. If a package version has disappeared, repeat step 1
above to pick the closest still-available version and re-tag.

## Troubleshooting

| Symptom | Cause / fix |
|---------|-------------|
| `winget is not available` | Open Microsoft Store, install "App Installer" |
| `Could not locate the Temurin JDK 21 installation directory` | Temurin path or version changed; update the wildcard in `setup.ps1` |
| `npm is not on PATH` | Open a brand new PowerShell window and re-run |
| `winget install failed ... exit code -1978335212` | Pinned version no longer in winget repo; bump it and re-tag |

The transcript of each run is written to `%TEMP%\training-setup-<timestamp>.log`.
