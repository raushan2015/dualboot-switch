#Requires -Version 5.1
<#
.SYNOPSIS
    One-time reboot from Windows 11 straight into Ubuntu (or any UEFI boot entry).

.DESCRIPTION
    Uses `bcdedit /set {fwbootmgr} bootsequence <id>` to set the UEFI "BootNext"
    variable. The firmware boots the chosen entry on the NEXT boot only. Your
    permanent boot order stays the same, so the boot after that goes back to
    the normal default.

    How the target entry is chosen (first match wins):
      1. -Id <guid>
      2. The entry saved in config.json (created by -Setup or on first use)
      3. Auto-detect: the single entry whose description matches -Pattern ('ubuntu')
      4. Interactive pick (not available with -Unattended)

.PARAMETER Setup       Pick the Ubuntu entry interactively and save it to config.json (no reboot).
.PARAMETER List        List all UEFI firmware boot entries and exit.
.PARAMETER Clear       Cancel a pending one-time boot (delete BootNext) and exit.
.PARAMETER Id          Firmware entry GUID to boot (overrides config / auto-detect).
.PARAMETER Pattern     Regex used to auto-detect the entry. Default: 'ubuntu'.
.PARAMETER Delay       Seconds before restart. Default 0. NOTE: with Delay > 0, Windows
                       force-closes apps (shutdown /t implies /f).
.PARAMETER NoReboot    Only set BootNext; do not restart.
.PARAMETER Force       Skip the confirmation prompt.
.PARAMETER Unattended  No prompts at all; errors are shown as a message box (used by the scheduled task).

.EXAMPLE
    .\RebootToUbuntu.ps1            # confirm, then reboot into Ubuntu
.EXAMPLE
    .\RebootToUbuntu.ps1 -Setup     # choose / re-choose the Ubuntu entry
.EXAMPLE
    .\RebootToUbuntu.ps1 -List
