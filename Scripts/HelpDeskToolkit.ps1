<#
.SYNOPSIS
    Menu that runs all the help desk automation scripts from one place.

.DESCRIPTION
    Shows a numbered menu. The technician picks a task, answers a simple question
    (e.g. which username), and the matching script runs. All scripts must be in the
    same folder as this file.

.EXAMPLE
    .\HelpDeskToolkit.ps1
#>

$scripts = $PSScriptRoot

function Read-Required {
    param([string]$Prompt)
    do { $value = (Read-Host $Prompt).Trim() } while (-not $value)
    $value
}

function Read-YesNo {
    param([string]$Prompt)
    (Read-Host "$Prompt (Y/N)").Trim().ToUpper() -eq "Y"
}

function Run-Script {
    param([string]$Name, [hashtable]$Arguments = @{})
    $path = Join-Path $scripts $Name
    if (-not (Test-Path $path)) {
        Write-Host "Script not found: $path" -ForegroundColor Red
        return
    }
    try   { & $path @Arguments }
    catch { Write-Host "Error: $($_.Exception.Message)" -ForegroundColor Red }
}

do {
    Clear-Host
    Write-Host "==============================================" -ForegroundColor Cyan
    Write-Host "      MARCOTECH HELP DESK TOOLKIT" -ForegroundColor Cyan
    Write-Host "      Logged in as: $env:USERDOMAIN\$env:USERNAME" -ForegroundColor Gray
    Write-Host "==============================================" -ForegroundColor Cyan
    Write-Host ""
    Write-Host " ACCOUNTS"
    Write-Host "   1. Create new users from CSV"
    Write-Host "   2. Reset a user's password"
    Write-Host "   3. Unlock a user's account"
    Write-Host "   4. Show all locked-out accounts"
    Write-Host "   5. Unlock all locked-out accounts"
    Write-Host ""
    Write-Host " LOOKUP"
    Write-Host "   6. Search for a user or computer"
    Write-Host "   7. User information"
    Write-Host "   8. Computer information"
    Write-Host ""
    Write-Host " REPORTS"
    Write-Host "   9. Disabled and inactive accounts"
    Write-Host "  10. Full help desk CSV report"
    Write-Host ""
    Write-Host "   Q. Quit"
    Write-Host ""

    $choice = (Read-Host "Choose an option").Trim().ToUpper()
    Write-Host ""

    switch ($choice) {
        "1" {
            $csv = Read-Host "Path to CSV (press Enter for ..\SampleData\NewUsers.csv)"
            if (-not $csv) { $csv = Join-Path (Split-Path $scripts -Parent) "SampleData\NewUsers.csv" }
            Write-Host "`nPreview first (no changes made):" -ForegroundColor Cyan
            Run-Script "New-BulkADUsers.ps1" @{ CsvPath = $csv; WhatIf = $true }
            if (Read-YesNo "`nCreate these users for real?") {
                Run-Script "New-BulkADUsers.ps1" @{ CsvPath = $csv }
            }
        }
        "2" {
            $user = Read-Required "Username to reset (e.g. jcarter)"
            Run-Script "Reset-ADUserPassword.ps1" @{ Username = $user }
        }
        "3" {
            $user = Read-Required "Username to unlock (e.g. jcarter)"
            Run-Script "Unlock-ADUserAccount.ps1" @{ Username = $user }
        }
        "4" { Run-Script "Unlock-ADUserAccount.ps1" @{ ReportOnly = $true } }
        "5" { Run-Script "Unlock-ADUserAccount.ps1" @{ AllLocked = $true } }
        "6" {
            $text = Read-Required "Search for (part of a name, e.g. carter)"
            Run-Script "Get-ADUserComputerInfo.ps1" @{ Search = $text }
        }
        "7" {
            $user = Read-Required "Username (e.g. jcarter)"
            Run-Script "Get-ADUserComputerInfo.ps1" @{ Username = $user }
        }
        "8" {
            $pc = Read-Required "Computer name (e.g. SALES-PC01)"
            Run-Script "Get-ADUserComputerInfo.ps1" @{ ComputerName = $pc }
        }
        "9" {
            $days = Read-Host "Days without logon to count as inactive (press Enter for 90)"
            $params = @{}
            if ($days -match '^\d+$') { $params.InactiveDays = [int]$days }
            Run-Script "Get-StaleADAccounts.ps1" $params
        }
        "10" { Run-Script "Export-ADHelpDeskReport.ps1" }
        "Q"  { Write-Host "Goodbye." -ForegroundColor Cyan }
        default { Write-Host "'$choice' is not a valid option." -ForegroundColor Yellow }
    }

    if ($choice -ne "Q") {
        Write-Host ""
        Read-Host "Press Enter to return to the menu" | Out-Null
    }
} while ($choice -ne "Q")
