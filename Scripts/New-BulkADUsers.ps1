<#
.SYNOPSIS
    Creates Active Directory user accounts in bulk from a CSV file.

.DESCRIPTION
    Reads new starters from a CSV (FirstName, LastName, Department, JobTitle, Group),
    builds a username in the format first initial + last name (e.g. amorgan), adding a
    number if a different person already has that username (e.g. swilson2), places the
    user in the OU matching their department, creates each account with a random
    temporary password, forces a password change at first logon, adds the user
    to a group, and writes a results report to CSV.

    Supports -WhatIf so you can preview the changes without creating anything.

.PARAMETER CsvPath
    Path to the CSV file of new users.

.PARAMETER BaseOU
    The OU that holds the department OUs. Default: OU=Users,OU=Company,<your domain>.
    A user in the Sales department goes to OU=Sales,<BaseOU>.

.EXAMPLE
    .\New-BulkADUsers.ps1 -CsvPath .\NewUsers.csv -WhatIf
    Preview what would be created.

.EXAMPLE
    .\New-BulkADUsers.ps1 -CsvPath .\NewUsers.csv
    Create the users, each in their department OU.
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)]
    [string]$CsvPath,

    [string]$BaseOU
)

# --- Setup -------------------------------------------------------------------

Import-Module ActiveDirectory -ErrorAction Stop

if (-not (Test-Path $CsvPath)) {
    Write-Error "CSV file not found: $CsvPath"
    exit 1
}

# Find the domain automatically so the script works in any lab
$domain    = Get-ADDomain
$upnSuffix = $domain.DNSRoot                     # e.g. Marcotech.ltd
if (-not $BaseOU) { $BaseOU = "OU=Users,OU=Company,$($domain.DistinguishedName)" }

# Logs and Reports folders next to the Scripts folder (C:\HelpDeskAutomation\Logs and \Reports)
$projectRoot  = Split-Path $PSScriptRoot -Parent
$logFolder    = Join-Path $projectRoot "Logs"
$reportFolder = Join-Path $projectRoot "Reports"
New-Item -ItemType Directory -Path $logFolder, $reportFolder -Force | Out-Null
$timestamp  = Get-Date -Format "yyyyMMdd-HHmmss"
$logFile    = Join-Path $logFolder    "UserCreation-$timestamp.log"
$reportFile = Join-Path $reportFolder "UserCreation-$timestamp.csv"

function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $line = "{0} [{1}] {2}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $Level, $Message
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

$users   = Import-Csv -Path $CsvPath
$results = @()

Write-Log "Starting bulk user creation: $($users.Count) user(s) from $CsvPath (base OU: $BaseOU)"

foreach ($user in $users) {

    # Basic validation: skip rows missing a name
    if ([string]::IsNullOrWhiteSpace($user.FirstName) -or [string]::IsNullOrWhiteSpace($user.LastName)) {
        Write-Log "Skipped a row with a missing first or last name" "WARN"
        continue
    }

    $first    = $user.FirstName.Trim()
    $last     = $user.LastName.Trim()
    $baseName = ("$($first[0])$last").ToLower() -replace '[^a-z0-9]', ''  # e.g. amorgan; removes spaces/apostrophes
    if ($baseName.Length -gt 18) { $baseName = $baseName.Substring(0, 18) }  # room for a number (20-char limit)

    # Work out the department OU and make sure it exists
    $ouPath = "OU=$("$($user.Department)".Trim()),$BaseOU"
    try {
        Get-ADOrganizationalUnit -Identity $ouPath -ErrorAction Stop | Out-Null
    }
    catch {
        Write-Log "OU '$ouPath' not found - skipped $first $last" "WARN"
        $results += [PSCustomObject]@{
            Name = "$first $last"; Username = $baseName; Status = "Skipped - department OU not found"; TempPassword = ""
        }
        continue
    }

    # 1) Same person already set up? (same first + last name in the same department OU) -> skip
    $safeFirst = $first -replace "'", "''"
    $safeLast  = $last  -replace "'", "''"
    $existing  = Get-ADUser -Filter "GivenName -eq '$safeFirst' -and Surname -eq '$safeLast'" `
                            -SearchBase $ouPath -SearchScope OneLevel -ErrorAction SilentlyContinue
    if ($existing) {
        Write-Log "$first $last already has an account ($($existing[0].SamAccountName)) - skipped" "WARN"
        $results += [PSCustomObject]@{
            Name = "$first $last"; Username = $existing[0].SamAccountName; Status = "Skipped - already exists"; TempPassword = ""
        }
        continue
    }

    # 2) New person, but the username is taken by someone else? -> add a number (swilson2, swilson3...)
    $username = $baseName
    $number   = 2
    while (Get-ADUser -Filter "SamAccountName -eq '$username'" -ErrorAction SilentlyContinue) {
        $username = "$baseName$number"
        $number++
    }
    if ($username -ne $baseName) {
        Write-Log "Username $baseName is taken by another person - using $username for $first $last" "WARN"
    }
    $upn = "$username@$upnSuffix"

    $tempPassword = New-TempPassword

    $params = @{
        Name                  = "$first $last"
        GivenName             = $first
        Surname               = $last
        DisplayName           = "$first $last"
        SamAccountName        = $username
        UserPrincipalName     = $upn
        Department            = $user.Department
        Title                 = $user.JobTitle
        Path                  = $ouPath
        AccountPassword       = (ConvertTo-SecureString $tempPassword -AsPlainText -Force)
        ChangePasswordAtLogon = $true
        Enabled               = $true
    }

    if ($PSCmdlet.ShouldProcess($username, "Create AD user")) {
        try {
            New-ADUser @params -ErrorAction Stop
            Write-Log "Created user $username ($first $last)"

            if ($user.Group) {
                try {
                    Add-ADGroupMember -Identity $user.Group -Members $username -ErrorAction Stop
                    Write-Log "Added $username to group $($user.Group)"
                }
                catch {
                    Write-Log "Created $username but could not add to group '$($user.Group)': $($_.Exception.Message)" "WARN"
                }
            }

            $results += [PSCustomObject]@{
                Name = "$first $last"; Username = $username; Status = "Created"; TempPassword = $tempPassword
            }
        }
        catch {
            Write-Log "Failed to create $username : $($_.Exception.Message)" "ERROR"
            $results += [PSCustomObject]@{
                Name = "$first $last"; Username = $username; Status = "Failed - $($_.Exception.Message)"; TempPassword = ""
            }
        }
    }
}

# --- Report ------------------------------------------------------------------

if ($results.Count -gt 0) {
    $results | Export-Csv -Path $reportFile -NoTypeInformation
    Write-Log "Report saved to $reportFile"
}

$created = ($results | Where-Object Status -eq "Created").Count
Write-Log "Finished. Created: $created, Skipped/Failed: $($results.Count - $created)"
