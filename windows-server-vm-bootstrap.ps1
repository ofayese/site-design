#Requires -Version 5.1
#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Prepares a Windows Server 2025 node (Akoda or Geekom) for:
      - Hyper-V host role (to run a nested Domain Controller VM)
      - OpenSSH Server (remote management from Mac/dev workstation)
      - ara.ao local FastAPI agent, run as a Windows Service via NSSM
      - Windows Firewall rules for SSH + agent port

.NOTES
    This is intentionally NOT a Windows Failover Cluster script.
    Per the architecture decision: lightweight HA (health-check based),
    not Failover-Clustering / CSV / live migration. See arao-failover-monitor.ps1.

.PARAMETER NodeRole
    'Primary' (Akoda) or 'Secondary' (Geekom). Only affects labeling/log output.

.PARAMETER SkipHyperV
    Skip enabling the Hyper-V role.

.PARAMETER SkipSsh
    Skip enabling/configuring OpenSSH Server.

.PARAMETER SkipAraAo
    Skip ara.ao agent install + service registration.

.EXAMPLE
    .\windows-server-vm-bootstrap.ps1 -NodeRole Primary
#>
[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
param(
    [ValidateSet('Primary', 'Secondary')]
    [string]$NodeRole = 'Primary',
    [switch]$SkipHyperV,
    [switch]$SkipSsh,
    [switch]$SkipAraAo,
    [int]$AraAoPort = 8765
)

$ErrorActionPreference = 'Stop'

function Write-Step($msg) { Write-Host "`n=== [$NodeRole] $msg ===" -ForegroundColor Yellow }
function Write-Info($msg) { Write-Host "[INFO] $msg" -ForegroundColor Cyan }
function Write-Ok($msg)   { Write-Host "[OK]   $msg" -ForegroundColor Green }
function Write-WarnMsg($msg) { Write-Warning $msg }

#region Hyper-V role (host for nested DC VM)

function Enable-HyperVRole {
    Write-Step 'Hyper-V role (host for Domain Controller VM)'

    $feature = Get-WindowsFeature -Name Hyper-V -ErrorAction SilentlyContinue
    if ($feature -and $feature.Installed) {
        Write-Ok 'Hyper-V role already installed.'
        return
    }

    if (-not $PSCmdlet.ShouldProcess('Hyper-V', 'Install-WindowsFeature (requires reboot)')) { return }

    Write-Info 'Installing Hyper-V role + management tools. A reboot will be required.'
    $result = Install-WindowsFeature -Name Hyper-V -IncludeManagementTools -Restart:$false
    if ($result.Success) {
        Write-Ok 'Hyper-V installed. Reboot required before creating VMs.'
        if ($result.RestartNeeded -eq 'Yes') {
            Write-WarnMsg 'Restart-Computer is required to finish Hyper-V setup. Run it manually, then re-run this script.'
        }
    }
    else {
        Write-WarnMsg "Hyper-V install did not report success: $($result.ExitCode)"
    }
}

function New-DomainControllerVmShell {
    # Creates the VM shell only (no unattended AD DS promotion here by design --
    # DC promotion should be done deliberately via Install-ADDSForest /
    # Install-ADDSDomainController after OS install, per your identity design).
    param(
        [string]$VmName = "DC-$NodeRole",
        [string]$VhdPath = "D:\Hyper-V\$VmName\$VmName.vhdx",
        [int64]$VhdSizeBytes = 60GB,
        [int64]$MemoryBytes = 4GB,
        [string]$SwitchName = 'Internal-Identity-Switch'
    )

    if (-not (Get-Command Get-VM -ErrorAction SilentlyContinue)) {
        Write-WarnMsg 'Hyper-V PowerShell module not available (reboot pending?). Skipping VM shell creation.'
        return
    }
    if (Get-VM -Name $VmName -ErrorAction SilentlyContinue) {
        Write-Ok "VM '$VmName' already exists."
        return
    }
    if (-not $PSCmdlet.ShouldProcess($VmName, 'Create Hyper-V VM shell for Domain Controller')) { return }

    if (-not (Get-VMSwitch -Name $SwitchName -ErrorAction SilentlyContinue)) {
        Write-Info "Creating internal virtual switch '$SwitchName' for DC <-> host traffic."
        New-VMSwitch -Name $SwitchName -SwitchType Internal | Out-Null
    }

    $vhdDir = Split-Path $VhdPath -Parent
    if (-not (Test-Path $vhdDir)) { New-Item -ItemType Directory -Path $vhdDir -Force | Out-Null }

    New-VM -Name $VmName -MemoryStartupBytes $MemoryBytes -NewVHDPath $VhdPath -NewVHDSizeBytes $VhdSizeBytes -Generation 2 -SwitchName $SwitchName | Out-Null
    Set-VMProcessor -VMName $VmName -Count 2
    Set-VM -Name $VmName -AutomaticStartAction Start -AutomaticStopAction ShutDown

    Write-Ok "VM shell '$VmName' created. Attach a Windows Server ISO and install the OS, then promote to DC deliberately."
}

#endregion

#region OpenSSH Server (remote management from Mac)

function Enable-OpenSshServer {
    Write-Step 'OpenSSH Server (for SSH / VS Code Remote-SSH from Mac dev workstation)'

    $cap = Get-WindowsCapability -Online -Name 'OpenSSH.Server*' | Select-Object -First 1
    if (-not $cap) {
        Write-WarnMsg 'OpenSSH.Server capability not found on this OS image.'
        return
    }
    if ($cap.State -ne 'Installed') {
        if (-not $PSCmdlet.ShouldProcess('OpenSSH.Server', 'Add-WindowsCapability')) { return }
        Add-WindowsCapability -Online -Name $cap.Name | Out-Null
        Write-Ok 'OpenSSH Server capability installed.'
    }
    else {
        Write-Ok 'OpenSSH Server capability already installed.'
    }

    if (-not $PSCmdlet.ShouldProcess('sshd', 'Set service to Automatic and start')) { return }

    Set-Service -Name sshd -StartupType Automatic
    Start-Service -Name sshd -ErrorAction SilentlyContinue

    # Default shell -> PowerShell 7 if present, else keep default cmd-based sshd shell.
    $pwsh = Get-Command pwsh -ErrorAction SilentlyContinue
    if ($pwsh) {
        New-ItemProperty -Path 'HKLM:\SOFTWARE\OpenSSH' -Name DefaultShell `
            -Value $pwsh.Source -PropertyType String -Force | Out-Null
        Write-Ok "Default SSH shell set to pwsh ($($pwsh.Source))."
    }

    New-NetFirewallRule -Name 'OpenSSH-Server-In-TCP' -DisplayName 'OpenSSH Server (sshd)' `
        -Enabled True -Direction Inbound -Protocol TCP -Action Allow -LocalPort 22 `
        -ErrorAction SilentlyContinue | Out-Null

    Write-Ok 'OpenSSH Server enabled, started, and firewall rule added for port 22.'
}

#endregion

#region ara.ao agent as a Windows Service (via NSSM)

function Install-NssmIfMissing {
    if (Get-Command nssm -ErrorAction SilentlyContinue) { return $true }

    if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
        Write-WarnMsg 'winget not available; install NSSM manually from https://nssm.cc/download'
        return $false
    }
    if (-not $PSCmdlet.ShouldProcess('NSSM.NSSM', 'winget install')) { return $false }

    winget install -e --id NSSM.NSSM --accept-source-agreements --accept-package-agreements
    return $true
}

function Install-AraAoService {
    param(
        [string]$InstallRoot = "$env:ProgramData\ara-ao",
        [string]$ServiceName = 'AraAoAgent',
        [int]$Port = $AraAoPort
    )

    Write-Step "ara.ao FastAPI agent as Windows Service ($ServiceName)"

    if (-not (Get-Command python -ErrorAction SilentlyContinue)) {
        Write-WarnMsg 'Python not found. Install Python 3.12 first (winget install Python.Python.3.12), then re-run.'
        return
    }
    if (-not (Install-NssmIfMissing)) {
        Write-WarnMsg 'NSSM unavailable; cannot register ara.ao as a Windows Service.'
        return
    }

    if (-not (Test-Path $InstallRoot)) {
        if (-not $PSCmdlet.ShouldProcess($InstallRoot, 'Create ara.ao install directory + scaffold')) { return }
        New-Item -ItemType Directory -Path $InstallRoot -Force | Out-Null

        $mainPy = @'
from fastapi import FastAPI
from pydantic import BaseModel
import socket, time

app = FastAPI(title="ara.ao local agent")
START_TIME = time.time()

class InvokeRequest(BaseModel):
    input: str

@app.get("/health")
def health():
    return {"status": "ok", "host": socket.gethostname(),
            "uptime_seconds": round(time.time() - START_TIME, 1)}

@app.post("/invoke")
def invoke(req: InvokeRequest):
    return {"host": socket.gethostname(), "echo": req.input}
'@
        Set-Content -Path (Join-Path $InstallRoot 'main.py') -Value $mainPy -Encoding utf8
        Set-Content -Path (Join-Path $InstallRoot 'requirements.txt') -Value "fastapi>=0.110`nuvicorn[standard]>=0.29`npydantic>=2.6" -Encoding utf8
    }

    $venvPath = Join-Path $InstallRoot '.venv'
    if (-not (Test-Path $venvPath)) {
        if ($PSCmdlet.ShouldProcess($venvPath, 'python -m venv')) {
            & python -m venv $venvPath
        }
    }
    $venvPython = Join-Path $venvPath 'Scripts\python.exe'
    if (Test-Path $venvPython) {
        & $venvPython -m pip install -r (Join-Path $InstallRoot 'requirements.txt')
    }

    if (Get-Service -Name $ServiceName -ErrorAction SilentlyContinue) {
        Write-Ok "Service '$ServiceName' already registered. Restarting to pick up changes."
        if ($PSCmdlet.ShouldProcess($ServiceName, 'Restart-Service')) {
            Restart-Service -Name $ServiceName
        }
        return
    }

    if (-not $PSCmdlet.ShouldProcess($ServiceName, 'nssm install (register Windows Service)')) { return }

    $uvicornArgs = "-m uvicorn main:app --host 0.0.0.0 --port $Port"
    nssm install $ServiceName $venvPython
    nssm set $ServiceName AppParameters $uvicornArgs
    nssm set $ServiceName AppDirectory $InstallRoot
    nssm set $ServiceName DisplayName "ara.ao Local Agent ($NodeRole)"
    nssm set $ServiceName Description 'Local-only FastAPI agent runtime for ara.ao (no cloud dependency).'
    nssm set $ServiceName Start SERVICE_AUTO_START
    nssm set $ServiceName AppStdout (Join-Path $InstallRoot 'service.out.log')
    nssm set $ServiceName AppStderr (Join-Path $InstallRoot 'service.err.log')
    nssm start $ServiceName

    New-NetFirewallRule -Name "AraAo-$Port-In-TCP" -DisplayName "ara.ao agent (port $Port)" `
        -Enabled True -Direction Inbound -Protocol TCP -Action Allow -LocalPort $Port `
        -ErrorAction SilentlyContinue | Out-Null

    Write-Ok "ara.ao agent registered as service '$ServiceName' on port $Port."
    Write-Info "Health check: http://localhost:$Port/health"
}

#endregion

try {
    Write-Host "Windows Server VM Node Bootstrap ($NodeRole)" -ForegroundColor Cyan
    Write-Host ('-' * 50) -ForegroundColor Cyan
    Write-Info 'Scope: Hyper-V host + OpenSSH Server + ara.ao service. NOT a Failover Cluster (by design).'

    if (-not $SkipHyperV) {
        Enable-HyperVRole
        New-DomainControllerVmShell
    }
    else {
        Write-Info 'Skipping Hyper-V role (per -SkipHyperV).'
    }

    if (-not $SkipSsh) {
        Enable-OpenSshServer
    }
    else {
        Write-Info 'Skipping OpenSSH Server (per -SkipSsh).'
    }

    if (-not $SkipAraAo) {
        Install-AraAoService -Port $AraAoPort
    }
    else {
        Write-Info 'Skipping ara.ao service install (per -SkipAraAo).'
    }

    Write-Host "`n=== [$NodeRole] Node bootstrap complete ===" -ForegroundColor Green
    Write-Host 'Next steps:' -ForegroundColor White
    Write-Host '  1. If Hyper-V was just installed, reboot this VM, then re-run this script.' -ForegroundColor White
    Write-Host '  2. Attach a Windows Server ISO to the DC VM shell and install the OS.' -ForegroundColor White
    Write-Host '  3. Promote the DC VM deliberately (Install-ADDSForest / Install-ADDSDomainController).' -ForegroundColor White
    Write-Host '  4. From your Mac: ssh <user>@<this-host> to verify remote access.' -ForegroundColor White
    Write-Host '  5. Repeat this script on the other node with -NodeRole Secondary.' -ForegroundColor White
    Write-Host '  6. Run arao-failover-monitor.ps1 on the Secondary node once both /health endpoints respond.' -ForegroundColor White
}
catch {
    Write-Host "[ERR] Node bootstrap failed: $_" -ForegroundColor Red
    exit 1
}
