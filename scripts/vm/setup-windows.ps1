#Requires -RunAsAdministrator
<#
.SYNOPSIS
    One-time setup for a WinBridge Flutter build VM.

.DESCRIPTION
    Run this inside the Windows guest (via the dockur/windows web viewer or
    RDP — see docs/vm-setup.md, which this script is not a substitute for).
    It installs everything `winbridge vm doctor` and `winbridge build` expect
    to find on the VM: Git, the Flutter SDK, Visual Studio Build Tools with
    the C++ desktop workload, rsync, and a key-authenticated OpenSSH server.

    Safe to re-run: every step checks whether it already did its job before
    doing it again.

.PARAMETER PublicKey
    The contents of the SSH public key file WinBridge should be allowed to
    connect with (the .pub half of the identityFile in
    ~/.config/winbridge/vm.json on the Linux host). Generate one there first:

        ssh-keygen -t ed25519 -f ~/.ssh/id_winbridge_vm -N ""
        cat ~/.ssh/id_winbridge_vm.pub

    then paste the output as this parameter.

.EXAMPLE
    .\setup-windows.ps1 -PublicKey "ssh-ed25519 AAAA... you@host"
#>
param(
    [Parameter(Mandatory = $true)]
    [string]$PublicKey,

    [string]$FlutterRoot = 'C:\tools\flutter',

    [string]$FlutterChannel = 'stable'
)

$ErrorActionPreference = 'Stop'

function Write-Step($message) {
    Write-Host ""
    Write-Host "==> $message" -ForegroundColor Cyan
}

function Test-Command($name) {
    return [bool](Get-Command $name -ErrorAction SilentlyContinue)
}

# ---------------------------------------------------------------------------
# Git
# ---------------------------------------------------------------------------
Write-Step 'Git for Windows'
if (Test-Command git) {
    Write-Host 'already installed'
} else {
    winget install --id Git.Git --source winget --accept-package-agreements --accept-source-agreements
}

# ---------------------------------------------------------------------------
# Visual Studio Build Tools + the C++ desktop workload (what flutter build
# windows actually shells out to via CMake/MSBuild).
# ---------------------------------------------------------------------------
Write-Step 'Visual Studio Build Tools (C++ desktop workload)'
$vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
$hasVCTools = $false
if (Test-Path $vswhere) {
    $installed = & $vswhere -latest -products * `
        -requires Microsoft.VisualStudio.Workload.VCTools -property installationPath
    $hasVCTools = [bool]$installed
}
if ($hasVCTools) {
    Write-Host 'already installed'
} else {
    winget install --id Microsoft.VisualStudio.2022.BuildTools --source winget `
        --accept-package-agreements --accept-source-agreements --override `
        '--quiet --wait --add Microsoft.VisualStudio.Workload.VCTools --includeRecommended'
}

# ---------------------------------------------------------------------------
# Flutter SDK — installed by cloning the release branch directly, which is
# what flutter.dev itself documents for Windows and avoids depending on a
# winget/choco package that may lag the SDK.
# ---------------------------------------------------------------------------
Write-Step "Flutter SDK ($FlutterChannel) at $FlutterRoot"
if (Test-Path (Join-Path $FlutterRoot 'bin\flutter.bat')) {
    Write-Host 'already installed'
} else {
    git clone --branch $FlutterChannel https://github.com/flutter/flutter.git "$FlutterRoot"
}

$flutterBin = Join-Path $FlutterRoot 'bin'
$machinePath = [Environment]::GetEnvironmentVariable('Path', 'Machine')
if ($machinePath -notlike "*$flutterBin*") {
    [Environment]::SetEnvironmentVariable('Path', "$machinePath;$flutterBin", 'Machine')
}
$env:Path = "$env:Path;$flutterBin"

& "$flutterBin\flutter.bat" config --enable-windows-desktop
& "$flutterBin\flutter.bat" precache --windows

# ---------------------------------------------------------------------------
# rsync — winbridge fetches build output over rsync-via-ssh, so the VM needs
# a server-side rsync too, not just the Linux host. There is no official
# winget package for it; Chocolatey's does the job.
# ---------------------------------------------------------------------------
Write-Step 'rsync'
if (Test-Command rsync) {
    Write-Host 'already installed'
} else {
    if (-not (Test-Command choco)) {
        Write-Step 'Chocolatey (needed for rsync)'
        Set-ExecutionPolicy Bypass -Scope Process -Force
        [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor 3072
        Invoke-Expression ((New-Object System.Net.WebClient).DownloadString('https://community.chocolatey.org/install.ps1'))
        $env:Path = "$env:Path;$env:ALLUSERSPROFILE\chocolatey\bin"
    }
    choco install rsync -y
}

# ---------------------------------------------------------------------------
# OpenSSH Server, key-only auth for $PublicKey.
# ---------------------------------------------------------------------------
Write-Step 'OpenSSH Server'
$sshdCapability = Get-WindowsCapability -Online -Name 'OpenSSH.Server~~~~0.0.1.0'
if ($sshdCapability.State -ne 'Installed') {
    Add-WindowsCapability -Online -Name 'OpenSSH.Server~~~~0.0.1.0' | Out-Null
}

Start-Service sshd
Set-Service -Name sshd -StartupType Automatic

if (-not (Get-NetFirewallRule -Name 'OpenSSH-Server-In-TCP' -ErrorAction SilentlyContinue)) {
    New-NetFirewallRule -Name 'OpenSSH-Server-In-TCP' -DisplayName 'OpenSSH SSH Server (sshd)' `
        -Enabled True -Direction Inbound -Protocol TCP -Action Allow -LocalPort 22 | Out-Null
}

# Administrators use a single shared authorized_keys file with locked-down
# ACLs, not the per-user ~/.ssh one; sshd on Windows silently ignores the
# per-user file for accounts in the Administrators group. This assumes the
# account WinBridge connects as is an administrator, which is the common case
# for a single-purpose build VM — see docs/vm-setup.md if it is not.
Write-Step 'Authorizing the WinBridge public key'
$authorizedKeysPath = 'C:\ProgramData\ssh\administrators_authorized_keys'
$existing = if (Test-Path $authorizedKeysPath) { Get-Content $authorizedKeysPath } else { @() }
if ($existing -notcontains $PublicKey) {
    Add-Content -Path $authorizedKeysPath -Value $PublicKey
}

icacls $authorizedKeysPath /inheritance:r | Out-Null
icacls $authorizedKeysPath /grant 'Administrators:F' | Out-Null
icacls $authorizedKeysPath /grant 'SYSTEM:F' | Out-Null

Restart-Service sshd

Write-Step 'Done'
Write-Host 'flutter --version:'
& "$flutterBin\flutter.bat" --version
Write-Host ''
Write-Host 'Next: from the Linux host, run `winbridge vm doctor`.'
Write-Host 'If this is the VM''s first connection, add --accept-new once.'
