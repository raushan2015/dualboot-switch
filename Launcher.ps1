# Non-elevated launcher used by the "Reboot to Ubuntu" shortcut.
# Asks for confirmation, then starts the pre-elevated scheduled task (no UAC prompt).
param(
    [switch]$NoConfirm,
    [string]$TaskName = 'RebootToUbuntu'
)

Add-Type -AssemblyName PresentationFramework

$name    = 'Ubuntu'
$cfgPath = Join-Path $PSScriptRoot 'config.json'
if (Test-Path $cfgPath) {
    try { $name = (Get-Content $cfgPath -Raw | ConvertFrom-Json).Description } catch { }
}

if (-not $NoConfirm) {
    $r = [System.Windows.MessageBox]::Show(
        "Restart now and boot into '$name'?`n`nSave your work first - open apps will be asked to close.",
        'Reboot to Ubuntu', 'YesNo', 'Question')
    if ($r -ne 'Yes') { exit 0 }
}

$out = & schtasks.exe /run /tn $TaskName 2>&1
if ($LASTEXITCODE -ne 0) {
    [void][System.Windows.MessageBox]::Show(
        "Could not start the scheduled task '$TaskName'. Run Install.ps1 again.`n`n$($out -join "`n")",
        'Reboot to Ubuntu - error', 'OK', 'Error')
    exit 1
}
