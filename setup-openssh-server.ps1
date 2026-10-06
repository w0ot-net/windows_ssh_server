#Requires -Version 5.1
#Requires -RunAsAdministrator

<#
.SYNOPSIS
Sets up the built-in OpenSSH Server on Windows 11.

.DESCRIPTION
Installs OpenSSH Server if needed, starts sshd automatically, allows inbound
TCP port 22, and prepares the administrator authorized-keys file. Existing
keys and sshd_config are preserved. Running the script again is supported.

Run from an elevated, 64-bit Windows PowerShell or PowerShell terminal.
Installing the Windows feature may require access to Windows Update.
If installation requires a restart, restart Windows and run the script again.

The script uses port 22 and reports the Windows default authorized-key paths.
If you customized sshd_config, check its AuthorizedKeysFile and Match settings.
Authentication settings are left as configured by OpenSSH, including password
authentication on a fresh installation. Add your client's PUBLIC key as one
line in the appropriate authorized-keys file; never copy a private key there.
The administrator file is shared by all administrator accounts.

.EXAMPLE
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\setup-openssh-server.ps1

Run this command in a terminal opened with "Run as administrator".

.LINK
https://learn.microsoft.com/windows-server/administration/openssh/openssh_install_firstuse

.LINK
https://learn.microsoft.com/windows-server/administration/openssh/openssh_keymanagement
#>

[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ($env:OS -ne 'Windows_NT') {
    throw 'This script requires Windows 11.'
}

$os = Get-CimInstance -ClassName Win32_OperatingSystem
if ($os.ProductType -ne 1 -or [int]$os.BuildNumber -lt 22000) {
    throw 'This script supports Windows 11 client editions only.'
}
if (-not [Environment]::Is64BitProcess) {
    throw 'Run this script in a 64-bit PowerShell terminal.'
}

$capabilityName = 'OpenSSH.Server~~~~0.0.1.0'
$capability = Get-WindowsCapability -Online -Name $capabilityName
if ($capability.State -ne 'Installed') {
    Write-Host 'Installing OpenSSH Server...'
    $installation = Add-WindowsCapability -Online -Name $capabilityName
    if ($installation.RestartNeeded) {
        throw 'Installation requires a restart. Restart Windows, then run this script again.'
    }
    $capability = Get-WindowsCapability -Online -Name $capabilityName
    if ($capability.State -ne 'Installed') {
        throw 'OpenSSH Server installation did not reach the Installed state.'
    }
}

$sshDirectory = Join-Path $env:ProgramData 'ssh'
$authorizedKeysPath = Join-Path $sshDirectory 'administrators_authorized_keys'
$sshdPath = Join-Path $env:SystemRoot 'System32\OpenSSH\sshd.exe'
$configPath = Join-Path $sshDirectory 'sshd_config'

New-Item -ItemType Directory -Path $sshDirectory -Force | Out-Null
if (-not (Test-Path -LiteralPath $authorizedKeysPath)) {
    New-Item -ItemType File -Path $authorizedKeysPath | Out-Null
}
if (-not (Test-Path -LiteralPath $authorizedKeysPath -PathType Leaf)) {
    throw "The authorized-keys path is not a file: $authorizedKeysPath"
}

# Use SIDs so permissions also work on non-English Windows installations.
# Replace the DACL completely; removing inheritance alone leaves explicit ACEs.
$administrators = [System.Security.Principal.SecurityIdentifier]::new('S-1-5-32-544')
$system = [System.Security.Principal.SecurityIdentifier]::new('S-1-5-18')
$acl = [System.Security.AccessControl.FileSecurity]::new()
$acl.SetAccessRuleProtection($true, $false)
$acl.SetOwner($administrators)
foreach ($sid in @($administrators, $system)) {
    $rule = [System.Security.AccessControl.FileSystemAccessRule]::new(
        $sid,
        [System.Security.AccessControl.FileSystemRights]::FullControl,
        [System.Security.AccessControl.AccessControlType]::Allow
    )
    $acl.AddAccessRule($rule)
}
Set-Acl -LiteralPath $authorizedKeysPath -AclObject $acl

Write-Host 'Starting OpenSSH Server...'
Set-Service -Name sshd -StartupType Automatic
Start-Service -Name sshd
$service = Get-Service -Name sshd
$service.WaitForStatus('Running', [TimeSpan]::FromSeconds(30))

# Starting sshd on a fresh installation creates sshd_config and host keys.
& $sshdPath -t
if ($LASTEXITCODE -ne 0) {
    throw "OpenSSH configuration validation failed. Check $configPath."
}

# Confirm that this service, rather than another application, owns port 22.
$listenerReady = $false
for ($attempt = 0; $attempt -lt 20; $attempt++) {
    $serviceProcess = Get-CimInstance -ClassName Win32_Service -Filter "Name='sshd'"
    if ($serviceProcess.State -ne 'Running' -or $serviceProcess.ProcessId -eq 0) {
        throw 'The sshd service stopped before setup completed.'
    }
    $listeners = @(Get-NetTCPConnection -State Listen -ErrorAction SilentlyContinue)
    if ($listeners | Where-Object {
        $_.LocalPort -eq 22 -and $_.OwningProcess -eq $serviceProcess.ProcessId
    }) {
        $listenerReady = $true
        break
    }
    Start-Sleep -Milliseconds 500
}
if (-not $listenerReady) {
    throw "The sshd service is not listening on TCP port 22. Check $configPath."
}

$firewallRuleName = 'OpenSSH-Server-In-TCP'
$firewallRule = Get-NetFirewallRule -Name $firewallRuleName -ErrorAction SilentlyContinue
$firewallSettings = @{
    Enabled = 'True'
    Direction = 'Inbound'
    Action = 'Allow'
    Profile = 'Any'
    Protocol = 'TCP'
    LocalPort = 22
}
if ($firewallRule) {
    Set-NetFirewallRule -Name $firewallRuleName @firewallSettings
} else {
    New-NetFirewallRule -Name $firewallRuleName -DisplayName 'OpenSSH Server (sshd)' @firewallSettings | Out-Null
}

Write-Host ''
Write-Host 'OpenSSH Server setup completed successfully. sshd is running on TCP port 22.'
Write-Host 'Add your client public key to the file for the account you will SSH into.'
Write-Host "Existing custom key paths can be checked in: $configPath"
Write-Output "Administrator accounts: $authorizedKeysPath"
Write-Output 'Non-administrator accounts: %USERPROFILE%\.ssh\authorized_keys (in that account''s Windows profile)'
