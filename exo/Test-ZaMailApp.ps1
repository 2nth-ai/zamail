<#
.SYNOPSIS
  Shows how Exchange Online sees the ZA Mail app, to diagnose "authenticated but not connected".

.DESCRIPTION
  Read-only. Prints no secrets. Requires ExchangeOnlineManagement and Microsoft.Graph;
  use -Connect to sign in first.

.EXAMPLE
  ./Test-ZaMailApp.ps1 -Connect
#>
[CmdletBinding()]
param(
    [string]$DisplayName = 'ZA Mail continuity',
    [switch]$Connect
)
$ErrorActionPreference = 'Stop'
if ($Connect) {
    Connect-MgGraph -Scopes 'Application.Read.All' -NoWelcome
    Connect-ExchangeOnline -ShowBanner:$false
}

$app = Get-MgApplication -Filter "displayName eq '$DisplayName'"
"Entra app registrations named '$DisplayName': $(@($app).Count)"
foreach ($a in @($app)) {
    $sp = Get-MgServicePrincipal -Filter "appId eq '$($a.AppId)'"
    "  appId $($a.AppId)  enterprise-app objectId $($sp.Id)  secrets $(@($a.PasswordCredentials).Count)"
    $roles = Get-MgServicePrincipalAppRoleAssignment -ServicePrincipalId $sp.Id -All
    "  app role assignments: $(@($roles).Count)"

    $exo = Get-ServicePrincipal | Where-Object { $_.AppId -eq $a.AppId }
    if (-not $exo) { "  Exchange service principal: MISSING"; continue }
    "  Exchange service principal: objectId $($exo.ObjectId)  matches Entra: $($exo.ObjectId -eq $sp.Id)"

    foreach ($mb in Get-EXOMailbox -RecipientTypeDetails UserMailbox -ResultSize Unlimited) {
        $perm = Get-MailboxPermission -Identity $mb.PrimarySmtpAddress | Where-Object { $_.User -eq $exo.ObjectId -or $_.User -eq $exo.DisplayName -or $_.User -eq $sp.Id }
        $cas = Get-CASMailbox -Identity $mb.PrimarySmtpAddress
        "  mailbox $($mb.PrimarySmtpAddress): FullAccess for app = $([bool]($perm.AccessRights -match 'FullAccess'))  IMAP enabled = $($cas.ImapEnabled)"
    }
}
"Tenant modern authentication (OAuth2ClientProfileEnabled): $((Get-OrganizationConfig).OAuth2ClientProfileEnabled)"
