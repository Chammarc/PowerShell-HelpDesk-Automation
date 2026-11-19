<#
.SYNOPSIS
    LAB USE ONLY - locks out a test account by trying wrong passwords.

.DESCRIPTION
    Tries to sign in as the user with a deliberately wrong password several times,
    so the account hits the lockout limit. Used to create a realistic
    "I'm locked out" situation for testing Unlock-ADUserAccount.ps1.
    Never run this against real accounts.

.EXAMPLE
    .\Invoke-LockoutTest.ps1 -Username jcarter
#>

param(
    [Parameter(Mandatory)]
    [string]$Username,

    [int]$Attempts = 5
)

Import-Module ActiveDirectory -ErrorAction Stop
$domain = Get-ADDomain

Write-Host "Trying $Attempts wrong passwords for $Username ..." -ForegroundColor Yellow

for ($i = 1; $i -le $Attempts; $i++) {
    $entry = New-Object System.DirectoryServices.DirectoryEntry(
        "LDAP://$($domain.PDCEmulator)", "$($domain.NetBIOSName)\$Username", "WrongPassword$i!")
    try   { $entry.RefreshCache() } catch { }   # the failed sign-in is the point
    $entry.Dispose()
    Write-Host "  Attempt $i - wrong password"
}

$user = Get-ADUser -Identity $Username -Properties LockedOut, BadLogonCount
Write-Host ""
Write-Host "$Username locked out: $($user.LockedOut)" -ForegroundColor Cyan
