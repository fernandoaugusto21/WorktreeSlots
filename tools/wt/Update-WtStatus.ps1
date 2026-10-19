#Requires -Version 7
<#
.SYNOPSIS
    Regera o painel do pool (<pool>/README.md) e mostra um resumo no terminal.
.EXAMPLE
    pwsh Update-WtStatus.ps1
#>
# Sem binding posicional: argumento solto (ex.: lista quebrada pelo shell) é erro, nunca vira -Purpose/-Base.
[CmdletBinding(PositionalBinding = $false)]
param([switch]$NoFetch)
. "$PSScriptRoot/WtCommon.ps1"

Assert-WtPanelOwnership
$profiles = Get-WtProfiles
if (-not $NoFetch) {
    foreach ($p in $profiles.Values) {
        if (Test-Path $p.Root) { Invoke-Git -Dir $p.Root -GitArgs @('fetch', $p.Remote, '--prune', '--quiet') -AllowFail | Out-Null }
    }
}

Invoke-WtLocked {
    Get-WtSlotInfo $profiles |
        Select-Object Name, @{ n = 'Repo'; e = { $_.RepoName } }, State, Branch, Ticket, Purpose,
            @{ n = 'Dirty'; e = { if ($_.Tree) { $_.Tree.Dirty } } }, Warning |
        Format-Table -AutoSize | Out-Host
    Write-Host "Painel: $(Write-WtReadme $profiles)"
}
