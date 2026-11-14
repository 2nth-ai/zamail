<#
.SYNOPSIS
  Creates the Entra app registration ZA Mail uses to read the directory and mirror mailboxes.

.DESCRIPTION
  UNTESTED against a live tenant in this repository. Read it before running.

  The app gets these application permissions, all read-only except mailbox access:
    Microsoft Graph            User.Read.All, Group.Read.All   (directory for the provisioner)
    Office 365 Exchange Online IMAP.AccessAsApp                (mirror and fail-back over IMAP)

  IMAP.AccessAsApp alone grants nothing. Mailbox access is granted per mailbox with
  FullAccess, and only to members of -MailboxGroup. Keep that group to the mailboxes that
  need continuity. FullAccess is needed because fail-back writes outage-time mail back.

  The client secret this prints is powerful: it can read every mailbox in the group.
  Store it only in the ZA Mail host's .env, and rotate it on a schedule.

  Requires Microsoft.Graph and ExchangeOnlineManagement, with Connect-MgGraph
  (Application.ReadWrite.All, AppRoleAssignment.ReadWrite.All) and Connect-ExchangeOnline done.

.EXAMPLE
  ./New-ZaMailApp.ps1 -MailboxGroup zamail-continuity@corp.co.za
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)][string]$MailboxGroup,
    [string]$DisplayName = 'ZA Mail continuity',
    [int]$SecretMonths = 12
)
$ErrorActionPreference = 'Stop'

$graphSp = Get-MgServicePrincipal -Filter "appId eq '00000003-0000-0000-c000-000000000000'"
$exoSp   = Get-MgServicePrincipal -Filter "appId eq '00000002-0000-0ff1-ce00-000000000000'"
function Get-RoleId($sp, $value) {
    $role = $sp.AppRoles | Where-Object { $_.Value -eq $value -and $_.AllowedMemberTypes -contains 'Application' }
    if (-not $role) { throw "Application permission '$value' not found on $($sp.DisplayName)." }
    $role.Id
}
$wanted = @(
    @{ Sp = $graphSp; Value = 'User.Read.All' },
    @{ Sp = $graphSp; Value = 'Group.Read.All' },
    @{ Sp = $exoSp;   Value = 'IMAP.AccessAsApp' }
)

if (-not $PSCmdlet.ShouldProcess($DisplayName, 'Create app registration, grant permissions and mailbox access')) { return }

$app = New-MgApplication -DisplayName $DisplayName -SignInAudience AzureADMyOrg
$sp  = New-MgServicePrincipal -AppId $app.AppId
foreach ($w in $wanted) {
    New-MgServicePrincipalAppRoleAssignment -ServicePrincipalId $sp.Id -PrincipalId $sp.Id `
        -ResourceId $w.Sp.Id -AppRoleId (Get-RoleId $w.Sp $w.Value) | Out-Null
}
$secret = Add-MgApplicationPassword -ApplicationId $app.Id -PasswordCredential @{
    DisplayName = 'zamail'; EndDateTime = (Get-Date).AddMonths($SecretMonths)
}

# Tell Exchange Online about the service principal, then grant it the mailboxes.
New-ServicePrincipal -AppId $app.AppId -ObjectId $sp.Id -DisplayName $DisplayName | Out-Null
$members = Get-DistributionGroupMember -Identity $MailboxGroup -ResultSize Unlimited
foreach ($m in $members) {
    Add-MailboxPermission -Identity $m.PrimarySmtpAddress -User $sp.Id -AccessRights FullAccess -AutoMapping:$false | Out-Null
}

Write-Host "Granted FullAccess on $($members.Count) mailboxes. Re-run the grant loop when the group changes."
Write-Host ''
Write-Host 'Put these in the ZA Mail .env file:'
Write-Host "M365_TENANT_ID=$((Get-MgContext).TenantId)"
Write-Host "M365_CLIENT_ID=$($app.AppId)"
Write-Host "M365_CLIENT_SECRET=$($secret.SecretText)"
