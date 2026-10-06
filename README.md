# Windows 11 OpenSSH Server

Installs OpenSSH Server, enables automatic startup, and allows inbound SSH on TCP port 22.

Open **PowerShell as Administrator** on Windows 11 and paste this one-liner:

```powershell
Invoke-RestMethod -Uri 'https://raw.githubusercontent.com/w0ot-net/windows_ssh_server/main/setup-openssh-server.ps1' -ErrorAction Stop | Invoke-Expression
```

After successful setup, the script prints the authorized-key locations. Add your client's public key to the file for the Windows account you will connect to. Existing keys and configuration are preserved.
