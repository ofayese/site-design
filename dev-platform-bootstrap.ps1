#Requires -Version 5.1
[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
param(
    [ValidateSet('All', 'Google', 'Mobile', 'Azure', 'OpenAI', 'Firebase', 'GoogleCloud',
                 'AntigravityCli', 'AntigravityPages', 'Flutter', 'Gradle', 'AndroidStudio',
                 'Jdk', 'Validation', 'Git', 'Python', 'Nssm', 'RemoteTools', 'AraAo')]
    [string[]]$Exclude = @(),
    [switch]$Debug
)

$ErrorActionPreference = 'Stop'
$script:TranscriptStarted = $false
$script:InstallCount = 0
$script:SkipCount = 0
$script:UserPathCache = $null

#region Configuration

$script:Config = @{
    WingetPackages = @(
        @{ Id = 'Microsoft.OpenJDK.17';    Command = 'java';     Label = 'JDK 17';           Section = 'Jdk' }
        @{ Id = 'Google.AndroidStudio';     Command = '';         Label = 'Android Studio';   Section = 'AndroidStudio' }
        @{ Id = 'OpenJS.NodeJS.LTS';        Command = 'npm';      Label = 'Node.js LTS';      Section = 'Google' }
        @{ Id = 'Gradle.Gradle';            Command = 'gradle';   Label = 'Gradle';           Section = 'Gradle' }
        @{ Id = 'Flutter.Flutter';          Command = 'flutter';  Label = 'Flutter';          Section = 'Flutter' }
        @{ Id = 'Google.CloudSDK';          Command = 'gcloud';   Label = 'Google Cloud CLI'; Section = 'GoogleCloud' }
        @{ Id = 'Git.Git';                  Command = 'git';      Label = 'Git';              Section = 'Git' }
        @{ Id = 'Python.Python.3.12';       Command = 'python';   Label = 'Python 3.12';      Section = 'Python' }
        @{ Id = 'NSSM.NSSM';                Command = 'nssm';     Label = 'NSSM (service manager)'; Section = 'Nssm' }
        @{ Id = 'Microsoft.WindowsTerminal';Command = '';         Label = 'Windows Terminal'; Section = 'RemoteTools' }
    )
    Antigravity = @{
        InstallerUrl = 'https://antigravity.google/cli/install.ps1'
        BinPath      = "$env:USERPROFILE\AppData\Local\agy\bin"
        Pages        = @(
            'https://antigravity.google/download?app=antigravity-ide'
            'https://antigravity.google/docs/ide-getting-started?app=antigravity-ide'
            'https://www.antigravity.google/docs/overview'
        )
    }
    AndroidSdk = @{
        Root        = "$env:USERPROFILE\AppData\Local\Android\Sdk"
        PathSubdirs = @('platform-tools', 'cmdline-tools\latest\bin', 'emulator')
        EnvVars     = @('ANDROID_HOME', 'ANDROID_SDK_ROOT')
    }
    AraAo = @{
        # Local-only FastAPI agent runtime (no cloud/ara.so dependency).
        InstallRoot   = "$env:USERPROFILE\ara-ao"
        VenvPath      = "$env:USERPROFILE\ara-ao\.venv"
        ServiceName   = 'AraAoAgent'
        Port          = 8765
        HealthPath    = '/health'
        RepoUrl       = ''   # set to your git URL to clone instead of scaffolding
    }
    TrackedEnvVars = @(
        'OPENAI_API_KEY', 'OPENAI_BASE_URL',
        'AZURE_OPENAI_ENDPOINT', 'AZURE_OPENAI_API_KEY',
        'GOOGLE_API_KEY', 'GEMINI_API_KEY',
        'GITHUB_TOKEN', 'ANTHROPIC_API_KEY',
        'ANDROID_HOME', 'ANDROID_SDK_ROOT'
    )
    ValidationCommands = @(
        'gh', 'gcloud', 'firebase', 'agy', 'java', 'node', 'npm',
        'gradle', 'flutter', 'adb', 'emulator', 'dotnet', 'python',
        'git', 'nssm', 'ssh', 'wt'
    )
    PostValidationCommands = @(
        @{ Command = 'gh';       Args = @('auth', 'status'); Label = 'GitHub auth' }
        @{ Command = 'flutter';  Args = @('doctor');         Label = 'Flutter doctor' }
        @{ Command = 'gcloud';   Args = @('--version');      Label = 'Google Cloud CLI version' }
        @{ Command = 'firebase'; Args = @('--version');      Label = 'Firebase CLI version' }
        @{ Command = 'git';      Args = @('--version');      Label = 'Git version' }
        @{ Command = 'python';   Args = @('--version');      Label = 'Python version' }
    )
}

#endregion

#region Utility Functions

function Write-Step($msg)   { Write-Host "`n=== $msg ===" -ForegroundColor Yellow }
function Write-Info($msg)   { Write-Host "[INFO] $msg" -ForegroundColor Cyan }
function Write-Ok($msg)     { Write-Host "[OK]   $msg" -ForegroundColor Green }
function Write-WarnMsg($msg) { Write-Warning $msg }

function Write-Err($msg) {
    Write-Host "[ERR]  $msg" -ForegroundColor Red
    Write-Warning $msg
}

function Test-Excluded([string]$Section) {
    $excluded = $script:Exclude -contains 'All' -or $script:Exclude -contains $Section
    if ($excluded) {
        Write-Info "Skipping $Section (excluded)."
        $script:SkipCount++
    }
    return $excluded
}

function Test-IsElevated {
    $identity  = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Test-CommandExists {
    param([Parameter(Mandatory)][string]$Command)
    $null -ne (Get-Command $Command -ErrorAction SilentlyContinue)
}

function Get-UserPathEntries {
    if ($null -eq $script:UserPathCache) {
        $current = [Environment]::GetEnvironmentVariable('Path', 'User')
        $script:UserPathCache = if ($current) {
            @($current -split ';' | ForEach-Object { $_.TrimEnd('\', '/') })
        }
        else { @() }
    }
    return $script:UserPathCache
}

function Test-PathInUserPath {
    param([Parameter(Mandatory)][string]$PathToAdd)
    $normalized = $PathToAdd.TrimEnd('\', '/')
    (Get-UserPathEntries) -contains $normalized
}

function Add-UserPathIfExists {
    param([Parameter(Mandatory)][string]$PathToAdd)
    if (-not (Test-Path $PathToAdd)) { return }
    if (Test-PathInUserPath $PathToAdd) { return }
    if (-not $PSCmdlet.ShouldProcess($PathToAdd, 'Add to User PATH')) { return }

    $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
    $userPath = if ([string]::IsNullOrWhiteSpace($userPath)) { $PathToAdd } else { "$userPath;$PathToAdd" }

    [Environment]::SetEnvironmentVariable('Path', $userPath, 'User')
    if ($env:Path -notlike "*$PathToAdd*") {
        $env:Path += ";$PathToAdd"
    }
    $script:UserPathCache = $null
    Write-Info "Added to PATH: $PathToAdd"
}

function Refresh-SessionEnv {
    $machinePath = [Environment]::GetEnvironmentVariable('Path', 'Machine')
    $userPath    = [Environment]::GetEnvironmentVariable('Path', 'User')
    $env:Path    = "$machinePath;$userPath"
    $script:UserPathCache = $null

    foreach ($name in $script:Config.TrackedEnvVars) {
        $value = [Environment]::GetEnvironmentVariable($name, 'User')
        if ($null -ne $value) {
            Set-Item -Path "Env:$name" -Value $value
        }
    }
}

function Set-SecureStringFromHost {
    param([Parameter(Mandatory)][string]$PromptText)
    $secure = Read-Host $PromptText -AsSecureString
    $ptr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
    try {
        [Runtime.InteropServices.Marshal]::PtrToStringBSTR($ptr)
    }
    finally {
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ptr)
    }
}

function Invoke-ExternalCommand {
    # Runs an external (non-terminating-safe) command without the script's
    # global $ErrorActionPreference = 'Stop' causing stderr noise to abort the run.
    param(
        [Parameter(Mandatory)][string]$Executable,
        [string[]]$ArgumentList = @()
    )
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        & $Executable @ArgumentList 2>&1 | ForEach-Object { Write-Host $_ }
        return $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $prev
    }
}

#endregion

#region Installation Functions

function Install-WingetPackageIfMissing {
    param(
        [Parameter(Mandatory)][string]$PackageId,
        [string]$CommandName = '',
        [string]$Label = ''
    )
    if (-not $Label) { $Label = $PackageId }

    if ($CommandName -and (Test-CommandExists $CommandName)) {
        Write-Ok "$Label already available."
        return $true
    }

    if (-not $PSCmdlet.ShouldProcess($PackageId, "winget install ($Label)")) { return $false }

    Write-Step "Install $Label ($PackageId)"
    $exitCode = Invoke-ExternalCommand -Executable 'winget' -ArgumentList @(
        'install', '-e', '--id', $PackageId,
        '--accept-source-agreements', '--accept-package-agreements'
    )
    if ($exitCode -ne 0) {
        Write-Err "winget install failed for $PackageId (exit code $exitCode)"
        return $false
    }
    Refresh-SessionEnv
    $script:InstallCount++
    Write-Ok "$Label installed."
    return $true
}

function Install-FromWingetCatalog {
    param([Parameter(Mandatory)][string]$Section)
    $entries = $script:Config.WingetPackages | Where-Object { $_.Section -eq $Section }
    foreach ($pkg in $entries) {
        Install-WingetPackageIfMissing -PackageId $pkg.Id -CommandName $pkg.Command -Label $pkg.Label | Out-Null
    }
}

function Install-FirebaseCli {
    if (-not (Test-CommandExists npm)) {
        Write-WarnMsg 'npm not available; skipping Firebase CLI.'
        return
    }
    if (Test-CommandExists firebase) {
        Write-Ok 'Firebase CLI already available.'
        return
    }
    if (-not $PSCmdlet.ShouldProcess('firebase-tools', 'npm install -g')) { return }

    Write-Step 'Install Firebase CLI'
    $exitCode = Invoke-ExternalCommand -Executable 'npm' -ArgumentList @('install', '-g', 'firebase-tools')
    if ($exitCode -ne 0) {
        Write-Err "npm install firebase-tools failed (exit code $exitCode)"
        return
    }
    Refresh-SessionEnv
    Write-Ok 'Firebase CLI installed.'
}

function Install-AntigravityCli {
    $cfg = $script:Config.Antigravity
    if (Test-CommandExists agy) {
        Write-Ok 'Antigravity CLI already available.'
        return
    }
    if (-not $PSCmdlet.ShouldProcess($cfg.InstallerUrl, 'Download and run Antigravity CLI installer')) { return }

    Write-Step 'Install Antigravity CLI'
    $installerPath = Join-Path $env:TEMP 'install-antigravity.ps1'
    try {
        Invoke-WebRequest -Uri $cfg.InstallerUrl -OutFile $installerPath -TimeoutSec 60 -UseBasicParsing
        Write-Info "Downloaded installer to $installerPath"
        & $installerPath
        Add-UserPathIfExists -PathToAdd $cfg.BinPath
        Refresh-SessionEnv
        Write-Ok 'Antigravity CLI installation completed.'
    }
    catch {
        Write-Err "Failed to install Antigravity CLI: $_"
        Write-WarnMsg "Manual install: irm $($cfg.InstallerUrl) | iex"
    }
}

function Open-AntigravityPages {
    Write-Step 'Open official Antigravity download pages'
    foreach ($url in $script:Config.Antigravity.Pages) {
        Write-Info "Opening $url ..."
        try { Start-Process $url }
        catch { Write-WarnMsg "Could not open $url : $_" }
    }
}

function Install-NpmIfMissing {
    if (Test-CommandExists npm) {
        Write-Ok 'npm already available.'
        return $true
    }
    return (Install-WingetPackageIfMissing -PackageId 'OpenJS.NodeJS.LTS' -CommandName 'npm' -Label 'Node.js LTS')
}

function Enable-OpenSshClientFeature {
    if (Test-CommandExists ssh) {
        Write-Ok 'OpenSSH client already available.'
        return
    }
    if (-not (Test-IsElevated)) {
        Write-WarnMsg 'OpenSSH Client feature requires an elevated session; skipping.'
        return
    }
    if (-not $PSCmdlet.ShouldProcess('OpenSSH.Client', 'Add-WindowsCapability')) { return }

    Write-Step 'Enable OpenSSH Client (for SSH into Windows Server VM nodes)'
    try {
        $cap = Get-WindowsCapability -Online -Name 'OpenSSH.Client*' | Select-Object -First 1
        if ($cap -and $cap.State -ne 'Installed') {
            Add-WindowsCapability -Online -Name $cap.Name | Out-Null
        }
        Write-Ok 'OpenSSH Client enabled.'
    }
    catch {
        Write-WarnMsg "Could not enable OpenSSH Client: $_"
    }
}

function Install-VsCodeRemoteExtensions {
    if (-not (Test-CommandExists code)) {
        Write-WarnMsg 'VS Code (code CLI) not found on PATH; skipping remote extension install.'
        return
    }
    Write-Step 'Install VS Code Remote extensions (SSH + Tunnels)'
    $extensions = @('ms-vscode-remote.remote-ssh', 'ms-vscode.remote-server')
    foreach ($ext in $extensions) {
        try {
            Invoke-ExternalCommand -Executable 'code' -ArgumentList @('--install-extension', $ext) | Out-Null
            Write-Ok "Installed VS Code extension: $ext"
        }
        catch {
            Write-WarnMsg "Could not install VS Code extension ${ext}: $_"
        }
    }
}

function Install-RemoteManagementTools {
    if (Test-Excluded 'RemoteTools') { return }
    Write-Step 'Remote management tools (Mac/dev workstation -> Windows Server VM nodes)'

    Install-FromWingetCatalog -Section 'RemoteTools'
    Enable-OpenSshClientFeature
    Install-VsCodeRemoteExtensions

    Write-Info 'RDP: use built-in mstsc.exe (Start > Run > mstsc) to connect to Akoda/Geekom.'
    Write-Info 'SSH: ssh <user>@<vm-host> once OpenSSH Server is enabled on the VM (see windows-server-vm-bootstrap.ps1).'
    Write-Info 'VS Code: use "Remote-SSH: Connect to Host..." from the command palette.'
}

#endregion

#region ara.ao Agent Scaffold (local-only, no cloud runtime)

function New-AraAoScaffold {
    param([Parameter(Mandatory)][string]$InstallRoot)

    if (Test-Path (Join-Path $InstallRoot 'main.py')) {
        Write-Ok "ara.ao scaffold already present at $InstallRoot."
        return
    }
    if (-not $PSCmdlet.ShouldProcess($InstallRoot, 'Create ara.ao FastAPI scaffold')) { return }

    New-Item -ItemType Directory -Path $InstallRoot -Force | Out-Null

    $mainPy = @'
"""
ara.ao local agent runtime (no cloud/ara.so dependency).
Minimal FastAPI scaffold: health endpoint for lightweight HA failover checks,
plus a placeholder /invoke route for agent/tool execution.
"""
from fastapi import FastAPI
from pydantic import BaseModel
import socket
import time

app = FastAPI(title="ara.ao local agent")

START_TIME = time.time()


class InvokeRequest(BaseModel):
    input: str


@app.get("/health")
def health():
    return {
        "status": "ok",
        "host": socket.gethostname(),
        "uptime_seconds": round(time.time() - START_TIME, 1),
    }


@app.post("/invoke")
def invoke(req: InvokeRequest):
    # Replace with real skill/tool dispatch.
    return {"host": socket.gethostname(), "echo": req.input}


if __name__ == "__main__":
    import uvicorn
    uvicorn.run(app, host="0.0.0.0", port=8765)
'@
    Set-Content -Path (Join-Path $InstallRoot 'main.py') -Value $mainPy -Encoding utf8

    $requirements = @'
fastapi>=0.110
uvicorn[standard]>=0.29
pydantic>=2.6
'@
    Set-Content -Path (Join-Path $InstallRoot 'requirements.txt') -Value $requirements -Encoding utf8

    Write-Ok "ara.ao scaffold created at $InstallRoot."
}

function Install-AraAoAgent {
    if (Test-Excluded 'AraAo') { return }
    Write-Step 'ara.ao local FastAPI agent setup (dev workstation)'

    Install-FromWingetCatalog -Section 'Python'
    if (-not (Test-CommandExists python)) {
        Write-WarnMsg 'python not available after install attempt; skipping ara.ao venv setup.'
        return
    }

    $cfg = $script:Config.AraAo

    if ($cfg.RepoUrl) {
        Install-FromWingetCatalog -Section 'Git'
        if (-not (Test-Path $cfg.InstallRoot) -and (Test-CommandExists git)) {
            if ($PSCmdlet.ShouldProcess($cfg.RepoUrl, "git clone into $($cfg.InstallRoot)")) {
                Invoke-ExternalCommand -Executable 'git' -ArgumentList @('clone', $cfg.RepoUrl, $cfg.InstallRoot) | Out-Null
            }
        }
    }
    else {
        New-AraAoScaffold -InstallRoot $cfg.InstallRoot
    }

    if (-not (Test-Path $cfg.VenvPath)) {
        if ($PSCmdlet.ShouldProcess($cfg.VenvPath, 'Create Python virtual environment')) {
            Invoke-ExternalCommand -Executable 'python' -ArgumentList @('-m', 'venv', $cfg.VenvPath) | Out-Null
        }
    }

    $venvPython = Join-Path $cfg.VenvPath 'Scripts\python.exe'
    $reqFile    = Join-Path $cfg.InstallRoot 'requirements.txt'
    if ((Test-Path $venvPython) -and (Test-Path $reqFile)) {
        if ($PSCmdlet.ShouldProcess($reqFile, 'pip install -r requirements.txt')) {
            Invoke-ExternalCommand -Executable $venvPython -ArgumentList @('-m', 'pip', 'install', '-r', $reqFile) | Out-Null
        }
    }

    Write-Ok "ara.ao dev environment ready at $($cfg.InstallRoot)."
    Write-Info "Run locally with: $venvPython -m uvicorn main:app --host 0.0.0.0 --port $($cfg.Port)"
    Write-Info 'For production install-as-a-service on the VM node, see windows-server-vm-bootstrap.ps1.'
}

#endregion

#region Environment Setup

function Set-UserEnvVarInteractive {
    param(
        [Parameter(Mandatory)][string]$Name,
        [string]$PromptText = '',
        [switch]$Secret
    )

    $existing = [Environment]::GetEnvironmentVariable($Name, 'User')
    if ($existing) {
        Write-Info "$Name already set at User scope. Leaving unchanged."
        return
    }
    if (-not $PromptText) { $PromptText = "Enter value for $Name" }

    $value = if ($Secret) { Set-SecureStringFromHost $PromptText } else { Read-Host $PromptText }

    if ([string]::IsNullOrWhiteSpace($value)) {
        Write-WarnMsg "Skipped $Name."
        return
    }
    if (-not $PSCmdlet.ShouldProcess($Name, 'Set User environment variable')) { return }

    [Environment]::SetEnvironmentVariable($Name, $value, 'User')
    Set-Item -Path "Env:$Name" -Value $value
    Write-Ok "Saved $Name to User environment."
}

function Set-PairedGeminiGoogleKeyInteractive {
    $existing = [Environment]::GetEnvironmentVariable('GEMINI_API_KEY', 'User')
    if ($existing) {
        Write-Info 'GEMINI_API_KEY already set at User scope. Leaving unchanged.'
        return
    }

    $value = Set-SecureStringFromHost 'Enter Gemini / Google API key'
    if ([string]::IsNullOrWhiteSpace($value)) {
        Write-WarnMsg 'Skipped Gemini/Google key.'
        return
    }
    if (-not $PSCmdlet.ShouldProcess('GEMINI_API_KEY / GOOGLE_API_KEY', 'Set User environment variables')) { return }

    foreach ($varName in @('GEMINI_API_KEY', 'GOOGLE_API_KEY')) {
        [Environment]::SetEnvironmentVariable($varName, $value, 'User')
        Set-Item -Path "Env:$varName" -Value $value
    }
    Write-Ok 'Saved GEMINI_API_KEY and GOOGLE_API_KEY.'
}

function Configure-AndroidEnvVars {
    $sdk = $script:Config.AndroidSdk
    $sdkPath = $sdk.Root

    foreach ($varName in $sdk.EnvVars) {
        $existing = [Environment]::GetEnvironmentVariable($varName, 'User')
        if ($existing -and $existing -ne $sdkPath) {
            Write-Info "$varName already set to '$existing'. Leaving unchanged."
            continue
        }
        if (-not $PSCmdlet.ShouldProcess($varName, "Set to $sdkPath")) { continue }
        [Environment]::SetEnvironmentVariable($varName, $sdkPath, 'User')
        Set-Item -Path "Env:$varName" -Value $sdkPath
    }
    Write-Ok 'Android SDK environment variables configured.'

    foreach ($sub in $sdk.PathSubdirs) {
        Add-UserPathIfExists -PathToAdd (Join-Path $sdkPath $sub)
    }
    Refresh-SessionEnv
}

#endregion

#region Google / Mobile Sections

function Install-GoogleSection {
    if (Test-Excluded 'Google') { return }
    Write-Step 'Google developer tooling'

    if (-not (Test-Excluded 'GoogleCloud')) {
        Install-FromWingetCatalog -Section 'GoogleCloud'
    }
    Install-NpmIfMissing | Out-Null
    if (-not (Test-Excluded 'Firebase')) { Install-FirebaseCli }
    if (-not (Test-Excluded 'AntigravityCli')) { Install-AntigravityCli }
    if (-not (Test-Excluded 'AntigravityPages')) { Open-AntigravityPages }
}

function Install-MobileSection {
    if (Test-Excluded 'Mobile') { return }
    Write-Step 'Android / cross-platform mobile tooling'

    if (-not (Test-Excluded 'Jdk')) { Install-FromWingetCatalog -Section 'Jdk' }
    if (-not (Test-Excluded 'AndroidStudio')) { Install-FromWingetCatalog -Section 'AndroidStudio' }
    Install-NpmIfMissing | Out-Null
    if (-not (Test-Excluded 'Gradle')) { Install-FromWingetCatalog -Section 'Gradle' }
    if (-not (Test-Excluded 'Flutter')) { Install-FromWingetCatalog -Section 'Flutter' }
    if (-not (Test-Excluded 'GoogleCloud')) { Install-FromWingetCatalog -Section 'GoogleCloud' }
    if (-not (Test-Excluded 'Firebase')) { Install-FirebaseCli }

    Write-Step 'Configure Android environment variables'
    Configure-AndroidEnvVars
}

#endregion

#region Validation

function Run-PostValidation {
    if (Test-Excluded 'Validation') { return }
    Write-Step 'Post-install validation'

    $colWidth = 20
    $hasIssue = $false

    Write-Host "`nCommands:`n" -ForegroundColor White
    foreach ($cmd in $script:Config.ValidationCommands) {
        $resolved = Get-Command $cmd -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Source -ErrorAction SilentlyContinue
        if ($resolved) {
            Write-Host ("  {0,-$colWidth} {1}" -f $cmd, $resolved) -ForegroundColor Green
        }
        else {
            Write-Host ("  {0,-$colWidth} {1}" -f $cmd, 'MISSING') -ForegroundColor DarkYellow
            $hasIssue = $true
        }
    }

    Write-Host "`nEnvironment:`n" -ForegroundColor White
    $envChecks = @(
        @{ Name = 'ANDROID_HOME';          ShowPath = $true }
        @{ Name = 'ANDROID_SDK_ROOT';       ShowPath = $true }
        @{ Name = 'OPENAI_API_KEY';         ShowPath = $false }
        @{ Name = 'AZURE_OPENAI_ENDPOINT';  ShowPath = $true }
        @{ Name = 'AZURE_OPENAI_API_KEY';   ShowPath = $false }
        @{ Name = 'GEMINI_API_KEY';         ShowPath = $false }
        @{ Name = 'GOOGLE_API_KEY';         ShowPath = $false }
    )

    foreach ($check in $envChecks) {
        $val = [Environment]::GetEnvironmentVariable($check.Name, 'User')
        $display = if ($check.ShowPath) { if ($val) { $val } else { 'missing' } }
                   else { if ($val) { 'set' } else { 'missing' } }
        $color = if ($val) { 'Green' } else { 'DarkYellow' }
        Write-Host ("  {0,-$colWidth} {1}" -f $check.Name, $display) -ForegroundColor $color
    }

    if ($hasIssue) {
        Write-Host "`nSome items are missing. See above." -ForegroundColor Yellow
    }

    foreach ($post in $script:Config.PostValidationCommands) {
        if (-not (Test-CommandExists $post.Command)) { continue }
        Write-Step $post.Label
        try { & $post.Command @($post.Args) }
        catch { Write-WarnMsg "$($post.Label) failed: $_" }
    }
}

#endregion

#region Telemetry

function Show-Summary {
    Write-Step 'Summary'
    Write-Host "  Installations attempted : $script:InstallCount" -ForegroundColor White
    Write-Host "  Sections skipped        : $script:SkipCount" -ForegroundColor White
    if (-not (Test-IsElevated)) {
        Write-Host '  Note: session was not elevated; some installs may have failed silently.' -ForegroundColor DarkYellow
    }
}

#endregion

#region Main

if ($Debug) {
    $transcriptPath = Join-Path $env:TEMP "dev_platform_bootstrap_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"
    Start-Transcript -Path $transcriptPath | Out-Null
    $script:TranscriptStarted = $true
    Write-Info "Transcript: $transcriptPath"
}

try {
    Write-Host 'Developer Platforms Unified Bootstrap' -ForegroundColor Cyan
    Write-Host ('-' * 40) -ForegroundColor Cyan

    if (-not (Test-CommandExists winget)) {
        throw 'WinGet is required. Please update App Installer from the Microsoft Store.'
    }
    if (-not (Test-IsElevated)) {
        Write-WarnMsg 'Not running elevated. Some winget installs and feature toggles may fail. Consider re-running as Administrator.'
    }

    Refresh-SessionEnv

    Install-GoogleSection
    Install-MobileSection
    Install-RemoteManagementTools
    Install-AraAoAgent

    if (-not ($script:Exclude -contains 'Azure')) {
        Write-Step 'Azure / Azure OpenAI environment setup'
        $setupAzure = Read-Host 'Configure AZURE_OPENAI_ENDPOINT and AZURE_OPENAI_API_KEY now? (y/N)'
        if ($setupAzure -match '^(y|yes)$') {
            Set-UserEnvVarInteractive -Name 'AZURE_OPENAI_ENDPOINT' -PromptText 'Enter Azure OpenAI endpoint'
            Set-UserEnvVarInteractive -Name 'AZURE_OPENAI_API_KEY'  -PromptText 'Enter Azure OpenAI API key' -Secret
        }
    }

    if (-not ($script:Exclude -contains 'OpenAI')) {
        Write-Step 'OpenAI / Gemini environment setup'
        $setupOpenAI = Read-Host 'Configure OPENAI_API_KEY now? (y/N)'
        if ($setupOpenAI -match '^(y|yes)$') {
            Set-UserEnvVarInteractive -Name 'OPENAI_API_KEY' -PromptText 'Enter OpenAI API key' -Secret
            $setBaseUrl = Read-Host 'Set OPENAI_BASE_URL too? (y/N)'
            if ($setBaseUrl -match '^(y|yes)$') {
                Set-UserEnvVarInteractive -Name 'OPENAI_BASE_URL' -PromptText 'Enter OpenAI base URL'
            }
        }
        $setupGemini = Read-Host 'Configure GEMINI_API_KEY / GOOGLE_API_KEY now? (y/N)'
        if ($setupGemini -match '^(y|yes)$') {
            Set-PairedGeminiGoogleKeyInteractive
        }
    }

    Refresh-SessionEnv
    Run-PostValidation

    Write-Step 'Complete'
    Write-Ok 'Developer platform bootstrap finished.'
    Write-Host "`nNext steps:" -ForegroundColor White
    Write-Host '  1. Open a fresh PowerShell 7 session.' -ForegroundColor White
    Write-Host '  2. Run: gh auth status' -ForegroundColor White
    Write-Host '  3. Run: gcloud init' -ForegroundColor White
    Write-Host '  4. Run: firebase login' -ForegroundColor White
    Write-Host '  5. Run: flutter doctor' -ForegroundColor White
    Write-Host '  6. Complete Android Studio first-run SDK setup if adb/emulator are missing.' -ForegroundColor White
    Write-Host '  7. Install Antigravity desktop / IDE from official pages if opened.' -ForegroundColor White
    Write-Host '  8. Run windows-server-vm-bootstrap.ps1 ON each Windows Server VM node (Akoda/Geekom).' -ForegroundColor White
    Write-Host '  9. Run arao-failover-monitor.ps1 on the standby node once both nodes are up.' -ForegroundColor White

    Show-Summary
}
catch {
    Write-Err "Bootstrap failed: $_"
    exit 1
}
finally {
    if ($script:TranscriptStarted) {
        Stop-Transcript | Out-Null
    }
}

#endregion
