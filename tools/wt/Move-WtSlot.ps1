#Requires -Version 7
<#
.SYNOPSIS
    Move a worktree de um slot para outro slot VAZIO (git worktree move), levando o registro.
.DESCRIPTION
    - Origem: slot com worktree (ocupado, livre ou sujo — alterações locais vão junto).
    - Destino: slot vazio. Com política de faixas e origem ocupada, o destino precisa estar na
      faixa da branch.
    - Recusa se algum processo segura arquivo na origem (IDE, servidor web de desenvolvimento, build...).
    - Move a entrada do .slots.json e roda o PostAttachHook do perfil no destino (idempotente).
    Uso típico: corrigir um slot fora da faixa após adotar worktrees existentes.
.EXAMPLE
    pwsh Move-WtSlot.ps1 -From g2 -To g4
#>
# Sem binding posicional: argumento solto (ex.: lista quebrada pelo shell) é erro, nunca vira -Purpose/-Base.
[CmdletBinding(PositionalBinding = $false)]
param(
    [Parameter(Mandatory)][string]$From,
    [Parameter(Mandatory)][string]$To
)
. "$PSScriptRoot/WtCommon.ps1"

Assert-WtSlotName $From
Assert-WtSlotName $To
if ($From -eq $To) { throw 'Origem e destino são o mesmo slot.' }
Assert-WtPanelOwnership
$profiles = Get-WtProfiles

Invoke-WtLocked {
    $slots = @(Get-WtSlotInfo $profiles)
    $src = $slots | Where-Object Name -eq $From
    $dst = $slots | Where-Object Name -eq $To
    if ($src.State -notin 'ocupado', 'livre', 'sujo') { throw "Slot $From não tem worktree para mover (estado: $($src.State))." }
    if ($dst.State -ne 'vazio') { throw "Destino $To não está vazio (estado: $($dst.State)$(if ($dst.Branch) { ", branch '$($dst.Branch)'" }))." }
    if ($src.Branch) {
        $allowed = Get-WtAllowedSlots $src.Branch
        if ($To -notin $allowed) { throw "Destino $To fora da faixa de '$($src.Branch)' ($($allowed -join ', '))." }
    }
    if (Test-WtFolderLocked $src.Path) {
        throw "Slot $From tem arquivo preso por outro processo (IDE, servidor web de desenvolvimento, build, terminal aberto na pasta...). Feche e tente de novo."
    }
    # Pasta de destino vazia já existente faria o git mover PARA DENTRO dela (<To>\<From>).
    if (Test-Path $dst.Path) { Remove-Item -LiteralPath $dst.Path }
    Invoke-Git -Dir $src.RepoRoot -GitArgs @('worktree', 'move', $src.Path, $dst.Path) | Out-Null
    Write-Host "Slot $From -> $To$(if ($src.Branch) { " ($($src.RepoName):$($src.Branch))" })"

    $metaAll = Read-WtMeta
    if ($metaAll.ContainsKey($From)) { $metaAll[$To] = $metaAll[$From]; $metaAll.Remove($From) }
    Save-WtMeta $metaAll

    if ($src.Profile) {
        Invoke-WtHook $src.Profile.PostAttachHook 'pós-attach' @{
            Root = $src.Profile.Root; Repo = $src.RepoName; Slot = $To; Path = $dst.Path; Branch = $src.Branch; Created = $false; Meta = $metaAll[$To]
        }
    }
    Write-Host "Painel: $(Write-WtReadme $profiles)"
}
