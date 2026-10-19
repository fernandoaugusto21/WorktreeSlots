#Requires -Version 7
<#
.SYNOPSIS
    Ocupa um slot do pool com uma branch de um repo (perfil).
.DESCRIPTION
    - Repo: -Repo <perfil>, ou inferido do diretório corrente.
    - Sem -Slot: 1º livre@repo; senão 1º vazio; senão (só com -Convert) o livre de outro repo
      ocioso há mais tempo. Slot ocupado nunca é tomado.
    - Política de faixas ($WtSlotPolicy): só slots da faixa da branch são escolhidos/aceitos;
      -Slot fora da faixa é recusado. Na adoção (branch já num slot) fora da faixa, só avisa —
      corrija com Move-WtSlot.ps1.
    - -Convert é a confirmação explícita para mudar a afinidade de um slot livre de outro repo
      (worktree remove + add). Quem chama (pessoa ou skill) deve ter perguntado antes.
    - Branch local existente -> switch; só no remote -> switch com tracking;
      inexistente -> cria a partir de <remote>/<Base> (sem upstream; o push -u define).
    - Idempotente: branch já num slot -> só atualiza metadados e roda o gancho (é assim que se
      ADOTA uma worktree que já está no caminho de um slot).
    - -Ticket grava o id quando não está no nome da branch; -Meta grava campos livres:
      um único argumento 'k1=v1;k2=v2' (separador ';'). Via pwsh -File, vírgula NÃO separa
      valores — a lista chegaria quebrada ou como um valor só. Chave: letras/dígitos/_/-.
.EXAMPLE
    pwsh Attach-WtSlot.ps1 -Repo exemplo -Branch hf-proj123-exemplo -Purpose "Correção X"
.EXAMPLE
    pwsh Attach-WtSlot.ps1 -Repo exemplo -Slot g2 -Branch fb-Exp-llm -Ticket PROJ-42 -Meta 'familia=A > B > C;diario=docs/proj-42.md'
#>
# Sem binding posicional: argumento solto (ex.: lista quebrada pelo shell) é erro, nunca vira -Purpose/-Base.
[CmdletBinding(PositionalBinding = $false)]
param(
    [Parameter(Mandatory)][string]$Branch,
    [string]$Repo,
    [string]$Slot,
    [string]$Base,
    [string]$Purpose,
    [string]$Ticket,
    [string[]]$Meta,
    [switch]$Convert,
    [switch]$NoFetch
)
. "$PSScriptRoot/WtCommon.ps1"

Assert-WtSlotName $Slot
Assert-WtPanelOwnership
$profiles = Get-WtProfiles
$prof = Resolve-WtProfile $profiles $Repo
if (-not $Base) { $Base = $prof.Base }
$remote = $prof.Remote
if (-not $NoFetch) { Invoke-Git -Dir $prof.Root -GitArgs @('fetch', $remote, '--prune', '--quiet') | Out-Null }
if ($Branch -notmatch $prof.BranchPattern) {
    Write-Warning "'$Branch' foge da convenção de nomes de '$($prof.Name)' ($($prof.BranchPattern)). Seguindo mesmo assim."
}

# -Meta: 'k1=v1;k2=v2' num argumento só (via pwsh -File, vírgula não vira lista). Valida ANTES de
# qualquer efeito: chave inválida (ex.: aspas que o shell não removeu) aborta com mensagem clara.
$metaPairs = foreach ($kv in @($Meta | ForEach-Object { $_ -split ';' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })) {
    if ($kv -notmatch '^([A-Za-z_][\w-]*)=(.*)$') {
        throw "-Meta: '$kv' não é 'chave=valor' (chave: letras, dígitos, _ ou -). Vários campos: -Meta 'k1=v1;k2=v2' num argumento só."
    }
    [pscustomobject]@{ Key = $Matches[1]; Value = $Matches[2].Trim() }
}
# Faixa de slots da branch (política). Erro guardado: recusa attach novo, mas só avisa na adoção.
$policyError = $null
$allowed = try { Get-WtAllowedSlots $Branch } catch { $policyError = $_.Exception.Message; @() }
$rangeText = if ($policyError) { $policyError } else { "faixa de '$Branch': $($allowed -join ', ')" }
$hasPurpose = $PSBoundParameters.ContainsKey('Purpose')   # capturado fora: dentro do scriptblock $PSBoundParameters é outro

