#Requires -Version 7
<#
.SYNOPSIS
    Devolve um slot ao estado livre@repo: HEAD detached em <remote>/<base> do repo do slot.
    A afinidade com o repo é mantida (o slot não é esvaziado — para isso, Convert-WtSlot.ps1).
.DESCRIPTION
    Ordem: valida -DeleteBranch -> harvest do perfil (se habilitado e sem -NoHarvest) ->
    gancho PreDetachHook -> -Stash (se pedido) -> recusa se ainda sujo -> detach.
    - Harvest: copia não rastreados + rastreados modificados para o checkout principal do repo
      (mesmo caminho relativo, hash conferido). Destino existente e diferente aborta tudo antes
      de copiar. Exclude/PatchOnly do perfil. Não limpa o slot: combine com -Stash.
    - -Stash: git stash push -u rotulado "wt-detach <slot> <branch> <data>" (stash é do repo).
    - -DeleteBranch apaga a branch LOCAL só se contida em <remote>/<base>. Remota nunca é tocada.
      Squash de sanitização não aparece como contido: detach sem -DeleteBranch e apague à mão.
    - Submódulos inicializados no slot: recusa se algum tiver alterações ou HEAD não publicado; os
      que não existem na base têm a working tree MOVIDA para <pool>/_backup/<slot>_<data>/, os que
      existem em outro commit são alinhados com `git submodule update`.
    - Ignorados por um .gitignore que só existe na branch viram não rastreados na base: são MOVIDOS
      para <pool>/_backup/<slot>_<data>/ (com RESTAURAR.txt) em vez de deixar o slot sujo.
    - -CleanIgnored remove ignorados do slot, preservando junctions/symlinks e CleanKeep do perfil.
.EXAMPLE
    pwsh Detach-WtSlot.ps1 -Slot g1 -Stash
.EXAMPLE
    pwsh Detach-WtSlot.ps1 -Branch hf-proj123-exemplo -DeleteBranch
#>
# Sem binding posicional: argumento solto (ex.: lista quebrada pelo shell) é erro, nunca vira -Purpose/-Base.
[CmdletBinding(PositionalBinding = $false)]
param(
    [string]$Slot,
    [string]$Branch,
    [switch]$DeleteBranch,
    [switch]$Stash,
    [switch]$NoHarvest,
    [switch]$CleanIgnored,
    [switch]$NoFetch
)
. "$PSScriptRoot/WtCommon.ps1"

Assert-WtSlotName $Slot
if (-not $Slot -and -not $Branch) { throw "Informe -Slot $($script:WtSlotPrefix)N ou -Branch <nome>." }
Assert-WtPanelOwnership
$profiles = Get-WtProfiles

