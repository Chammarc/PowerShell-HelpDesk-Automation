<#
.SYNOPSIS
    Finds and unlocks locked-out Active Directory accounts.

.DESCRIPTION
    Three ways to use it:
      -ReportOnly          List every locked-out account and save a CSV report. Changes nothing.
      -Username <names>    Unlock one or more specific users.
      -AllLocked           Unlock every locked-out account (asks to confirm each one).

    For each account it shows the details a technician checks before unlocking:
    bad password count, time of the last bad password and when the lockout happened.
    Every unlock is logged with the technician's name. Supports -WhatIf.

.EXAMPLE
    .\Unlock-ADUserAccount.ps1 -ReportOnly
    Show all locked-out accounts and save a report.

.EXAMPLE
    .\Unlock-ADUserAccount.ps1 -Username jcarter
    Unlock James Carter.

.EXAMPLE
    .\Unlock-ADUserAccount.ps1 -AllLocked
    Unlock everyone who is locked out.
#>

[CmdletBinding(SupportsShouldProcess, DefaultParameterSetName = "Report")]
param(
    [Parameter(Mandatory, ParameterSetName = "ByName")]
    [string[]]$Username,

    [Parameter(Mandatory, ParameterSetName = "All")]
    [switch]$AllLocked,

    [Parameter(ParameterSetName = "Report")]
    [switch]$ReportOnly
)

# --- Setup -------------------------------------------------------------------

Import-Module ActiveDirectory -ErrorAction Stop

$projectRoot  = Split-Path $PSScriptRoot -Parent
$logFolder    = Join-Path $projectRoot "Logs"
$reportFolder = Join-Path $projectRoot "Reports"
New-Item -ItemType Directory -Path $logFolder, $reportFolder -Force | Out-Null
$logFile    = Join-Path $logFolder "AccountUnlock-$(Get-Date -Format 'yyyyMMdd').log"
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

$properties = 'Department', 'LockedOut', 'BadLogonCount', 'LastBadPasswordAttempt', 'AccountLockoutTime', 'Enabled'

function Show-AccountTable {
    param($Accounts)
    $Accounts | Select-Object Name, SamAccountName, Department, BadLogonCount,
        @{ n = 'LastBadPassword'; e = { $_.LastBadPasswordAttempt } },
        @{ n = 'LockedOutAt';     e = { $_.AccountLockoutTime } } |
        Format-Table -AutoSize | Out-Host
}

# --- Which accounts? ---------------------------------------------------------

if ($PSCmdlet.ParameterSetName -eq "ByName") {
    $accounts = foreach ($name in $Username) {
        try {
            Get-ADUser -Identity $name -Properties $properties -ErrorAction Stop
        }
        catch {
            Write-Log "User '$name' not found in Active Directory" "ERROR"
        }
    }
}
else {
    # Search-ADAccount finds every locked-out user in the domain
    $accounts = Search-ADAccount -LockedOut -UsersOnly |
        ForEach-Object { Get-ADUser -Identity $_ -Properties $properties }
}

$accounts = @($accounts | Where-Object { $_ })

# --- Report mode -------------------------------------------------------------

if ($PSCmdlet.ParameterSetName -eq "Report") {
    if ($accounts.Count -eq 0) {
        Write-Log "No locked-out accounts found"
        return
    }
    Write-Host "`nLocked-out accounts: $($accounts.Count)" -ForegroundColor Cyan
    Show-AccountTable $accounts

    $reportFile = Join-Path $reportFolder "LockedAccounts-$(Get-Date -Format 'yyyyMMdd-HHmmss').csv"
    $accounts | Select-Object Name, SamAccountName, Department, BadLogonCount,
        LastBadPasswordAttempt, AccountLockoutTime |
        Export-Csv -Path $reportFile -NoTypeInformation
    Write-Log "Locked-account report saved to $reportFile ($($accounts.Count) account(s))"
    return
}

# --- Unlock mode -------------------------------------------------------------

if ($accounts.Count -eq 0) {
    Write-Log "No accounts to unlock"
    return
}

Show-AccountTable $accounts

$unlocked = 0
foreach ($account in $accounts) {
    $name = $account.SamAccountName

    if (-not $account.LockedOut) {
        Write-Log "$name is not locked out - nothing to do" "WARN"
        continue
    }
    if (-not $account.Enabled) {
        Write-Log "$name is DISABLED - unlocking will not let them log in. Check before enabling." "WARN"
    }

    # -AllLocked asks before each unlock, because it can touch many accounts
    $confirmEach = $PSCmdlet.ParameterSetName -eq "All"
    if ($PSCmdlet.ShouldProcess("$($account.Name) ($name)", "Unlock account")) {
        if ($confirmEach -and -not $WhatIfPreference -and
            -not $PSCmdlet.ShouldContinue("Unlock $($account.Name) ($name)?", "Confirm unlock")) {
            Write-Log "Unlock of $name cancelled by technician" "WARN"
            continue
        }
        try {
            Unlock-ADAccount -Identity $account -ErrorAction Stop
            Write-Log "Unlocked $name ($($account.Name)) - had $($account.BadLogonCount) bad password attempt(s)"
            $unlocked++
        }
        catch {
            Write-Log "Failed to unlock $name : $($_.Exception.Message)" "ERROR"
        }
    }
}

Write-Log "Finished. Unlocked: $unlocked of $($accounts.Count)"
