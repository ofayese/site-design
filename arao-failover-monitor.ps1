#Requires -Version 5.1
<#
.SYNOPSIS
    Lightweight HA monitor for the ara.ao agent across two nodes (Akoda/Geekom).
    NOT a Windows Failover Cluster: no quorum, no CSV, no live migration.
    Polls the primary node's /health endpoint; if it fails N consecutive checks,
    promotes the local (standby) ara.ao service to active and flips a simple
    DNS-style pointer via the local hosts file (or a CNAME you manage in your
    resolver, if preferred).

.PARAMETER PrimaryHost
    Hostname or IP of the primary ara.ao node (e.g. Akoda).

.PARAMETER LocalRole
    'Primary' or 'Standby'. Run this script on the STANDBY node.

.PARAMETER Port
    ara.ao agent port (default 8765, must match windows-server-vm-bootstrap.ps1).

.PARAMETER FailureThreshold
    Consecutive failed health checks before failover triggers. Default 3.

.PARAMETER IntervalSeconds
    Seconds between health checks. Default 10.

.PARAMETER ServiceAliasHost
    The stable hostname clients use to reach "the active ara.ao node"
    (e.g. arao.olutech.systems). This script updates the local hosts file
    mapping so that name resolves to whichever node is currently active.
    For a cleaner setup, point this at a resolver you control instead.

.EXAMPLE
    .\arao-failover-monitor.ps1 -PrimaryHost akoda.olutech.systems -LocalRole Standby -ServiceAliasHost arao.olutech.systems
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$PrimaryHost,
    [ValidateSet('Primary', 'Standby')]
    [string]$LocalRole = 'Standby',
    [int]$Port = 8765,
    [int]$FailureThreshold = 3,
    [int]$IntervalSeconds = 10,
    [string]$ServiceAliasHost = '',
    [string]$ServiceName = 'AraAoAgent',
    [string]$LogPath = "$env:ProgramData\ara-ao\failover-monitor.log"
)

$ErrorActionPreference = 'Stop'
$script:ConsecutiveFailures = 0
$script:CurrentlyActive = ($LocalRole -eq 'Primary')

function Write-Log {
    param([string]$Message, [string]$Level = 'INFO')
    $line = "[{0}] [{1}] {2}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
    Write-Host $line
    $dir = Split-Path $LogPath -Parent
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    Add-Content -Path $LogPath -Value $line
}

function Test-NodeHealth {
    param([Parameter(Mandatory)][string]$TargetHost)
    try {
        $uri = "http://${TargetHost}:$Port/health"
        $resp = Invoke-RestMethod -Uri $uri -Method Get -TimeoutSec 5
        return ($resp.status -eq 'ok')
    }
    catch {
        return $false
    }
}

function Set-LocalAraAoServiceState {
    param([ValidateSet('Start', 'Stop')][string]$Action)
    $svc = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
    if (-not $svc) {
        Write-Log "Service '$ServiceName' not found on this node." 'WARN'
        return
    }
    if ($Action -eq 'Start' -and $svc.Status -ne 'Running') {
        Start-Service -Name $ServiceName
        Write-Log "Started local ara.ao service ($ServiceName)."
    }
    elseif ($Action -eq 'Stop' -and $svc.Status -eq 'Running') {
        Stop-Service -Name $ServiceName
        Write-Log "Stopped local ara.ao service ($ServiceName)."
    }
}

function Set-ServiceAliasTarget {
    # Simple hosts-file based pointer. Replace with a proper internal DNS
    # (idc.olutech.systems zone) update if you want this to apply cluster-wide
    # rather than per-client. This local version is enough for a 2-node setup
    # where clients query the alias via this node's resolver, or you manually
    # sync the hosts file entry to dependent clients.
    param([Parameter(Mandatory)][string]$TargetIp)

    if (-not $ServiceAliasHost) { return }

    $hostsPath = "$env:WINDIR\System32\drivers\etc\hosts"
    $existing = Get-Content $hostsPath -ErrorAction SilentlyContinue
    $filtered = $existing | Where-Object { $_ -notmatch [regex]::Escape($ServiceAliasHost) }
    $filtered + "$TargetIp`t$ServiceAliasHost" | Set-Content -Path $hostsPath -Force

    Write-Log "Updated hosts alias: $ServiceAliasHost -> $TargetIp"
}

function Invoke-Failover {
    Write-Log "PRIMARY ($PrimaryHost) unhealthy for $FailureThreshold consecutive checks. Promoting local standby node." 'ALERT'
    Set-LocalAraAoServiceState -Action 'Start'

    $localIp = (Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
                Where-Object { $_.IPAddress -notlike '127.*' -and $_.IPAddress -notlike '169.254.*' } |
                Select-Object -First 1).IPAddress
    if ($localIp) {
        Set-ServiceAliasTarget -TargetIp $localIp
    }

    $script:CurrentlyActive = $true
    Write-Log 'Failover complete. This node is now ACTIVE for ara.ao.' 'ALERT'
}

function Invoke-Failback {
    # Optional: called when primary comes back healthy while we're active.
    # Manual failback is safer than automatic for a 2-node setup (avoids
    # flapping); this just logs and leaves the operator to decide.
    Write-Log "PRIMARY ($PrimaryHost) is healthy again. This node is still ACTIVE. Manual failback recommended (re-run with -LocalRole Standby after confirming primary stability)." 'WARN'
}

Write-Log "Starting ara.ao failover monitor. Role=$LocalRole, Primary=$PrimaryHost, Threshold=$FailureThreshold, Interval=${IntervalSeconds}s"

if ($LocalRole -eq 'Standby') {
    Set-LocalAraAoServiceState -Action 'Stop'
}

while ($true) {
    $healthy = Test-NodeHealth -TargetHost $PrimaryHost

    if ($healthy) {
        if ($script:ConsecutiveFailures -gt 0) {
            Write-Log "Primary recovered after $($script:ConsecutiveFailures) failed checks."
        }
        $script:ConsecutiveFailures = 0

        if ($script:CurrentlyActive -and $LocalRole -eq 'Standby') {
            Invoke-Failback
        }
    }
    else {
        $script:ConsecutiveFailures++
        Write-Log "Health check failed for $PrimaryHost ($($script:ConsecutiveFailures)/$FailureThreshold)." 'WARN'

        if (-not $script:CurrentlyActive -and $script:ConsecutiveFailures -ge $FailureThreshold) {
            Invoke-Failover
        }
    }

    Start-Sleep -Seconds $IntervalSeconds
}
