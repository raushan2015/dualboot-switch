#Requires -Version 5.1
# Removes the scheduled task, shortcuts and any pending one-time boot.
$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
if (-not (New-Object Security.Principal.WindowsPrincipal $identity).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Start-Process -FilePath (Get-Process -Id $PID).Path -Verb RunAs `
        -ArgumentList @('-NoExit', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`"")
    exit
}

$TaskName = 'RebootToUbuntu'
if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) {
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
    Write-Host "Removed scheduled task '$TaskName'."
}

foreach ($folder in [Environment]::GetFolderPath('Programs'), [Environment]::GetFolderPath('Desktop')) {
    $path = Join-Path $folder 'Reboot to Ubuntu.lnk'
    if (Test-Path $path) { Remove-Item $path -Force; Write-Host "Removed $path" }
}

& bcdedit.exe /deletevalue '{fwbootmgr}' bootsequence 2>&1 | Out-Null
Write-Host 'Uninstalled. (config.json was kept; delete the folder to remove everything.)' -ForegroundColor Green
