<#
.SYNOPSIS
    Exports a full set of Active Directory reports to CSV in one run.

.DESCRIPTION
    Creates a dated folder in Reports and saves:
      01-AllUsers.csv               Every user with department, status and logon details
      02-DisabledUsers.csv          Disabled accounts
      03-LockedOutUsers.csv         Locked-out accounts
      04-PasswordIssues.csv         Expired passwords, passwords that never expire,
                                    and users who must change at next logon
      05-NeverLoggedOn.csv          Enabled accounts that have never been used
      06-GroupMembership.csv        Every security group and its members
      07-Computers.csv              Every computer with OS, last logon and assigned user
      00-Summary.csv                One line per report with the number of records

    This script only READS Active Directory - it does not change anything.

.PARAMETER SearchBase
    Where to look. Default: OU=Company,<your domain>.

.EXAMPLE
    .\Export-ADHelpDeskReport.ps1
#>

[CmdletBinding()]
param(
    [string]$SearchBase
)

# --- Setup -------------------------------------------------------------------

Import-Module ActiveDirectory -ErrorAction Stop

$domain = Get-ADDomain
if (-not $SearchBase) { $SearchBase = "OU=Company,$($domain.DistinguishedName)" }

$projectRoot  = Split-Path $PSScriptRoot -Parent
$logFolder    = Join-Path $projectRoot "Logs"
$outFolder    = Join-Path $projectRoot "Reports\HelpDeskReport-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
New-Item -ItemType Directory -Path $logFolder, $outFolder -Force | Out-Null
$logFile    = Join-Path $logFolder "HelpDeskReport-$(Get-Date -Format 'yyyyMMdd').log"
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

$summary = [System.Collections.Generic.List[object]]::new()

function Save-Report {
    param([string]$FileName, [string]$Description, $Data)
    $Data = @($Data)
    $path = Join-Path $outFolder $FileName
    if ($Data.Count -gt 0) {
        $Data | Export-Csv -Path $path -NoTypeInformation
    }
    else {
        # Still create the file so the folder always has the same set of reports
        Set-Content -Path $path -Value "No records found"
    }
    $summary.Add([PSCustomObject]@{ Report = $FileName; Description = $Description; Records = $Data.Count })
    Write-Log ("{0,-24} {1,4} record(s)" -f $FileName, $Data.Count)
}

function Get-OUName { param([string]$Dn) ($Dn -split ',', 2)[1] }

Write-Log "Building help desk report for $SearchBase"

# --- Users -------------------------------------------------------------------

try {
    $users = Get-ADUser -Filter * -SearchBase $SearchBase -Properties `
        Department, Title, EmailAddress, Enabled, LockedOut, LastLogonDate, PasswordLastSet,
        PasswordExpired, PasswordNeverExpires, pwdLastSet, WhenCreated, Manager, MemberOf -ErrorAction Stop
}
catch {
    Write-Log "Could not read users: $($_.Exception.Message)" "ERROR"
    return
}

$userRows = foreach ($u in $users) {
    [PSCustomObject]@{
        Name                 = $u.Name
        Username             = $u.SamAccountName
        Email                = $u.EmailAddress
        Department           = $u.Department
        JobTitle             = $u.Title
        Enabled              = $u.Enabled
        LockedOut            = $u.LockedOut
        LastLogon            = if ($u.LastLogonDate) { $u.LastLogonDate.ToString('yyyy-MM-dd HH:mm') } else { "Never" }
        PasswordLastSet      = if ($u.PasswordLastSet) { $u.PasswordLastSet.ToString('yyyy-MM-dd HH:mm') } else { "" }
        PasswordExpired      = $u.PasswordExpired
        PasswordNeverExpires = $u.PasswordNeverExpires
        MustChangeAtLogon    = ($u.pwdLastSet -eq 0)
        Manager              = if ($u.Manager) { (($u.Manager -split ',')[0]) -replace '^CN=' } else { "" }
        Groups               = ($u.MemberOf | ForEach-Object { (($_ -split ',')[0]) -replace '^CN=' }) -join '; '
        Created              = $u.WhenCreated.ToString('yyyy-MM-dd')
        OU                   = Get-OUName $u.DistinguishedName
    }
}
$userRows = @($userRows | Sort-Object Department, Name)

Save-Report "01-AllUsers.csv"      "All user accounts"            $userRows
Save-Report "02-DisabledUsers.csv" "Disabled accounts"            ($userRows | Where-Object { -not $_.Enabled })
Save-Report "03-LockedOutUsers.csv" "Locked-out accounts"         ($userRows | Where-Object { $_.LockedOut })

$passwordIssues = foreach ($r in $userRows | Where-Object Enabled) {
    $issue = @()
    if ($r.PasswordExpired)      { $issue += "Password expired" }
    if ($r.PasswordNeverExpires) { $issue += "Password never expires" }
    if ($r.MustChangeAtLogon)    { $issue += "Must change at next logon" }
    if ($issue) {
        $r | Select-Object Name, Username, Department, PasswordLastSet,
            @{ n = 'Issue'; e = { $issue -join '; ' } }
    }
}
Save-Report "04-PasswordIssues.csv" "Password problems to follow up" $passwordIssues
Save-Report "05-NeverLoggedOn.csv"  "Enabled accounts never used" `
    ($userRows | Where-Object { $_.Enabled -and $_.LastLogon -eq "Never" })

# --- Groups ------------------------------------------------------------------

$groupRows = foreach ($g in Get-ADGroup -Filter "GroupCategory -eq 'Security'" -SearchBase $SearchBase -Properties Description) {
    $members = @(Get-ADGroupMember -Identity $g -ErrorAction SilentlyContinue)
    if ($members.Count -eq 0) {
        [PSCustomObject]@{ Group = $g.Name; Member = "(no members)"; MemberUsername = ""; MemberType = "" }
    }
    foreach ($m in $members) {
        [PSCustomObject]@{ Group = $g.Name; Member = $m.Name; MemberUsername = $m.SamAccountName; MemberType = $m.objectClass }
    }
}
Save-Report "06-GroupMembership.csv" "Security groups and their members" ($groupRows | Sort-Object Group, Member)

# --- Computers ---------------------------------------------------------------

$computerRows = foreach ($c in Get-ADComputer -Filter * -SearchBase $SearchBase -Properties `
        OperatingSystem, OperatingSystemVersion, LastLogonDate, IPv4Address, ManagedBy, Description, Enabled, WhenCreated) {
    [PSCustomObject]@{
        Name            = $c.Name
        OperatingSystem = $c.OperatingSystem
        OSVersion       = $c.OperatingSystemVersion
        IPv4Address     = $c.IPv4Address
        Enabled         = $c.Enabled
        LastLogon       = if ($c.LastLogonDate) { $c.LastLogonDate.ToString('yyyy-MM-dd HH:mm') } else { "Never" }
        AssignedUser    = if ($c.ManagedBy) { (($c.ManagedBy -split ',')[0]) -replace '^CN=' } else { "" }
        Description     = $c.Description
        Created         = $c.WhenCreated.ToString('yyyy-MM-dd')
        OU              = Get-OUName $c.DistinguishedName
    }
}
Save-Report "07-Computers.csv" "Computer accounts" ($computerRows | Sort-Object Name)

# --- Summary -----------------------------------------------------------------

$summary | Export-Csv -Path (Join-Path $outFolder "00-Summary.csv") -NoTypeInformation

Write-Host ""
Write-Host "===== Help desk report summary =====" -ForegroundColor Cyan
$summary | Format-Table -AutoSize | Out-Host
Write-Log "All reports saved to $outFolder"
