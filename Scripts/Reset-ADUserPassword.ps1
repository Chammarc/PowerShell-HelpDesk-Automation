<#
.SYNOPSIS
    Resets an Active Directory user's password, as a help desk technician would.

.DESCRIPTION
    For each username given, the script:
      1. Checks the account exists and shows its current status
      2. Generates a secure random temporary password
      3. Resets the password and forces a change at next logon
      4. Unlocks the account if it is locked out
      5. Warns (but does not re-enable) if the account is disabled
      6. Logs who did the reset and when, and adds a line to an audit CSV
         (the password itself is never written to the log or the CSV)

    Supports -WhatIf to preview without changing anything.

.PARAMETER Username
    One or more usernames (sAMAccountName), e.g. jcarter

.EXAMPLE
    .\Reset-ADUserPassword.ps1 -Username jcarter -WhatIf
    Preview the reset.

.EXAMPLE
    .\Reset-ADUserPassword.ps1 -Username jcarter
    Reset James Carter's password.

.EXAMPLE
    .\Reset-ADUserPassword.ps1 -Username jcarter, ppatel
    Reset two users' passwords.
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)]
    [string[]]$Username
)

# --- Setup -------------------------------------------------------------------

Import-Module ActiveDirectory -ErrorAction Stop

$projectRoot  = Split-Path $PSScriptRoot -Parent
$logFolder    = Join-Path $projectRoot "Logs"
$reportFolder = Join-Path $projectRoot "Reports"
New-Item -ItemType Directory -Path $logFolder, $reportFolder -Force | Out-Null
$logFile   = Join-Path $logFolder    "PasswordReset-$(Get-Date -Format 'yyyyMMdd').log"
$auditFile = Join-Path $reportFolder "PasswordReset-Audit.csv"
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

function New-TempPassword {
    # 14 characters with upper, lower, digit and symbol so it meets AD complexity rules
    $upper  = 'ABCDEFGHJKLMNPQRSTUVWXYZ'
    $lower  = 'abcdefghijkmnopqrstuvwxyz'
    $digits = '23456789'
    $symbol = '!@#$%&*?'
    $all    = $upper + $lower + $digits + $symbol

    $chars  = @(
        $upper[(Get-Random -Maximum $upper.Length)]
        $lower[(Get-Random -Maximum $lower.Length)]
        $digits[(Get-Random -Maximum $digits.Length)]
        $symbol[(Get-Random -Maximum $symbol.Length)]
    )
    $chars += 1..10 | ForEach-Object { $all[(Get-Random -Maximum $all.Length)] }
    -join ($chars | Sort-Object { Get-Random })
}

# --- Main --------------------------------------------------------------------

foreach ($name in $Username) {

    # 1) Does the account exist?
    try {
        $user = Get-ADUser -Identity $name -Properties LockedOut, Enabled, PasswordLastSet, Department -ErrorAction Stop
    }
    catch {
        Write-Log "User '$name' not found in Active Directory" "ERROR"
        continue
    }

    # Show the current status - what a technician checks before acting
    Write-Host ""
    Write-Host "User:              $($user.Name) ($($user.SamAccountName))" -ForegroundColor Cyan
    Write-Host "Department:        $($user.Department)"
    Write-Host "Enabled:           $($user.Enabled)"
    Write-Host "Locked out:        $($user.LockedOut)"
    Write-Host "Password last set: $($user.PasswordLastSet)"
    Write-Host ""

    if (-not $PSCmdlet.ShouldProcess("$($user.Name) ($name)", "Reset password")) { continue }

    $wasLocked = $user.LockedOut
    $tempPassword = New-TempPassword

    try {
        # 2) + 3) Reset the password and force a change at next logon
        Set-ADAccountPassword -Identity $user -Reset `
            -NewPassword (ConvertTo-SecureString $tempPassword -AsPlainText -Force) -ErrorAction Stop
        Set-ADUser -Identity $user -ChangePasswordAtLogon $true -ErrorAction Stop
        Write-Log "Password reset for $name - user must change it at next logon"

        # 4) Unlock if locked
        if ($wasLocked) {
            Unlock-ADAccount -Identity $user -ErrorAction Stop
            Write-Log "Account $name was locked out - unlocked"
        }

        # 5) Disabled accounts are not re-enabled automatically: that needs approval
        if (-not $user.Enabled) {
            Write-Log "Account $name is DISABLED - password was reset but the user still cannot log in. Check with their manager before enabling." "WARN"
        }

        # Show the temporary password once, on screen only
        Write-Host ""
        Write-Host "Temporary password for $name : $tempPassword" -ForegroundColor Magenta
        Write-Host "Give this to the user securely (e.g. by phone after verifying identity). It is not saved anywhere." -ForegroundColor Magenta

        # 6) Audit record - no password
        [PSCustomObject]@{
            Date        = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
            Technician  = $technician
            Username    = $name
            Name        = $user.Name
            WasLocked   = $wasLocked
            Unlocked    = $wasLocked
            Enabled     = $user.Enabled
            Result      = "Success"
        } | Export-Csv -Path $auditFile -NoTypeInformation -Append
    }
    catch {
        Write-Log "Failed to reset password for $name : $($_.Exception.Message)" "ERROR"
        [PSCustomObject]@{
            Date        = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
            Technician  = $technician
            Username    = $name
            Name        = $user.Name
            WasLocked   = $wasLocked
            Unlocked    = $false
            Enabled     = $user.Enabled
            Result      = "Failed - $($_.Exception.Message)"
        } | Export-Csv -Path $auditFile -NoTypeInformation -Append
    }
}
