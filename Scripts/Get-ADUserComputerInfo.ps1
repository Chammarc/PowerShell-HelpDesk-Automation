<#
.SYNOPSIS
    Looks up Active Directory information about a user or a computer for help desk calls.

.DESCRIPTION
    Three ways to use it:
      -Username <name>      Full details for one user: contact info, account status,
                            password status, group memberships and assigned computers.
      -ComputerName <name>  Full details for one computer: OS, last logon, IP, OU, assigned user.
      -Search <text>        Find users AND computers whose name contains the text,
                            for when the caller only gives a name like "James" or "Sales".

    Add -ExportCsv to save the result to the Reports folder.
    This script only READS Active Directory - it does not change anything.

.EXAMPLE
    .\Get-ADUserComputerInfo.ps1 -Username jcarter

.EXAMPLE
    .\Get-ADUserComputerInfo.ps1 -ComputerName SALES-PC01

.EXAMPLE
    .\Get-ADUserComputerInfo.ps1 -Search carter
#>

[CmdletBinding(DefaultParameterSetName = "Search")]
param(
    [Parameter(Mandatory, ParameterSetName = "User")]
    [string]$Username,

    [Parameter(Mandatory, ParameterSetName = "Computer")]
    [string]$ComputerName,

    [Parameter(Mandatory, ParameterSetName = "Search")]
    [string]$Search,

    [switch]$ExportCsv
)

# --- Setup -------------------------------------------------------------------

Import-Module ActiveDirectory -ErrorAction Stop

$projectRoot  = Split-Path $PSScriptRoot -Parent
$reportFolder = Join-Path $projectRoot "Reports"
New-Item -ItemType Directory -Path $reportFolder -Force | Out-Null
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'

function Show-Section {
    param([string]$Title, $Object)
    Write-Host ""
    Write-Host "----- $Title -----" -ForegroundColor Cyan
    $Object | Format-List | Out-Host
}

function Get-OUName {
    param([string]$DistinguishedName)
    ($DistinguishedName -split ',', 2)[1]
}

# --- User lookup -------------------------------------------------------------

if ($PSCmdlet.ParameterSetName -eq "User") {
    try {
        $u = Get-ADUser -Identity $Username -Properties * -ErrorAction Stop
    }
    catch {
        Write-Host "User '$Username' not found. Try: .\Get-ADUserComputerInfo.ps1 -Search <part of their name>" -ForegroundColor Red
        return
    }

    $manager = if ($u.Manager) { (Get-ADUser -Identity $u.Manager).Name } else { "" }
    $groups  = ($u.MemberOf | ForEach-Object { (($_ -split ',')[0]) -replace '^CN=' } | Sort-Object) -join ', '
    $pcs     = (Get-ADComputer -Filter "ManagedBy -eq '$($u.DistinguishedName)'" | Select-Object -ExpandProperty Name) -join ', '

    $identity = [PSCustomObject]@{
        Name        = $u.Name
        Username    = $u.SamAccountName
        LoginName   = $u.UserPrincipalName
        Email       = $u.EmailAddress
        JobTitle    = $u.Title
        Department  = $u.Department
        Manager     = $manager
        Phone       = $u.OfficePhone
        OU          = Get-OUName $u.DistinguishedName
    }

    $status = [PSCustomObject]@{
        Enabled              = $u.Enabled
        LockedOut            = $u.LockedOut
        BadPasswordCount     = $u.BadLogonCount
        LastBadPassword      = $u.LastBadPasswordAttempt
        LastLogon            = if ($u.LastLogonDate) { $u.LastLogonDate } else { "Never" }
        PasswordLastSet      = $u.PasswordLastSet
        PasswordExpired      = $u.PasswordExpired
        PasswordNeverExpires = $u.PasswordNeverExpires
        MustChangeAtLogon    = ($u.pwdLastSet -eq 0)
        AccountCreated       = $u.WhenCreated
        Description          = $u.Description
    }

    $access = [PSCustomObject]@{
        Groups            = if ($groups) { $groups } else { "(none)" }
        AssignedComputers = if ($pcs) { $pcs } else { "(none)" }
    }

    Show-Section "USER: $($u.Name)" $identity
    Show-Section "ACCOUNT STATUS"   $status
    Show-Section "ACCESS"           $access

    # Quick hints, like a technician would note on the ticket
    if (-not $u.Enabled)      { Write-Host "! Account is DISABLED" -ForegroundColor Red }
    if ($u.LockedOut)         { Write-Host "! Account is LOCKED OUT - use Unlock-ADUserAccount.ps1" -ForegroundColor Yellow }
    if ($u.PasswordExpired)   { Write-Host "! Password has EXPIRED - use Reset-ADUserPassword.ps1" -ForegroundColor Yellow }

    if ($ExportCsv) {
        $file = Join-Path $reportFolder "UserInfo-$($u.SamAccountName)-$stamp.csv"
        $row = [ordered]@{}
        foreach ($obj in $identity, $status, $access) {
            foreach ($p in $obj.PSObject.Properties) { $row[$p.Name] = $p.Value }
        }
        [PSCustomObject]$row | Export-Csv -Path $file -NoTypeInformation
        Write-Host "`nSaved to $file" -ForegroundColor Green
    }
    return
}