Invoke-WtLocked {
    $slots = @(Get-WtSlotInfo $profiles)
    $metaAll = Read-WtMeta
    $created = $false

    $holder = Get-WtWorktrees $prof.Root | Where-Object { $_.Branch -eq $Branch } | Select-Object -First 1
    if ($holder) {
        $target = $slots | Where-Object { (ConvertTo-WtPathKey $_.Path) -eq (ConvertTo-WtPathKey $holder.Path) } | Select-Object -First 1
        if (-not $target) {
            throw "A branch '$Branch' já está em uso na worktree '$($holder.Path)' (fora dos slots). Libere-a lá, ou mova-a: git worktree move '$($holder.Path)' <pool>\<slot>."
        }
        if ($Slot -and $Slot -ne $target.Name) { throw "A branch '$Branch' já está no slot $($target.Name), não em $Slot." }
        Write-Host "Branch '$Branch' já ocupa $($target.Name) — atualizando só os metadados."
        if ($target.Name -notin $allowed) { Write-Warning "$($target.Name) está fora da faixa da branch ($rangeText). Mova com Move-WtSlot.ps1 -From $($target.Name) -To <slot da faixa>." }
    } else {
        if ($policyError) { throw $policyError }
        if ($Slot) {
            if ($Slot -notin $allowed) { throw "Slot $Slot fora da faixa ($rangeText)." }
            $target = $slots | Where-Object Name -eq $Slot
        } else {
            $inRange = @($slots | Where-Object { $_.Name -in $allowed })
            $target = $inRange | Where-Object { $_.State -eq 'livre' -and $_.RepoName -eq $prof.Name } | Select-Object -First 1
            if (-not $target) { $target = $inRange | Where-Object State -eq 'vazio' | Select-Object -First 1 }
            if (-not $target) {
                $cand = $inRange | Where-Object { $_.State -eq 'livre' -and $_.RepoName -ne $prof.Name } |
                    Sort-Object { if ($_.FreedAt) { $_.FreedAt } else { '0000' } } | Select-Object -First 1
                if (-not $cand) { throw "Nenhum slot livre ou vazio na faixa ($rangeText). Veja $($script:WtDir)\README.md e libere um com Detach-WtSlot.ps1." }
                if (-not $Convert) {
                    throw "Nenhum slot livre@$($prof.Name) nem vazio. Candidato à conversão: $($cand.Name) (livre@$($cand.RepoName)$(if ($cand.FreedAt) { ", livre desde $($cand.FreedAt)" })). Rode de novo com -Convert para convertê-lo."
                }
                $target = $cand
            }
        }

        switch ($target.State) {
            'vazio' { New-WtSlotWorktree $target $prof; $created = $true }
            'livre' {
                if ($target.RepoName -ne $prof.Name) {
                    if (-not $Convert) { throw "Slot $($target.Name) é livre@$(if ($target.RepoName) { $target.RepoName } else { $target.RepoRoot }). Para convertê-lo para '$($prof.Name)', rode de novo com -Convert." }
                    Write-Host "Convertendo $($target.Name): $($target.RepoName) -> $($prof.Name)..."
                    Remove-WtSlotWorktree $target
                    New-WtSlotWorktree $target $prof; $created = $true
                }
            }
            default { throw "Slot $($target.Name) não está disponível (estado: $($target.State)$(if ($target.Branch) { ", branch '$($target.Branch)'" }))." }
        }

        $hasLocal = (Invoke-Git -Dir $prof.Root -GitArgs @('show-ref', '--verify', '--quiet', "refs/heads/$Branch") -AllowFail).Ok
        $hasRemote = (Invoke-Git -Dir $prof.Root -GitArgs @('show-ref', '--verify', '--quiet', "refs/remotes/$remote/$Branch") -AllowFail).Ok
        if ($hasLocal) {
            Invoke-Git -Dir $target.Path -GitArgs @('switch', $Branch) | Out-Null
            $how = 'branch local existente'
        } elseif ($hasRemote) {
            Invoke-Git -Dir $target.Path -GitArgs @('switch', '--track', "$remote/$Branch") | Out-Null
            $how = "rastreando $remote/$Branch"
        } else {
            if (-not (Invoke-Git -Dir $prof.Root -GitArgs @('show-ref', '--verify', '--quiet', "refs/remotes/$remote/$Base") -AllowFail).Ok) {
                throw "Base '$remote/$Base' não existe em $($prof.Root)."
            }
            Invoke-Git -Dir $target.Path -GitArgs @('switch', '--no-track', '-c', $Branch, "$remote/$Base") | Out-Null
            $how = "nova, cortada de $remote/$Base"
        }
        Write-Host "Slot $($target.Name) <- $($prof.Name):$Branch ($how)"
        $metaAll[$target.Name] = @{ attachedAt = (Get-Date -Format 'yyyy-MM-dd') }
    }

    $entry = if ($metaAll.ContainsKey($target.Name)) { $metaAll[$target.Name] } else { @{ attachedAt = (Get-Date -Format 'yyyy-MM-dd') } }
    $entry.Remove('freedAt')
    foreach ($kv in $metaPairs) { $entry[$kv.Key] = $kv.Value }
    $entry['repo'] = $prof.Name
    $entry['branch'] = $Branch
    if ($Ticket) { $entry['ticket'] = $Ticket } elseif (-not $entry['ticket']) { $entry['ticket'] = Get-WtTicketId $prof $Branch }
    if ($hasPurpose) { $entry['purpose'] = $Purpose }
    $metaAll[$target.Name] = $entry
    Save-WtMeta $metaAll

    Invoke-WtHook $prof.PostAttachHook 'pós-attach' @{
        Root = $prof.Root; Repo = $prof.Name; Slot = $target.Name; Path = $target.Path; Branch = $Branch; Created = $created; Meta = $entry
    }
    $readme = Write-WtReadme $profiles
    Write-Host "Caminho: $($target.Path)"
    Write-Host "Painel:  $readme"
}
