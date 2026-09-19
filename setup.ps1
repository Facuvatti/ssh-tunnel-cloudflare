#Requires -Version 5.1
<#
.SYNOPSIS
    Sets up an SSH server (with a Cloudflare tunnel) or an SSH client on Windows.

.DESCRIPTION
    PowerShell port of setup.sh. Server mode: installs/starts OpenSSH Server,
    configures authentication, creates a Cloudflare tunnel and starts it via
    Docker Compose. Client mode: generates an SSH key pair and copies the
    public key to the server.
#>

[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# State
# ---------------------------------------------------------------------------
$script:ComposeStarted = $false
$script:ComposeDir     = $null

# ---------------------------------------------------------------------------
# Helper functions
# ---------------------------------------------------------------------------

function Test-IsAdmin {
    $identity  = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Test-CommandExists {
    param([Parameter(Mandatory)][string]$Name)
    return [bool](Get-Command $Name -ErrorAction SilentlyContinue)
}

function Read-YesNo {
    <# Asks a y/n question and returns $true for 'y'. Re-asks on invalid input. #>
    param([Parameter(Mandatory)][string]$Prompt)
    while ($true) {
        $answer = (Read-Host "$Prompt (y/n)").Trim().ToLower()
        if ($answer -eq 'y') { return $true }
        if ($answer -eq 'n') { return $false }
        Write-Host "Please answer 'y' or 'n'." -ForegroundColor Yellow
    }
}

function Invoke-ComposeDown {
    <# Stops the compose stack using the absolute path saved at startup. #>
    if (-not $script:ComposeDir) { return }
    Write-Host "Stopping Docker Compose services..."
    Push-Location $script:ComposeDir
    try {
        docker compose down
    }
    catch {
        Write-Warning "Failed to stop Docker Compose: $($_.Exception.Message)"
    }
    finally {
        Pop-Location
    }
}

function Set-SshdOption {
    <#
    Sets (or replaces) a single option in sshd_config.
    Backs up the file first and validates the result with `sshd -t`,
    rolling back if the new config is invalid.
    #>
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Value
    )

    $configPath = Join-Path $env:ProgramData 'ssh\sshd_config'
    $backupPath = "$configPath.bak"

    Copy-Item -Path $configPath -Destination $backupPath -Force

    # Remove existing (commented or not) lines for this option.
    $lines = Get-Content -Path $configPath |
        Where-Object { $_ -notmatch "^\s*#?\s*$Name\b" }

    # Options must appear before any "Match" block, otherwise they only
    # apply inside that block. Insert at the top of the file.
    $newLines = @("$Name $Value") + $lines
    Set-Content -Path $configPath -Value $newLines -Encoding ascii

    $sshdExe = Join-Path $env:WINDIR 'System32\OpenSSH\sshd.exe'
    & $sshdExe -t 2>$null
    if ($LASTEXITCODE -ne 0) {
        Write-Host "❌ sshd config test failed. Restoring backup." -ForegroundColor Red
        Copy-Item -Path $backupPath -Destination $configPath -Force
        throw "Invalid sshd_config after setting '$Name'. Check with: sshd -t"
    }
}

function Get-SshdEffectivePasswordAuth {
    $sshdExe = Join-Path $env:WINDIR 'System32\OpenSSH\sshd.exe'
    $output  = & $sshdExe -T 2>$null
    $match   = $output | Select-String -Pattern '^passwordauthentication\s+(\w+)' |
               Select-Object -First 1
    if ($match) { return $match.Matches[0].Groups[1].Value }
    return $null
}

# ---------------------------------------------------------------------------
# Server setup
# ---------------------------------------------------------------------------

function Install-SshServer {
    Write-Host "🔐 Checking SSH server status..."

    # 1. Install OpenSSH Server capability if missing
    $capability = Get-WindowsCapability -Online -Name 'OpenSSH.Server*' |
                  Select-Object -First 1
    if ($capability.State -ne 'Installed') {
        Write-Host "OpenSSH Server not found. Installing..."
        Add-WindowsCapability -Online -Name $capability.Name | Out-Null
        Write-Host "✅ OpenSSH Server installed."
    }
    else {
        Write-Host "✅ OpenSSH Server already installed."
    }

    # 2. Ensure the service is enabled and running
    $service = Get-Service -Name 'sshd'
    if ($service.Status -eq 'Running') {
        Write-Host "✅ SSH service is already running."
    }
    else {
        Write-Host "Starting and enabling SSH service..."
        Set-Service -Name 'sshd' -StartupType Automatic
        Start-Service -Name 'sshd'
        Write-Host "✅ SSH service started."
    }

    # Make sure the firewall rule exists (the capability usually creates it)
    if (-not (Get-NetFirewallRule -Name 'OpenSSH-Server-In-TCP' -ErrorAction SilentlyContinue)) {
        New-NetFirewallRule -Name 'OpenSSH-Server-In-TCP' -DisplayName 'OpenSSH Server (sshd)' `
            -Enabled True -Direction Inbound -Protocol TCP -Action Allow -LocalPort 22 | Out-Null
        Write-Host "✅ Firewall rule created for port 22."
    }
}

function Test-HasAuthorizedKeys {
    # On Windows, admin accounts use a shared file instead of ~/.ssh.
    $userFile  = Join-Path $HOME '.ssh\authorized_keys'
    $adminFile = Join-Path $env:ProgramData 'ssh\administrators_authorized_keys'

    foreach ($file in @($userFile, $adminFile)) {
        if ((Test-Path $file) -and ((Get-Item $file).Length -gt 0)) {
            $count = @(Select-String -Path $file -Pattern '^ssh-|^ecdsa-' -ErrorAction SilentlyContinue).Count
            Write-Host "✅ Authorized keys found ($count key(s)) in $file."
            return $true
        }
    }
    Write-Host "⚠️  No authorized keys found. Password authentication is needed for initial key setup."
    return $false
}

function Enable-PasswordAuthIfNeeded {
    param([bool]$HasKeys)

    if ($HasKeys) {
        Write-Host "Keys exist; leaving PasswordAuthentication unchanged."
        return
    }

    if ((Get-SshdEffectivePasswordAuth) -eq 'yes') {
        Write-Host "✅ PasswordAuthentication is already enabled."
        return
    }

    Write-Host "Enabling PasswordAuthentication in sshd_config..."
    Set-SshdOption -Name 'PasswordAuthentication' -Value 'yes'
    Restart-Service -Name 'sshd'
    Write-Host "✅ PasswordAuthentication enabled and SSH restarted."
}

function Install-Cloudflared {
    if (Test-CommandExists 'cloudflared') {
        Write-Host "cloudflared is already installed at $((Get-Command cloudflared).Source)"
        return
    }

    if (-not (Test-CommandExists 'winget')) {
        throw "winget is not available. Install cloudflared manually from https://github.com/cloudflare/cloudflared/releases"
    }

    Write-Host "Installing cloudflared with winget..."
    winget install --id Cloudflare.cloudflared --exact --silent `
        --accept-package-agreements --accept-source-agreements

    # Refresh PATH for the current session so the new binary is found.
    $env:Path = [Environment]::GetEnvironmentVariable('Path', 'Machine') + ';' +
                [Environment]::GetEnvironmentVariable('Path', 'User')

    if (-not (Test-CommandExists 'cloudflared')) {
        throw "cloudflared was installed but is not on PATH. Open a new terminal and run the script again."
    }
}

function New-CloudflareTunnel {
    param([Parameter(Mandatory)][string]$ProjectRoot)

    $cloudflaredDir = Join-Path $ProjectRoot 'cloudflared'
    $dockerDir      = Join-Path $ProjectRoot 'docker'

    foreach ($dir in @($cloudflaredDir, $dockerDir)) {
        if (-not (Test-Path $dir)) { throw "Directory not found: $dir" }
    }

    Push-Location $cloudflaredDir
    try {
        # Authenticate if there is no certificate yet
        $certFile = Join-Path $cloudflaredDir 'cert.pem'
        if (Test-Path $certFile) {
            Write-Host "Authentication file found!"
        }
        else {
            Write-Host "Authenticate in a browser, this won't go on until you log in."
            cloudflared tunnel login
        }

        $tunnelName = (Read-Host "Tunnel name [my-tunnel]").Trim()
        if ([string]::IsNullOrWhiteSpace($tunnelName)) { $tunnelName = 'my-tunnel' }

        Write-Host "Creating tunnel with name: $tunnelName"
        cloudflared tunnel create $tunnelName

        # Use JSON output instead of parsing text columns (more robust).
        $tunnels    = cloudflared tunnel list --output json | ConvertFrom-Json
        $tunnel     = $tunnels | Where-Object { $_.name -eq $tunnelName } | Select-Object -First 1
        if (-not $tunnel) { throw "Tunnel UUID not found: $tunnelName" }

        $tunnelUuid = $tunnel.id
        Write-Host "Tunnel UUID: $tunnelUuid"

        $configFile = Join-Path $cloudflaredDir 'config.yaml'
        if (-not (Test-Path $configFile)) { throw "Config file not found: $configFile" }

        (Get-Content -Path $configFile -Raw) -replace '<TUNNEL_UUID>', $tunnelUuid |
            Set-Content -Path $configFile -NoNewline -Encoding utf8
    }
    finally {
        Pop-Location
    }

    return $dockerDir
}

function Start-ComposeStack {
    param([Parameter(Mandatory)][string]$DockerDir)

    if (-not (Test-CommandExists 'docker')) {
        throw "Docker is not installed or not on PATH."
    }

    $script:ComposeDir = $DockerDir
    Push-Location $DockerDir
    try {
        $script:ComposeStarted = $true
        docker compose up -d
        Start-Sleep -Seconds 3

        $running = docker compose ps --status running
        if ($running -match 'cloudflare-tunnel') {
            Write-Host "Cloudflared is running via Docker Compose."
        }
        else {
            Write-Host "Container failed to start. Logs:" -ForegroundColor Red
            docker compose logs cloudflared
            throw "Cloudflared container failed to start."
        }
    }
    finally {
        Pop-Location
    }
}

function Show-SshConnectionInfo {
    $sshUser = $env:USERNAME

    # First IPv4 address that is not loopback / link-local (169.254.x.x).
    $sshIp = Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
             Where-Object { $_.IPAddress -notmatch '^(127\.|169\.254\.)' } |
             Select-Object -First 1 -ExpandProperty IPAddress

    # Port from sshd_config (default 22 when not set).
    $sshPort = 22
    $configPath = Join-Path $env:ProgramData 'ssh\sshd_config'
    if (Test-Path $configPath) {
        $portLine = Select-String -Path $configPath -Pattern '^\s*Port\s+(\d+)' |
                    Select-Object -First 1
        if ($portLine) { $sshPort = [int]$portLine.Matches[0].Groups[1].Value }
    }

    $sshInfo = "$sshUser@$sshIp -p $sshPort"
    Write-Host "⚠️ ¡IMPORTANT! You need to remember this to connect from the client" -ForegroundColor Yellow
    Write-Host "🔑 SSH connection info: $sshInfo" -ForegroundColor Green

    try {
        Set-Clipboard -Value $sshInfo
        Write-Host "📋 Copied to clipboard."
    }
    catch {
        Write-Host "Could not copy to clipboard: $($_.Exception.Message)"
    }
}

function Invoke-ServerSetup {
    if (-not (Test-IsAdmin)) {
        throw "Server setup needs an elevated PowerShell. Right-click PowerShell and choose 'Run as administrator'."
    }

    Install-SshServer
    $hasKeys = Test-HasAuthorizedKeys
    Enable-PasswordAuthIfNeeded -HasKeys $hasKeys

    Install-Cloudflared
    $dockerDir = New-CloudflareTunnel -ProjectRoot $PSScriptRoot
    Start-ComposeStack -DockerDir $dockerDir
    Show-SshConnectionInfo

    Read-Host "Press Enter to exit" | Out-Null
}

# ---------------------------------------------------------------------------
# Client setup
# ---------------------------------------------------------------------------

function Install-SshClient {
    Write-Host "🔑 Checking SSH client status..."
    if (Test-CommandExists 'ssh') {
        Write-Host "✅ ssh already installed at $((Get-Command ssh).Source)"
        return
    }

    if (-not (Test-IsAdmin)) {
        throw "ssh not found. Run this script as administrator once to install the OpenSSH Client."
    }

    Write-Host "ssh not found. Installing OpenSSH Client..."
    $capability = Get-WindowsCapability -Online -Name 'OpenSSH.Client*' | Select-Object -First 1
    Add-WindowsCapability -Online -Name $capability.Name | Out-Null
    Write-Host "✅ OpenSSH Client installed."
}

function Set-PrivateKeyPermissions {
    <# Windows equivalent of chmod 600: only the current user can access the file. #>
    param([Parameter(Mandatory)][string]$Path)

    icacls $Path /inheritance:r | Out-Null
    icacls $Path /grant:r "${env:USERNAME}:(R,W)" | Out-Null
}

function Copy-PublicKeyToServer {
    <# ssh-copy-id does not exist on Windows, so we append the key manually. #>
    param(
        [Parameter(Mandatory)][string]$PublicKeyPath,
        [Parameter(Mandatory)][string]$User,
        [Parameter(Mandatory)][string]$HostName,
        [Parameter(Mandatory)][int]$Port
    )

    $publicKey = (Get-Content -Path $PublicKeyPath -Raw).Trim()

    # Remote command (Linux server): create ~/.ssh, fix permissions, append key
    # only if it is not already there.
    $remoteCommand = @"
umask 077; mkdir -p ~/.ssh; touch ~/.ssh/authorized_keys; grep -qxF '$publicKey' ~/.ssh/authorized_keys || echo '$publicKey' >> ~/.ssh/authorized_keys; chmod 700 ~/.ssh; chmod 600 ~/.ssh/authorized_keys
"@

    ssh -p $Port "$User@$HostName" $remoteCommand
    return ($LASTEXITCODE -eq 0)
}

function Invoke-ClientSetup {
    Install-SshClient

    $sshDir  = Join-Path $HOME '.ssh'
    $keyPath = Join-Path $sshDir 'id_ed25519'

    if (-not (Test-Path $sshDir)) {
        New-Item -ItemType Directory -Path $sshDir | Out-Null
    }

    if (Test-Path $keyPath) {
        Write-Host "⚠️  Key already exists at $keyPath."
        return
    }

    if (-not (Read-YesNo "Do you want to generate a new key pair? (is it safer than using only a password)")) {
        Write-Host "Nothing was changed."
        return
    }

    # --- Generate key pair ---
    Write-Host "Generating Ed25519 key pair..."
    $securePass = Read-Host "Enter a password for the key (it can be empty)" -AsSecureString
    $bstr       = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($securePass)
    try {
        $passphrase = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
    }
    finally {
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
    }

    # Windows PowerShell 5.1 drops empty-string arguments to native commands,
    # so an empty passphrase must be passed as literal quotes.
    $passArg = if ([string]::IsNullOrEmpty($passphrase)) { '""' } else { $passphrase }
    ssh-keygen -t ed25519 -f $keyPath -N $passArg
    if ($LASTEXITCODE -ne 0) { throw "ssh-keygen failed." }
    Write-Host "✅ Key generated at $keyPath"

    Set-PrivateKeyPermissions -Path $keyPath
    Write-Host "✅ Client-side permissions set (private key restricted to your user)."

    # --- Collect server data ---
    Write-Host "If you executed setup on the server, you received 'user@ip -p port'"
    Write-Host "Example: admin@192.168.0.100 -p 22"
    Write-Host "Now is when you need to remember it"

    $sshUser = (Read-Host "Remote user").Trim()
    $sshHost = (Read-Host "Remote IP").Trim()
    $portStr = (Read-Host "Remote SSH port [22]").Trim()

    if ([string]::IsNullOrWhiteSpace($sshUser) -or [string]::IsNullOrWhiteSpace($sshHost)) {
        throw "User and host cannot be empty."
    }

    $sshPort = 22
    if (-not [string]::IsNullOrWhiteSpace($portStr)) {
        if (-not [int]::TryParse($portStr, [ref]$sshPort) -or $sshPort -lt 1 -or $sshPort -gt 65535) {
            throw "Invalid port: $portStr"
        }
    }

    # --- Copy public key ---
    Write-Host "Copying public key to $sshUser@$sshHost..."
    if (Copy-PublicKeyToServer -PublicKeyPath "$keyPath.pub" -User $sshUser -HostName $sshHost -Port $sshPort) {
        Write-Host "✅ Public key copied to server."
    }
    else {
        throw "Failed to copy public key. Check your password and server details."
    }

    # --- Verify key-based login ---
    Write-Host "Verifying key-based login..."
    ssh -i $keyPath -p $sshPort -o BatchMode=yes -o ConnectTimeout=5 "$sshUser@$sshHost" 'echo ok' *> $null
    if ($LASTEXITCODE -eq 0) {
        Write-Host "✅ Key-based login works."
    }
    else {
        throw "Key-based login failed. Aborting before any further changes."
    }

    Write-Host "If you want to disable password authentication (recommended for safety), run this in a LOCAL session of the server (not over remote SSH):"
    Write-Host "echo 'PasswordAuthentication no' | sudo tee /etc/ssh/sshd_config.d/99-disable-password.conf > /dev/null && sudo sshd -t && sudo systemctl restart ssh"
    Write-Host "And try logging in again with the generated key."
    Write-Host "✅ Client setup complete."
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

try {
    Write-Host "If you don't know what's the difference between server and client, use Ctrl + C and ask an AI before running this script."
    $isServer = Read-YesNo "Is this the server or client? (y = server, n = client)"

    if ($isServer) { Invoke-ServerSetup } else { Invoke-ClientSetup }
}
catch [System.Management.Automation.PipelineStoppedException] {
    # Ctrl + C was pressed.
    Write-Host ""
    Write-Host "You used Ctrl + C to stop the script."
    if ($script:ComposeStarted) {
        Write-Host "ℹ️  Docker Compose services were already started; they were NOT torn down."
        if (Read-YesNo "Do you want to stop them now?") {
            Invoke-ComposeDown
        }
        else {
            Write-Host "ℹ️  Docker Compose services were left running."
        }
    }
    exit 130
}
catch {
    Write-Host "❌ $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}