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
    -WithPrinting additionally installs SumatraPDF for the print bridge (see
    docs/devices.md); nothing else here reaches for a peripheral.

    Safe to re-run: every step checks whether it already did its job before
    doing it again.

.PARAMETER PublicKey
    The contents of the SSH public key file WinBridge should be allowed to
    connect with (the .pub half of the identityFile in
    ~/.config/winbridge/vm.json on the Linux host). Generate one there first:

        ssh-keygen -t ed25519 -f ~/.ssh/id_winbridge_vm -N ""
        cat ~/.ssh/id_winbridge_vm.pub

    then paste the output as this parameter.

.PARAMETER WithPrinting
    Also installs SumatraPDF, for the print bridge in scripts/printing/ (see
    docs/devices.md). Off by default: most printers do not need this at all
    — check driverless IPP first — so this only downloads and installs
    anything when you explicitly ask for it.

.PARAMETER SumatraSha256
    Optional SHA-256 of the SumatraPDF release zip, verified after download.
    SumatraPDF publishes no checksum of its own, so there is nothing to pin by
    default; supply one here (Get-FileHash on a copy you have verified) to make
    every later run check what it downloaded.

.EXAMPLE
    .\setup-windows.ps1 -PublicKey "ssh-ed25519 AAAA... you@host"

.EXAMPLE
    .\setup-windows.ps1 -PublicKey "ssh-ed25519 AAAA... you@host" -WithPrinting
#>
param(
    [Parameter(Mandatory = $true)]
    [string]$PublicKey,

    [string]$FlutterRoot = 'C:\tools\flutter',

    [string]$FlutterChannel = 'stable',

    [switch]$WithPrinting,

    [string]$SumatraSha256
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
# SumatraPDF — only with -WithPrinting. This is what
# scripts/printing/winbridge-print.sh and print-vm-side.ps1 print through;
# see docs/devices.md for the full print bridge walkthrough and why
# driverless IPP is worth ruling out first.
# ---------------------------------------------------------------------------
if ($WithPrinting) {
    Write-Step 'SumatraPDF (silent printing)'
    $sumatraDir = 'C:\tools\sumatra'
    $sumatraExe = Join-Path $sumatraDir 'SumatraPDF.exe'
    if (Test-Path $sumatraExe) {
        Write-Host 'already installed'
    } else {
        $sumatraVersion = '3.6.1'
        $sumatraZipUrl = "https://www.sumatrapdfreader.org/dl/rel/$sumatraVersion/SumatraPDF-$sumatraVersion-64.zip"
        $sumatraZip = Join-Path $env:TEMP 'winbridge-sumatra.zip'
        $sumatraExtractDir = Join-Path $env:TEMP 'winbridge-sumatra-extract'

        # Windows PowerShell 5.1 can still default to TLS 1.0 here depending on
        # the host's .NET configuration, which fails against modern servers.
        [System.Net.ServicePointManager]::SecurityProtocol =
            [System.Net.ServicePointManager]::SecurityProtocol -bor 3072
        Invoke-WebRequest -Uri $sumatraZipUrl -OutFile $sumatraZip

        # SumatraPDF does not publish a checksum alongside its release zips, so
        # there is no vendor hash to pin by default and inventing one would only
        # break the install. The download is version-pinned and comes from the
        # project's own domain over TLS, which leaves the vendor and their CDN
        # trusted — pass -SumatraSha256 to close that gap: compute it once with
        # Get-FileHash on a copy you have checked, and every later run of this
        # script verifies against it.
        if ($SumatraSha256) {
            $actual = (Get-FileHash -Path $sumatraZip -Algorithm SHA256).Hash
            if ($actual -ne $SumatraSha256.Replace('-', '').ToUpperInvariant()) {
                Remove-Item $sumatraZip -Force
                throw "SumatraPDF checksum mismatch: expected $SumatraSha256, got $actual"
            }
            Write-Host 'checksum verified'
        } else {
            Write-Warning 'SumatraPDF downloaded without checksum verification; see -SumatraSha256'
        }

        if (Test-Path $sumatraExtractDir) {
            Remove-Item $sumatraExtractDir -Recurse -Force
        }
        Expand-Archive -Path $sumatraZip -DestinationPath $sumatraExtractDir -Force

        # The zip's internal exe name has carried the version number in it
        # across releases, so find it by extension instead of hardcoding one.
        $extractedExe = Get-ChildItem -Path $sumatraExtractDir -Filter '*.exe' -Recurse |
            Select-Object -First 1
        if (-not $extractedExe) {
            throw "SumatraPDF-$sumatraVersion-64.zip did not contain an .exe"
        }
        New-Item -ItemType Directory -Path $sumatraDir -Force | Out-Null
        Copy-Item -Path $extractedExe.FullName -Destination $sumatraExe -Force

        Remove-Item $sumatraZip -Force
        Remove-Item $sumatraExtractDir -Recurse -Force
    }
    Write-Host "SumatraPDF at $sumatraExe"
    Write-Host 'Install the printer''s own Windows driver normally (Settings > Printers)'
    Write-Host 'first — SumatraPDF only prints through it, it is not a driver itself.'
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

# Key-only authentication. Without this, sshd still accepts the account
# password — and the VM account's password is set from docker-compose.yml,
# which makes a guessable password the weakest link in a box that exists to
# run builds. WinBridge itself always connects with BatchMode=yes and never
# sends a password, so nothing here loses functionality.
Write-Step 'Disabling password authentication on sshd'
$sshdConfig = 'C:\ProgramData\ssh\sshd_config'
if (Test-Path $sshdConfig) {
    $config = Get-Content $sshdConfig
    $settings = [ordered]@{
        'PubkeyAuthentication'   = 'yes'
        'PasswordAuthentication' = 'no'
        'PermitEmptyPasswords'   = 'no'
    }
    foreach ($key in $settings.Keys) {
        # sshd takes the FIRST value it finds for a keyword, so appending is
        # only correct once every earlier occurrence is commented out.
        $config = $config -replace "^\s*#?\s*$key\s+.*$", "# (winbridge) was: `$0"
        $config += "$key $($settings[$key])"
    }

    # Never leave a VM with an sshd that will not start: validate the rewritten
    # file and put the original back if it does not parse.
    $backup = "$sshdConfig.winbridge.bak"
    Copy-Item $sshdConfig $backup -Force
    Set-Content -Path $sshdConfig -Value $config

    $sshdExe = Join-Path $env:SystemRoot 'System32\OpenSSH\sshd.exe'
    if (Test-Path $sshdExe) {
        & $sshdExe -t -f $sshdConfig
        if ($LASTEXITCODE -ne 0) {
            Copy-Item $backup $sshdConfig -Force
            throw "rewritten sshd_config failed validation; restored $backup"
        }
    } else {
        Write-Warning "sshd.exe not found; could not validate $sshdConfig"
    }
} else {
    Write-Warning "no sshd_config at $sshdConfig; check password auth by hand"
}

Restart-Service sshd

Write-Step 'Done'
Write-Host 'flutter --version:'
& "$flutterBin\flutter.bat" --version
if ($WithPrinting) {
    Write-Host "SumatraPDF: $sumatraExe"
}
Write-Host ''
Write-Host 'Next: from the Linux host, run `winbridge vm doctor`.'
Write-Host 'If this is the VM''s first connection, add --accept-new once.'
