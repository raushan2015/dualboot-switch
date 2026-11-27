#Requires -Version 5.1
<#
.SYNOPSIS
    Installs the one-click "Reboot to Ubuntu" tool.

.DESCRIPTION
    1. Lets you pick the Ubuntu UEFI boot entry (saved to config.json).
    2. Registers a scheduled task "RebootToUbuntu" that runs with highest privileges,
       so the shortcut can switch OS without a UAC prompt.
    3. Creates "Reboot to Ubuntu" shortcuts on the Desktop and in the Start Menu.

.PARAMETER NoConfirm          Shortcut reboots immediately without a Yes/No dialog.
.PARAMETER NoDesktopShortcut  Only create the Start Menu shortcut.
.PARAMETER Delay              Seconds before restart (0 = recommended; >0 force-closes apps).
#>
param(
    [switch]$NoConfirm,
    [switch]$NoDesktopShortcut,
    [ValidateRange(0, 600)]
    [int]$Delay = 0
)

$ErrorActionPreference = 'Stop'

$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
if (-not (New-Object Security.Principal.WindowsPrincipal $identity).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)) {
    $argList = @('-NoExit', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`"")
    if ($NoConfirm)         { $argList += '-NoConfirm' }
    if ($NoDesktopShortcut) { $argList += '-NoDesktopShortcut' }
    $argList += @('-Delay', $Delay)
    Start-Process -FilePath (Get-Process -Id $PID).Path -ArgumentList $argList -Verb RunAs
    exit
}

$TaskName = 'RebootToUbuntu'
$core     = Join-Path $PSScriptRoot 'RebootToUbuntu.ps1'
$launcher = Join-Path $PSScriptRoot 'Launcher.ps1'
$psExe    = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'

# ---- 1. choose the boot entry
Write-Host "`n== Step 1/3: choose the Ubuntu boot entry ==" -ForegroundColor Cyan
& $core -Setup
if ($LASTEXITCODE -ne 0 -or -not (Test-Path (Join-Path $PSScriptRoot 'config.json'))) {
    throw 'Setup did not complete. Plug in the external SSD and try again.'
}

# ---- 2. elevated scheduled task (lets the shortcut run without UAC)
Write-Host "`n== Step 2/3: registering scheduled task '$TaskName' ==" -ForegroundColor Cyan
$action = New-ScheduledTaskAction -Execute $psExe -WorkingDirectory $PSScriptRoot -Argument (
    "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$core`" -Unattended -Delay $Delay")
$principal = New-ScheduledTaskPrincipal -UserId $identity.Name -LogonType Interactive -RunLevel Highest
$settings  = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
                 -ExecutionTimeLimit (New-TimeSpan -Minutes 5) -MultipleInstances IgnoreNew
Register-ScheduledTask -TaskName $TaskName -Action $action -Principal $principal -Settings $settings `
    -Description 'One-time reboot into Ubuntu (UEFI BootNext). Started by the "Reboot to Ubuntu" shortcut.' `
    -Force | Out-Null
Write-Host 'Done.' -ForegroundColor Green

# ---- 3. shortcuts
Write-Host "`n== Step 3/3: creating shortcuts ==" -ForegroundColor Cyan
$folders = @([Environment]::GetFolderPath('Programs'))
if (-not $NoDesktopShortcut) { $folders += [Environment]::GetFolderPath('Desktop') }

$shell = New-Object -ComObject WScript.Shell
foreach ($folder in $folders) {
    $path = Join-Path $folder 'Reboot to Ubuntu.lnk'
    $lnk  = $shell.CreateShortcut($path)
    $lnk.TargetPath       = $psExe
    $lnk.Arguments        = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$launcher`"" +
                            $(if ($NoConfirm) { ' -NoConfirm' } else { '' })
    $lnk.WorkingDirectory = $PSScriptRoot
    $lnk.IconLocation     = "$env:SystemRoot\System32\shell32.dll,27"
    $lnk.Description      = 'Restart directly into Ubuntu (one-time boot)'
    $lnk.WindowStyle      = 7   # minimized
    $lnk.Save()
    Write-Host "Created $path"
}

Write-Host "`nAll set! Use the 'Reboot to Ubuntu' shortcut (Desktop / Start Menu)." -ForegroundColor Green
Write-Host 'Tip: right-click the Start Menu entry > Pin to Start / taskbar.'
