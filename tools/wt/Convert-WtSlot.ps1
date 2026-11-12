#Requires -Version 7
<#
.SYNOPSIS
    Muda a afinidade de um slot LIVRE: para outro repo (-Repo) ou para vazio (-Empty).
.DESCRIPTION
    Exceção controlada à regra "nunca worktree remove": só para slot livre (detached e limpo),
    nunca ocupado nem sujo. Antes de remover: recusa se algum processo segura arquivo na pasta
    (IDE, servidor web de desenvolvimento, build) e desfaz junctions/symlinks (sem tocar no destino deles).
    Executar este script É a confirmação — quem o chama (pessoa ou skill) deve ter perguntado.
    Também serve para provisionar um slot vazio para um repo (vazio -> livre@repo).
    Com política de faixas, -Repo recusa slot que não pertence a nenhuma faixa (nenhuma branch
    poderia ocupá-lo).
.EXAMPLE
    pwsh Convert-WtSlot.ps1 -Slot g4 -Repo sandbox
.EXAMPLE
    pwsh Convert-WtSlot.ps1 -Slot g7 -Empty
#>
# Sem binding posicional: argumento solto (ex.: lista quebrada pelo shell) é erro, nunca vira -Purpose/-Base.
[CmdletBinding(PositionalBinding = $false)]
param(
    [Parameter(Mandatory)][string]$Slot,
    [string]$Repo,
    [switch]$Empty,
    [switch]$NoFetch
)
. "$PSScriptRoot/WtCommon.ps1"

Assert-WtSlotName $Slot
if ([bool]$Repo -eq [bool]$Empty) { throw 'Informe -Repo <perfil> ou -Empty (um dos dois).' }
if ($Repo -and (Get-WtSlotLabel $Slot) -eq '(fora das faixas)') { throw "Slot $Slot não pertence a nenhuma faixa da política: nenhuma branch poderia ocupá-lo." }
Assert-WtPanelOwnership
$profiles = Get-WtProfiles
$prof = if ($Repo) { Resolve-WtProfile $profiles $Repo } else { $null }
if ($prof -and -not $NoFetch) { Invoke-Git -Dir $prof.Root -GitArgs @('fetch', $prof.Remote, '--prune', '--quiet') | Out-Null }

Invoke-WtLocked {
    $target = Get-WtSlotInfo $profiles | Where-Object Name -eq $Slot
    if ($target.State -notin 'livre', 'vazio') {
        throw "Slot $Slot não pode ser convertido (estado: $($target.State)$(if ($target.Branch) { ", branch '$($target.Branch)'" })). Só livre ou vazio."
    }
    # Sem conversão a fazer: o painel é regerado mesmo assim (pode ter sido escrito por outra versão do motor).
    if ($prof -and $target.State -eq 'livre' -and $target.RepoName -eq $prof.Name) { Write-Host "Slot $Slot já é livre@$($prof.Name)."; Write-Host "Painel: $(Write-WtReadme $profiles)"; return }
    if ($Empty -and $target.State -eq 'vazio') { Write-Host "Slot $Slot já está vazio."; Write-Host "Painel: $(Write-WtReadme $profiles)"; return }

    $from = if ($target.State -eq 'livre') { "livre@$(if ($target.RepoName) { $target.RepoName } else { $target.RepoRoot })" } else { 'vazio' }
    if ($target.State -eq 'livre') { Remove-WtSlotWorktree $target }
    $metaAll = Read-WtMeta
    if ($prof) {
        New-WtSlotWorktree $target $prof
        $metaAll[$Slot] = @{ repo = $prof.Name; freedAt = (Get-Date -Format 'yyyy-MM-dd HH:mm') }
        Write-Host "Slot ${Slot}: $from -> livre@$($prof.Name)"
    } else {
        $metaAll.Remove($Slot)
        Write-Host "Slot ${Slot}: $from -> vazio"
    }
    Save-WtMeta $metaAll
    Write-Host "Painel: $(Write-WtReadme $profiles)"
}
