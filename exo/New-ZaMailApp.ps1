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
    # Either a group whose members get continuity, or an explicit list of mailboxes.
    [string]$MailboxGroup,
    [string[]]$Mailbox,
    # Leave out the Graph directory permissions (use with DIRECTORY_SOURCE=file).
    [switch]$SkipDirectoryPermissions,
    # Sign in to Microsoft Graph and Exchange Online first (opens the browser twice).
    [switch]$Connect,
    # Write the three settings to this file (mode 600) instead of printing the secret.
    [string]$OutFile,
    [string]$DisplayName = 'ZA Mail continuity',
    [int]$SecretMonths = 12
)
$ErrorActionPreference = 'Stop'
if (-not $MailboxGroup -and -not $Mailbox) { throw 'Give -MailboxGroup or -Mailbox.' }

if ($Connect) {
    Connect-MgGraph -Scopes 'Application.ReadWrite.All', 'AppRoleAssignment.ReadWrite.All' -NoWelcome
    Connect-ExchangeOnline -ShowBanner:$false
}

$graphSp = Get-MgServicePrincipal -Filter "appId eq '00000003-0000-0000-c000-000000000000'"
$exoSp   = Get-MgServicePrincipal -Filter "appId eq '00000002-0000-0ff1-ce00-000000000000'"
function Get-RoleId($sp, $value) {
    $role = $sp.AppRoles | Where-Object { $_.Value -eq $value -and $_.AllowedMemberTypes -contains 'Application' }
    if (-not $role) { throw "Application permission '$value' not found on $($sp.DisplayName)." }
    $role.Id
}
$wanted = @(@{ Sp = $exoSp; Value = 'IMAP.AccessAsApp' })
if (-not $SkipDirectoryPermissions) {
    $wanted += @{ Sp = $graphSp; Value = 'User.Read.All' }
    $wanted += @{ Sp = $graphSp; Value = 'Group.Read.All' }
}

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
$targets = @($Mailbox)
if ($MailboxGroup) { $targets += (Get-DistributionGroupMember -Identity $MailboxGroup -ResultSize Unlimited).PrimarySmtpAddress }
$targets = $targets | Where-Object { $_ } | Sort-Object -Unique
foreach ($t in $targets) {
    Add-MailboxPermission -Identity $t -User $sp.Id -AccessRights FullAccess -AutoMapping:$false | Out-Null
}
Write-Host "Granted FullAccess on $($targets.Count) mailbox(es): $($targets -join ', ')"

# The mirror reads mail over IMAP, which can be switched off per mailbox.
$noImap = $targets | Where-Object { -not (Get-CASMailbox -Identity $_).ImapEnabled }
if ($noImap) { Write-Warning "IMAP is disabled on: $($noImap -join ', '). Enable it with: Set-CASMailbox -Identity <mailbox> -ImapEnabled `$true" }

$settings = @(
    "M365_TENANT_ID=$((Get-MgContext).TenantId)"
    "M365_CLIENT_ID=$($app.AppId)"
    "M365_CLIENT_SECRET=$($secret.SecretText)"
)
if ($OutFile) {
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $OutFile) | Out-Null
    Set-Content -Path $OutFile -Value $settings
    if (-not $IsWindows) { chmod 600 $OutFile }
    Write-Host "Settings written to $OutFile (contains the client secret; keep it private)."
} else {
    Write-Host 'Put these in the ZA Mail .env file:'
    $settings | ForEach-Object { Write-Host $_ }
}