# --- Computer lookup ---------------------------------------------------------

if ($PSCmdlet.ParameterSetName -eq "Computer") {
    try {
        $c = Get-ADComputer -Identity $ComputerName -Properties * -ErrorAction Stop
    }
    catch {
        Write-Host "Computer '$ComputerName' not found. Try: .\Get-ADUserComputerInfo.ps1 -Search <part of the name>" -ForegroundColor Red
        return
    }

    $assigned = if ($c.ManagedBy) {
        $m = Get-ADObject -Identity $c.ManagedBy -Properties SamAccountName
        "$($m.Name) ($($m.SamAccountName))"
    } else { "(none)" }

    $info = [PSCustomObject]@{
        Name             = $c.Name
        DNSName          = $c.DNSHostName
        OperatingSystem  = $c.OperatingSystem
        OSVersion        = $c.OperatingSystemVersion
        IPv4Address      = $c.IPv4Address
        Enabled          = $c.Enabled
        LastLogon        = if ($c.LastLogonDate) { $c.LastLogonDate } else { "Never" }
        AssignedUser     = $assigned
        Description      = $c.Description
        Location         = $c.Location
        OU               = Get-OUName $c.DistinguishedName
        Created          = $c.WhenCreated
    }

    Show-Section "COMPUTER: $($c.Name)" $info
    if (-not $c.Enabled) { Write-Host "! Computer account is DISABLED" -ForegroundColor Red }

    if ($ExportCsv) {
        $file = Join-Path $reportFolder "ComputerInfo-$($c.Name)-$stamp.csv"
        $info | Export-Csv -Path $file -NoTypeInformation
        Write-Host "`nSaved to $file" -ForegroundColor Green
    }
    return
}

# --- Search ------------------------------------------------------------------

$safe = $Search -replace "'", "''"

$users = @(Get-ADUser -Filter "Name -like '*$safe*' -or SamAccountName -like '*$safe*'" `
            -Properties Department, Enabled, LockedOut |
        Select-Object @{n='Type';e={'User'}}, Name, @{n='Username';e={$_.SamAccountName}},
            Department, Enabled, LockedOut)

$computers = @(Get-ADComputer -Filter "Name -like '*$safe*' -or Description -like '*$safe*'" `
            -Properties OperatingSystem, Enabled, Description |
        Select-Object @{n='Type';e={'Computer'}}, Name, @{n='Username';e={''}},
            @{n='Department';e={$_.Description}}, Enabled, @{n='LockedOut';e={''}})

$all = @($users) + @($computers)

if ($all.Count -eq 0) {
    Write-Host "Nothing found matching '$Search'" -ForegroundColor Yellow
    return
}

Write-Host "`nFound $($users.Count) user(s) and $($computers.Count) computer(s) matching '$Search':" -ForegroundColor Cyan
$all | Format-Table -AutoSize | Out-Host
Write-Host "For full details run: -Username <Username>  or  -ComputerName <Name>" -ForegroundColor Gray

if ($ExportCsv) {
    $file = Join-Path $reportFolder "Search-$($Search -replace '[^\w]', '_')-$stamp.csv"
    $all | Export-Csv -Path $file -NoTypeInformation
    Write-Host "Saved to $file" -ForegroundColor Green
}
