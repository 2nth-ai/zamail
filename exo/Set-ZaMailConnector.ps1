<#
.SYNOPSIS
  Configures Exchange Online to receive mail through the ZA Mail edge.

.DESCRIPTION
  UNTESTED against a live tenant in this repository. Read it, then run each stage with -WhatIf first.

  Three stages, run in this order during onboarding (docs/runbooks/onboarding.md):

    Prepare  Creates the inbound connector and turns on Enhanced Filtering so Microsoft
             evaluates SPF/DMARC against the original sender, not the ZA Mail edge.
             Safe to run before the MX records change. Nothing is restricted yet.

    Enforce  Run after MX points at ZA Mail and the old TTL has expired. Exchange Online
             then accepts internet mail ONLY from a server presenting the edge certificate.
             This closes the "gateway bypass" (senders delivering straight to Microsoft).

    Release  Break-glass. Removes the restriction so mail can be delivered directly to
             Microsoft again (used when MX is pointed back at Exchange Online).

  Requires the ExchangeOnlineManagement module and an existing Connect-ExchangeOnline session.

.EXAMPLE
  ./Set-ZaMailConnector.ps1 -Stage Prepare -EdgeCertificateName mx.zamail.corp.co.za -EdgeIPs 196.0.2.10,196.0.2.74
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)][ValidateSet('Prepare', 'Enforce', 'Release')][string]$Stage,
    # Subject or SAN on the TLS certificate both edges present, e.g. mx.zamail.corp.co.za or *.zamail.corp.co.za
    [string]$EdgeCertificateName,
    # Public IP addresses of the edges (used for Enhanced Filtering only, not for access control)
    [string[]]$EdgeIPs,
    [string]$ConnectorName = 'ZA Mail edge (inbound)'
)
$ErrorActionPreference = 'Stop'

$existing = Get-InboundConnector | Where-Object Name -eq $ConnectorName

switch ($Stage) {
    'Prepare' {
        if (-not $EdgeCertificateName -or -not $EdgeIPs) { throw 'Prepare needs -EdgeCertificateName and -EdgeIPs.' }

        # Internal Relay or External Relay domains would send unknown recipients back out
        # through MX, which is now the edge: a mail loop. They must be Authoritative.
        $notAuthoritative = Get-AcceptedDomain | Where-Object { $_.DomainType -ne 'Authoritative' -and $_.DomainName -notlike '*.onmicrosoft.com' }
        if ($notAuthoritative) {
            throw "These accepted domains are not Authoritative and would loop: $($notAuthoritative.DomainName -join ', ')"
        }

        $settings = @{
            ConnectorType                = 'Partner'
            SenderDomains                = '*'
            RequireTls                   = $true
            TlsSenderCertificateName     = $EdgeCertificateName
            RestrictDomainsToCertificate = $false      # turned on by the Enforce stage
            EFSkipIPs                    = $EdgeIPs    # Enhanced Filtering: look past the edge
            Enabled                      = $true
            Comment                      = 'Mail from the internet arrives via the ZA Mail edge. Managed by Set-ZaMailConnector.ps1.'
        }
        if ($existing) {
            if ($PSCmdlet.ShouldProcess($ConnectorName, 'Update inbound connector')) { Set-InboundConnector -Identity $ConnectorName @settings }
        } else {
            if ($PSCmdlet.ShouldProcess($ConnectorName, 'Create inbound connector')) { New-InboundConnector -Name $ConnectorName @settings }
        }

        # A rule that sets SCL -1 for the edge would switch Microsoft's filtering off. Warn if one exists.
        $bypass = Get-TransportRule | Where-Object { $_.SetSCL -eq -1 -and $_.SenderIpRanges }
        if ($bypass) { Write-Warning "Transport rules that bypass spam filtering by IP exist: $($bypass.Name -join ', '). Remove any that list the edge IPs." }
        Write-Host 'Prepared. Change MX to the ZA Mail edges, wait out the old TTL, then run -Stage Enforce.'
    }
    'Enforce' {
        if (-not $existing) { throw "Connector '$ConnectorName' not found. Run -Stage Prepare first." }
        if ($PSCmdlet.ShouldProcess($ConnectorName, 'Accept internet mail only from the ZA Mail edge certificate')) {
            Set-InboundConnector -Identity $ConnectorName -RestrictDomainsToCertificate $true
        }
        Write-Host 'Enforced. Mail delivered straight to Microsoft, bypassing the edge, is now rejected.'
    }
    'Release' {
        if (-not $existing) { throw "Connector '$ConnectorName' not found." }
        if ($PSCmdlet.ShouldProcess($ConnectorName, 'Remove the restriction (break-glass)')) {
            Set-InboundConnector -Identity $ConnectorName -RestrictDomainsToCertificate $false
        }
        Write-Host 'Released. Exchange Online accepts mail directly again. Point MX back at Microsoft to bypass ZA Mail.'
    }
}