Invoke-WtLocked {
    $slots = @(Get-WtSlotInfo $profiles)
    $target = if ($Slot) { $slots | Where-Object Name -eq $Slot } else { $slots | Where-Object Branch -eq $Branch | Select-Object -First 1 }
    if (-not $target) { throw "Nenhum slot com a branch '$Branch'." }
    if ($target.State -notin 'ocupado', 'sujo') { throw "Slot $($target.Name) não está ocupado (estado: $($target.State))." }
    $prof = $target.Profile
    if (-not $prof) { throw "Slot $($target.Name) pertence a um repo sem perfil ($($target.RepoRoot)). Crie o perfil antes." }
    $baseRef = Get-WtBaseRef $prof
    if (-not $NoFetch) { Invoke-Git -Dir $prof.Root -GitArgs @('fetch', $prof.Remote, '--prune', '--quiet') | Out-Null }

    $b = $target.Branch
    $merged = $b -and (Invoke-Git -Dir $prof.Root -GitArgs @('merge-base', '--is-ancestor', $b, $baseRef) -AllowFail).Ok
    if ($DeleteBranch -and $b -and -not $merged) {
        throw "-DeleteBranch recusado: '$b' ainda não está contida em $baseRef. Faça o merge da PR antes (ou rode sem -DeleteBranch; se foi squash, confira e apague à mão com git branch -D)."
    }

    if (-not $NoHarvest) { Invoke-WtHarvest $target $prof }
    Invoke-WtHook $prof.PreDetachHook 'pré-detach' @{
        Root = $prof.Root; Repo = $prof.Name; Slot = $target.Name; Path = $target.Path; Branch = $b; Created = $false; Meta = $target.Meta
    }

    $tree = Get-WtTreeState $target.Path
    if ($tree.Dirty -and $Stash) {
        $label = "wt-detach $($target.Name) $(if ($b) { $b } else { 'detached' }) $(Get-Date -Format 'yyyy-MM-dd HH:mm')"
        Invoke-Git -Dir $target.Path -GitArgs @('stash', 'push', '--include-untracked', '-m', $label) | Out-Null
        Write-Host "Alterações guardadas em stash de $($prof.Name): '$label' (git stash list; recuperar com git stash apply <ref> num slot com '$b')."
        $tree = Get-WtTreeState $target.Path
    }
    if ($tree.Dirty) {
        throw "Slot $($target.Name) tem alterações locais — faça commit, -Stash, ou descarte conscientemente antes do detach:`n$($tree.Porcelain -join "`n")"
    }

    if ($b) {
        $up = Invoke-Git -Dir $target.Path -GitArgs @('rev-parse', '--abbrev-ref', "$b@{upstream}") -AllowFail
        if ($up.Ok) {
            $ahead = (Invoke-Git -Dir $target.Path -GitArgs @('rev-list', '--count', "$($up.Lines[0])..$b")).Lines[0]
            if ([int]$ahead -gt 0) { Write-Warning "'$b' tem $ahead commit(s) sem push para $($up.Lines[0]). A branch local continua existindo." }
        } elseif (-not $merged) {
            Write-Warning "'$b' não tem upstream e não está em $baseRef — os commits só existem localmente, na branch."
        }
    }

    # Submódulos inicializados que o switch deixaria para trás: confere ANTES de qualquer efeito.
    $subs = @(Get-WtSubmodulePlan $target.Path $baseRef)
    foreach ($s in $subs) { Assert-WtSubmoduleSafe $s }
    # Ignorados de agora: os que virarem não rastreados depois do switch vão para _backup.
    $ignoredBefore = Get-WtIgnoredFiles $target.Path

    Invoke-Git -Dir $target.Path -GitArgs @('switch', '--detach', $baseRef) | Out-Null

    $backup = Join-Path $script:WtDir "_backup/$($target.Name)_$(Get-Date -Format yyyyMMdd-HHmmss)"
    foreach ($s in $subs) {
        if ($s.Kind -eq 'orphan') {
            $dest = Move-WtOrphanSubmodule $backup $s
            Write-Host "Submódulo '$($s.Rel)' não existe em ${baseRef}: working tree movida para $dest (nada apagado)."
        } else {
            Invoke-Git -Dir $target.Path -GitArgs @('submodule', 'update', '--', $s.Rel) | Out-Null
            Write-Host "Submódulo '$($s.Rel)' alinhado ao commit registrado em $baseRef."
        }
    }
    foreach ($rel in @(Move-WtIgnoredLeftovers $target.Path $backup $ignoredBefore $b)) {
        Write-Host "'$rel' era ignorado pela branch e ficaria não rastreado em ${baseRef}: movido para $(Join-Path $backup $rel) (nada apagado)."
    }
    $after = Get-WtTreeState $target.Path
    if ($after.Dirty) { Write-Warning "Slot $($target.Name) ainda tem alterações depois do detach:`n$($after.Porcelain -join "`n")" }
    Write-Host "Slot $($target.Name) liberado (livre@$($prof.Name), detached em $baseRef)."

    $metaAll = Read-WtMeta
    $metaAll[$target.Name] = @{ repo = $prof.Name; freedAt = (Get-Date -Format 'yyyy-MM-dd HH:mm') }
    Save-WtMeta $metaAll

    if ($b -and $DeleteBranch) {
        # Roda no slot (HEAD = base), não na raiz: `branch -d` mede o merge contra o HEAD de onde roda.
        Invoke-Git -Dir $target.Path -GitArgs @('branch', '-d', $b) | Out-Null
        Write-Host "Branch local '$b' apagada (remota intocada)."
    }

    if ($CleanIgnored) {
        $keepArgs = @(Get-WtCleanKeepArgs $target.Path $prof)
        Invoke-Git -Dir $target.Path -GitArgs (@('clean', '-fdX') + $keepArgs) | Out-Null
        if ($keepArgs) { Write-Host "Preservados: $(($keepArgs | Where-Object { $_ -ne '-e' }) -join ', ')" }
        Write-Host 'Arquivos ignorados removidos do slot.'
    } else {
        $left = (Get-WtTreeState $target.Path).Ignored
        if ($left -gt 0) { Write-Host "Obs.: $left item(ns) ignorado(s) (build/saídas) ficaram no slot; -CleanIgnored remove." }
    }
    Write-Host "Painel: $(Write-WtReadme $profiles)"
}
