<#
.SYNOPSIS
    Identifies disabled, inactive and never-used Active Directory user accounts.

.DESCRIPTION
    A security housekeeping report. It finds:
      - Disabled accounts       (e.g. leavers that have not been removed yet)
      - Inactive accounts       (enabled, but no logon for -InactiveDays days)
      - Never-logged-on accounts (enabled, created more than -InactiveDays ago, never used)

    Shows a summary on screen and saves everything to one CSV report.
    This script only READS Active Directory - it does not change any account.

.PARAMETER InactiveDays
    How many days without a logon counts as inactive. Default 90.

.PARAMETER SearchBase
    Where to look. Default: OU=Company,<your domain>.

.EXAMPLE
    .\Get-StaleADAccounts.ps1
    Report using the 90-day default.

.EXAMPLE
    .\Get-StaleADAccounts.ps1 -InactiveDays 30
    Treat 30 days without a logon as inactive.
#>

[CmdletBinding()]
param(
    [int]$InactiveDays = 90,
    [string]$SearchBase
)

# --- Setup -------------------------------------------------------------------

Import-Module ActiveDirectory -ErrorAction Stop

$domain = Get-ADDomain
if (-not $SearchBase) { $SearchBase = "OU=Company,$($domain.DistinguishedName)" }

$projectRoot  = Split-Path $PSScriptRoot -Parent
$logFolder    = Join-Path $projectRoot "Logs"
$reportFolder = Join-Path $projectRoot "Reports"
New-Item -ItemType Directory -Path $logFolder, $reportFolder -Force | Out-Null
$logFile    = Join-Path $logFolder    "StaleAccounts-$(Get-Date -Format 'yyyyMMdd').log"
$reportFile = Join-Path $reportFolder "StaleAccounts-$(Get-Date -Format 'yyyyMMdd-HHmmss').csv"
$technician = "$env:USERDOMAIN\$env:USERNAME"

function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $line = "{0} [{1}] [{2}] {3}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $Level, $technician, $Message
    Add-Content -Path $logFile -Value $line
    switch ($Level) {
        "ERROR" { Write-Host $line -ForegroundColor Red }
        "WARN"  { Write-Host $line -ForegroundColor Yellow }
        default { Write-Host $line -ForegroundColor Green }
    }
}

# --- Collect -----------------------------------------------------------------

$cutoff = (Get-Date).AddDays(-$InactiveDays)
Write-Log "Checking accounts in $SearchBase (inactive = no logon since $($cutoff.ToString('yyyy-MM-dd')))"

try {
    $users = Get-ADUser -Filter * -SearchBase $SearchBase `
        -Properties Department, Title, LastLogonDate, PasswordLastSet, WhenCreated, Enabled -ErrorAction Stop
}
catch {
    Write-Log "Could not read users from $SearchBase : $($_.Exception.Message)" "ERROR"
    return
}

$results = foreach ($u in $users) {

    $category = $null
    if (-not $u.Enabled) {
        $category = "Disabled"
    }
    elseif (-not $u.LastLogonDate -and $u.WhenCreated -lt $cutoff) {
        $category = "Never logged on"
    }
    elseif ($u.LastLogonDate -and $u.LastLogonDate -lt $cutoff) {
        $category = "Inactive"
    }

    if ($category) {
        [PSCustomObject]@{
            Category        = $category
            Name            = $u.Name
            Username        = $u.SamAccountName
            Department      = $u.Department
            Title           = $u.Title
            Enabled         = $u.Enabled
            LastLogon       = if ($u.LastLogonDate) { $u.LastLogonDate.ToString('yyyy-MM-dd') } else { "Never" }
            DaysSinceLogon  = if ($u.LastLogonDate) { [int]((Get-Date) - $u.LastLogonDate).TotalDays } else { "" }
            PasswordLastSet = if ($u.PasswordLastSet) { $u.PasswordLastSet.ToString('yyyy-MM-dd') } else { "" }
            Created         = $u.WhenCreated.ToString('yyyy-MM-dd')
            OU              = ($u.DistinguishedName -split ',', 2)[1]
        }
    }
}
$results = @($results)

# --- Output ------------------------------------------------------------------

$disabled = @($results | Where-Object Category -eq "Disabled")
$inactive = @($results | Where-Object Category -eq "Inactive")
$never    = @($results | Where-Object Category -eq "Never logged on")

Write-Host ""
Write-Host "===== Account housekeeping summary =====" -ForegroundColor Cyan
Write-Host "Users checked:        $($users.Count)"
Write-Host "Disabled:             $($disabled.Count)"
Write-Host "Inactive ($InactiveDays+ days): $($inactive.Count)"
Write-Host "Never logged on:      $($never.Count)"
Write-Host ""

foreach ($group in @(
        @{ Title = "DISABLED ACCOUNTS";        Items = $disabled; Colour = "Red" },
        @{ Title = "INACTIVE ACCOUNTS";        Items = $inactive; Colour = "Yellow" },
        @{ Title = "NEVER-LOGGED-ON ACCOUNTS"; Items = $never;    Colour = "Yellow" })) {
    if ($group.Items.Count -gt 0) {
        Write-Host $group.Title -ForegroundColor $group.Colour
        $group.Items | Select-Object Name, Username, Department, LastLogon, DaysSinceLogon, OU |
            Format-Table -AutoSize | Out-Host
    }
}

if ($results.Count -gt 0) {
    $results | Sort-Object Category, Name | Export-Csv -Path $reportFile -NoTypeInformation
    Write-Log "Report saved to $reportFile ($($results.Count) account(s) flagged)"
}
else {
    Write-Log "No disabled, inactive or never-used accounts found"
}