#>
[CmdletBinding()]
param(
    [switch]$Setup,
    [switch]$List,
    [switch]$Clear,
    [string]$Id,
    [string]$Pattern = 'ubuntu',
    [ValidateRange(0, 600)]
    [int]$Delay = 0,
    [switch]$NoReboot,
    [switch]$Force,
    [switch]$Unattended
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$ConfigPath     = Join-Path $PSScriptRoot 'config.json'
$FwBootMgrGuid  = '{a5a30fa2-3d06-4e9f-b5f4-a01df9d1fcba}'   # well-known GUID of {fwbootmgr}
$WinBootMgrGuid = '{9dea862c-5cdd-4e70-acc1-f32b344d4795}'   # well-known GUID of {bootmgr}

# --------------------------------------------------------------------------- helpers

function Test-IsAdmin {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    (New-Object Security.Principal.WindowsPrincipal $identity).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Exit-WithError([string]$Text) {
    if ($Unattended) {
        Add-Type -AssemblyName PresentationFramework
        [void][System.Windows.MessageBox]::Show($Text, 'Reboot to Ubuntu - error', 'OK', 'Error')
    } else {
        Write-Host "ERROR: $Text" -ForegroundColor Red
    }
    exit 1
}

# Parses `bcdedit /enum firmware /v` output into objects { Id, Description }.
# (Expects English bcdedit output; on other display languages use -Id.)
function Get-FirmwareEntries {
    param([string]$Text)

    if (-not $Text) {
        $raw = & bcdedit.exe /enum firmware /v 2>&1
        if ($LASTEXITCODE -ne 0) { throw "bcdedit /enum firmware failed:`n$($raw -join "`n")" }
        $Text = $raw -join "`n"
    }

    foreach ($block in ($Text -split '\r?\n[ \t]*\r?\n')) {
        $idMatch = [regex]::Match($block, '(?im)^identifier\s+(\{[0-9a-f-]{36}\})')
        if (-not $idMatch.Success) { continue }

        $guid = $idMatch.Groups[1].Value.ToLowerInvariant()
        if ($guid -eq $FwBootMgrGuid) { continue }   # the firmware boot manager itself

        $descMatch = [regex]::Match($block, '(?im)^description\s+(.+?)\s*$')
        $desc = if ($descMatch.Success) { $descMatch.Groups[1].Value } else { '(no description)' }

        [pscustomobject]@{ Id = $guid; Description = $desc }
    }
}

function Show-Entries([object[]]$Entries) {
    for ($i = 0; $i -lt $Entries.Count; $i++) {
        $e   = $Entries[$i]
        $tag = if ($e.Id -eq $WinBootMgrGuid) { '  <- Windows' } else { '' }
        Write-Host ('{0,3}) {1,-40} {2}{3}' -f ($i + 1), $e.Description, $e.Id, $tag)
    }
}

function Read-EntryChoice([object[]]$Entries, [int]$DefaultIndex = -1) {
    $hint = if ($DefaultIndex -ge 0) { " [default: $($DefaultIndex + 1)]" } else { '' }
    while ($true) {
        $answer = Read-Host "Enter the number of your Ubuntu entry$hint"
        if (-not $answer -and $DefaultIndex -ge 0) { return $Entries[$DefaultIndex] }
        if ($answer -match '^\d+$' -and [int]$answer -ge 1 -and [int]$answer -le $Entries.Count) {
            return $Entries[[int]$answer - 1]
        }
        Write-Host 'Invalid choice, try again.' -ForegroundColor Yellow
    }
}

function Get-SavedEntry {
    if (-not (Test-Path $ConfigPath)) { return $null }
    try { Get-Content $ConfigPath -Raw | ConvertFrom-Json } catch { $null }
}

function Save-Entry($Entry) {
    [pscustomobject]@{ Id = $Entry.Id; Description = $Entry.Description } |
        ConvertTo-Json | Set-Content -Path $ConfigPath -Encoding UTF8
    Write-Host "Saved '$($Entry.Description)' $($Entry.Id) -> $ConfigPath" -ForegroundColor Green
}

# --------------------------------------------------------------------------- elevation

if (-not (Test-IsAdmin)) {
    if ($Unattended) {
        Exit-WithError 'Administrator rights are required (the scheduled task must run with highest privileges).'
    }
    Write-Host 'Requesting administrator rights...' -ForegroundColor Yellow
    $argList = @('-NoExit', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`"")
    foreach ($p in $PSBoundParameters.GetEnumerator()) {
        if ($p.Value -is [System.Management.Automation.SwitchParameter]) {
            if ($p.Value.IsPresent) { $argList += "-$($p.Key)" }
        } else {
            $argList += "-$($p.Key)"
            $argList += "`"$($p.Value)`""
        }
    }
    try {
        Start-Process -FilePath (Get-Process -Id $PID).Path -ArgumentList $argList -Verb RunAs | Out-Null
    } catch {
        Exit-WithError 'Administrator rights are required (UAC prompt was declined).'
    }
    exit 0
}

# --------------------------------------------------------------------------- main

try {
    if ($Clear) {
        & bcdedit.exe /deletevalue '{fwbootmgr}' bootsequence 2>&1 | Out-Null
        Write-Host 'Any pending one-time boot (BootNext) has been cleared.' -ForegroundColor Green
        exit 0
    }

    $entries = @(Get-FirmwareEntries)
    if ($entries.Count -eq 0) {
        Exit-WithError 'No UEFI firmware boot entries found. Is Windows installed in UEFI mode?'
    }

    if ($List) { Show-Entries $entries; exit 0 }

    $patternMatches = @($entries | Where-Object { $_.Id -ne $WinBootMgrGuid -and $_.Description -match $Pattern })

    # ---- Setup: always pick interactively and save
    if ($Setup) {
        Write-Host "`nUEFI boot entries on this PC:" -ForegroundColor Cyan
        Show-Entries $entries
        $default = if ($patternMatches.Count -ge 1) { [array]::IndexOf($entries, $patternMatches[0]) } else { -1 }
        if ($patternMatches.Count -eq 0) {
            Write-Host "`nNo entry matching '$Pattern' was found. Is the external SSD plugged in?" -ForegroundColor Yellow
            Write-Host "Entries named like 'UEFI: <drive name>' are the USB drive itself and usually work too." -ForegroundColor Yellow
        }
        Save-Entry (Read-EntryChoice $entries $default)
        exit 0
    }

    # ---- Resolve target
    $target = $null

    if ($Id) {
        $target = $entries | Where-Object Id -eq $Id.ToLowerInvariant() | Select-Object -First 1
        if (-not $target) { Exit-WithError "No firmware boot entry with id $Id. Run with -List to see entries." }
    } else {
        $saved = Get-SavedEntry
        if ($saved) {
            $target = $entries | Where-Object Id -eq $saved.Id | Select-Object -First 1
            if (-not $target) {
                Write-Warning "Saved entry '$($saved.Description)' $($saved.Id) no longer exists. Trying auto-detect."
            }
        }

        if (-not $target) {
            if ($patternMatches.Count -eq 1) {
                $target = $patternMatches[0]
            } elseif ($Unattended) {
                if ($patternMatches.Count -gt 1) {
                    Exit-WithError "Several boot entries match '$Pattern'. Run RebootToUbuntu.ps1 -Setup once to pick one."
                }
                Exit-WithError ("Could not find the Ubuntu UEFI boot entry.`n`n" +
                    "- Make sure the external SSD is connected.`n" +
                    "- If it is, the firmware may have deleted the entry. Boot Ubuntu once from the firmware boot menu, " +
                    "run 'sudo grub-install', then run RebootToUbuntu.ps1 -Setup again.")
            } else {
                $pool = $patternMatches
                if ($pool.Count -eq 0) {
                    Write-Host "No entry matching '$Pattern' found. Is the external SSD connected? All entries:" -ForegroundColor Yellow
                    $pool = $entries
                }
                Show-Entries $pool
                $target = Read-EntryChoice $pool
            }
            Save-Entry $target
        }
    }

    Write-Host "Target: $($target.Description)  $($target.Id)" -ForegroundColor Cyan

    if (-not ($Force -or $Unattended -or $NoReboot)) {
        $answer = Read-Host "Reboot into '$($target.Description)' now? Save your work first [y/N]"
        if ($answer -notmatch '^(y|yes)$') { Write-Host 'Cancelled.'; exit 0 }
    }

    $out = & bcdedit.exe /set '{fwbootmgr}' bootsequence $target.Id 2>&1
    if ($LASTEXITCODE -ne 0) { Exit-WithError "Failed to set BootNext:`n$($out -join "`n")" }
    Write-Host "Next boot (once only): $($target.Description)" -ForegroundColor Green

    if ($NoReboot) {
        Write-Host 'Restart whenever you are ready. Run with -Clear to cancel.'
        exit 0
    }

    & shutdown.exe /r /t $Delay /c "Rebooting into $($target.Description)..."
    if ($LASTEXITCODE -ne 0) {
        Exit-WithError "shutdown.exe failed (exit code $LASTEXITCODE). BootNext is still set: restart manually, or run with -Clear to cancel."
    }
} catch {
    Exit-WithError $_.Exception.Message
}
