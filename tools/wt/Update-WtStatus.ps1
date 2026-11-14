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
    # Mesmo cache da coluna Usuário para o console e o painel: uma consulta ao helper por (repo, URL).
    $userCache = @{}
    $cols = @('Name', @{ n = 'Repo'; e = { $_.RepoName } })
    if ($script:WtUserLabel) {
        $cols += @{ n = $script:WtUserLabel; e = {
            if ($_.RepoRoot) { ConvertTo-WtPlainUser (Get-WtCredentialUser -Path $_.Path -RepoRoot $_.RepoRoot -Branch $_.Branch -Prof $_.Profile -Cache $userCache) } else { '' } } }
    }
    $cols += @('State', 'Branch', 'Ticket', 'Purpose', @{ n = 'Dirty'; e = { if ($_.Tree) { $_.Tree.Dirty } } }, 'Warning')
    Get-WtSlotInfo $profiles | Select-Object $cols | Format-Table -AutoSize | Out-Host
    Write-Host "Painel: $(Write-WtReadme $profiles $userCache)"
}
