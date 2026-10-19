#Requires -Version 7
# Sandbox: operação do pool — README manual, attach/afinidade/ticket/-Meta, conversão, lock,
# harvest, -Stash, painel, adoção, faixas e Move. Dois repos com remoto bare; o pool mora dentro de
# um terceiro repo. Não toca em nada fora de -Sandbox.
param([Parameter(Mandatory)][string]$Engine, [Parameter(Mandatory)][string]$Sandbox)
$ErrorActionPreference = 'Stop'
$env:GIT_AUTHOR_NAME = 'sbx'; $env:GIT_AUTHOR_EMAIL = 'sbx@example.invalid'
$env:GIT_COMMITTER_NAME = 'sbx'; $env:GIT_COMMITTER_EMAIL = 'sbx@example.invalid'
Remove-Item Env:WT_CONFIG -ErrorAction SilentlyContinue
if (Test-Path $Sandbox) { throw "Sandbox já existe: $Sandbox" }
function G { param([string]$Dir) $out = & git -C $Dir @args 2>&1; if ($LASTEXITCODE) { throw "git $args em ${Dir}: $out" }; $out }

# ---- montagem
$outer = Join-Path $Sandbox 'outer'; $tools = Join-Path $outer 'tools\wt'; $pool = Join-Path $outer 'wt'
$alpha = Join-Path $Sandbox 'repos\alpha'; $beta = Join-Path $Sandbox 'repos\beta'; $shared = Join-Path $Sandbox 'shared-alpha'
New-Item -ItemType Directory -Force $tools, $alpha, $beta, $shared | Out-Null
Copy-Item "$Engine\*" $tools -Recurse
Remove-Item "$tools\profiles\*.ps1"; Remove-Item "$tools\wt.config.json" -ErrorAction SilentlyContinue
G $outer init -q -b main; Set-Content "$outer\.gitignore" "/wt/`n/tools/"; G $outer add .; G $outer commit -q -m outer
Set-Content "$shared\keep.txt" 'conteúdo do destino da junction'

New-Item -ItemType Directory -Force "$alpha\config" | Out-Null
Set-Content "$alpha\README.md" alpha; Set-Content "$alpha\config\local.settings.json" base
Set-Content "$alpha\.gitignore" "shared`n.claude/"
G $alpha init -q -b develop; G $alpha add .; G $alpha commit -q -m init
G $Sandbox init -q --bare "$Sandbox\remotes\alpha.git"
G $alpha remote add origin ("$Sandbox\remotes\alpha.git" -replace '\\', '/'); G $alpha push -q -u origin develop
Set-Content "$beta\README.md" beta
G $beta init -q -b develop; G $beta add .; G $beta commit -q -m init
G $Sandbox init -q --bare "$Sandbox\remotes\beta.git"
G $beta remote add origin ("$Sandbox\remotes\beta.git" -replace '\\', '/'); G $beta push -q -u origin develop

Set-Content "$tools\profiles\alpha.ps1" -Encoding utf8NoBOM -Value @"
@{
    Root = '$alpha'
    TicketFromBranch = { param([string]`$Branch) if (`$Branch -match '(?i)proj-?(\d+)') { "PROJ-`$(`$Matches[1])" } else { '' } }
    ExtraColumns = @('familia')
    Harvest = @{ Enabled = `$true; Exclude = @('dados/*'); PatchOnly = @('config/local.settings.json') }
    PostAttachHook = { param(`$Ctx) `$l = Join-Path `$Ctx.Path 'shared'; if (-not (Test-Path `$l)) { New-Item -ItemType Junction -Path `$l -Target '$shared' | Out-Null } }
}
"@
Set-Content "$tools\profiles\beta.ps1" -Encoding utf8NoBOM -Value "@{ Root = '$beta' }"

# ---- utilitários
$results = [Collections.Generic.List[object]]::new()
function Run([string]$Script, [string[]]$A) {
    $out = & pwsh -NoProfile -File (Join-Path $tools $Script) @A 2>&1 | ForEach-Object { "$_" }
    [pscustomobject]@{ Exit = $LASTEXITCODE; Out = ($out -join "`n") }
}
function Check([string]$Id, [string]$Desc, [bool]$Ok, [string]$Detail = '') {
    $results.Add([pscustomobject]@{ Id = $Id; Ok = $(if ($Ok) { 'OK' } else { 'FALHOU' }); Desc = $Desc; Detail = $Detail })
}
function Reg { if (Test-Path "$pool\.slots.json") { Get-Content "$pool\.slots.json" -Raw | ConvertFrom-Json -AsHashtable } else { @{} } }
function Panel { if (Test-Path "$pool\README.md") { Get-Content "$pool\README.md" -Raw } else { '' } }
function BranchOf([string]$Slot) { if (Test-Path "$pool\$Slot\.git") { (& git -C "$pool\$Slot" branch --show-current 2>$null) } else { '' } }
function RootOf([string]$Slot) { Split-Path ([IO.Path]::GetFullPath((& git -C "$pool\$Slot" rev-parse --path-format=absolute --git-common-dir))) -Parent }
function Hold([string]$File) { [IO.File]::Open($File, 'Open', 'Read', 'None') }
function Policy([bool]$Strict) {
    @{ slotPolicyStrict = $Strict; slotPolicy = @(
        @{ label = 'hotfix'; pattern = '^hf-'; slots = @('g1', 'g2') },
        @{ label = 'feature'; pattern = '^fb-'; slots = @('g3', 'g4', 'g5') }) } |
        ConvertTo-Json -Depth 5 | Set-Content "$tools\wt.config.json" -Encoding utf8NoBOM
}
Push-Location $Sandbox
try {

# P1 README manual no pool
New-Item -ItemType Directory -Force $pool | Out-Null
Set-Content "$pool\README.md" '# manifesto escrito à mão'
$r = Run 'Attach-WtSlot.ps1' @('-Repo', 'alpha', '-Branch', 'fb-proj7-x', '-NoFetch')
Check 'P1' 'README manual no pool: recusa sem efeito' ($r.Exit -ne 0 -and $r.Out -match 'não foi gerado pelo painel' -and -not (Test-Path "$pool\g1")) $r.Out
Rename-Item "$pool\README.md" '_manifesto_legado.md'
New-Item -ItemType Directory -Force "$pool\_legado" | Out-Null; Set-Content "$pool\_legado\velho.txt" v

# P2 vazio -> slot; ticket normalizado; -Meta; colunas extras; gancho
$r = Run 'Attach-WtSlot.ps1' @('-Repo', 'alpha', '-Branch', 'fb-proj7-x', '-Purpose', 'p2', '-Meta', 'familia=A > B;diario=d.md', '-NoFetch')
$g = Reg
Check 'P2a' 'vazio vira worktree (g1), ticket normalizado PROJ-7' ($r.Exit -eq 0 -and (BranchOf 'g1') -eq 'fb-proj7-x' -and $g['g1'].ticket -eq 'PROJ-7') $r.Out
Check 'P2b' '-Meta com dois campos e coluna extra no painel' ($g['g1'].familia -eq 'A > B' -and $g['g1'].diario -eq 'd.md' -and (Panel) -match '\| familia \|' -and (Panel) -match 'A > B') (Panel)
Check 'P2c' 'gancho pós-attach criou a junction' ((Get-Item "$pool\g1\shared" -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) ''

# P3 -Ticket explícito
$r = Run 'Attach-WtSlot.ps1' @('-Repo', 'beta', '-Branch', 'fb-y', '-Ticket', 'T-9', '-NoFetch')
Check 'P3' '-Ticket explícito gravado (g2)' ($r.Exit -eq 0 -and (BranchOf 'g2') -eq 'fb-y' -and (Reg)['g2'].ticket -eq 'T-9') $r.Out

# P4 afinidade no detach; preferência livre@repo > vazio
$r = Run 'Detach-WtSlot.ps1' @('-Slot', 'g1', '-NoFetch')
$g = Reg
Check 'P4a' 'detach mantém afinidade (repo + freedAt, sem branch)' ($r.Exit -eq 0 -and $g['g1'].repo -eq 'alpha' -and $g['g1'].freedAt -and -not $g['g1'].branch -and -not (BranchOf 'g1')) $r.Out
$r = Run 'Attach-WtSlot.ps1' @('-Repo', 'alpha', '-Branch', 'fb-z', '-NoFetch')
Check 'P4b' 'livre@repo (g1) preferido a vazio (g3)' ($r.Exit -eq 0 -and (BranchOf 'g1') -eq 'fb-z' -and -not (Test-Path "$pool\g3")) $r.Out

# P5 conversão: recusada sem -Convert; com -Convert não toca o destino da junction
$r = Run 'Detach-WtSlot.ps1' @('-Slot', 'g1', '-NoFetch')
$r = Run 'Attach-WtSlot.ps1' @('-Repo', 'beta', '-Branch', 'fb-w', '-Slot', 'g1', '-NoFetch')
Check 'P5a' 'livre de outro repo recusado sem -Convert' ($r.Exit -ne 0 -and $r.Out -match '-Convert' -and (RootOf 'g1') -eq $alpha) $r.Out
$r = Run 'Attach-WtSlot.ps1' @('-Repo', 'beta', '-Branch', 'fb-w', '-Slot', 'g1', '-Convert', '-NoFetch')
Check 'P5b' 'com -Convert: g1 vira beta e o destino da junction fica intacto' ($r.Exit -eq 0 -and (RootOf 'g1') -eq $beta -and (BranchOf 'g1') -eq 'fb-w' -and (Test-Path "$shared\keep.txt")) $r.Out

# P6 conversão recusada com arquivo preso
$r = Run 'Detach-WtSlot.ps1' @('-Slot', 'g2', '-NoFetch')
$h = Hold "$pool\g2\README.md"
try { $r = Run 'Convert-WtSlot.ps1' @('-Slot', 'g2', '-Repo', 'alpha', '-NoFetch') } finally { $h.Dispose() }
Check 'P6' 'conversão recusada com arquivo preso, slot intacto' ($r.Exit -ne 0 -and $r.Out -match 'arquivo preso' -and (RootOf 'g2') -eq $beta) $r.Out

# P7 slot ocupado nunca convertido
$r = Run 'Convert-WtSlot.ps1' @('-Slot', 'g1', '-Repo', 'alpha', '-NoFetch')
Check 'P7' 'slot ocupado nunca convertido' ($r.Exit -ne 0 -and (BranchOf 'g1') -eq 'fb-w') $r.Out

# P8 Convert -Empty e -Repo
$r = Run 'Convert-WtSlot.ps1' @('-Slot', 'g2', '-Empty', '-NoFetch')
Check 'P8a' 'Convert -Empty: livre -> vazio, sai do registro' ($r.Exit -eq 0 -and -not (Test-Path "$pool\g2\.git") -and -not (Reg).ContainsKey('g2')) $r.Out
$r = Run 'Convert-WtSlot.ps1' @('-Slot', 'g2', '-Repo', 'alpha', '-NoFetch')
Check 'P8b' 'Convert -Repo: vazio -> livre@alpha' ($r.Exit -eq 0 -and (RootOf 'g2') -eq $alpha -and (Reg)['g2'].repo -eq 'alpha') $r.Out

# P9 lock: dois attaches concorrentes pelo mesmo slot
$jobs = foreach ($b in 'fb-c1', 'fb-c2') {
    Start-Job -ArgumentList $tools, $b, $Sandbox -ScriptBlock {
        param($tools, $b, $sbx)
        Set-Location $sbx
        $env:GIT_AUTHOR_NAME = 'sbx'; $env:GIT_AUTHOR_EMAIL = 'sbx@example.invalid'; $env:GIT_COMMITTER_NAME = 'sbx'; $env:GIT_COMMITTER_EMAIL = 'sbx@example.invalid'
        $o = & pwsh -NoProfile -File "$tools\Attach-WtSlot.ps1" -Repo beta -Branch $b -Slot g4 -NoFetch 2>&1 | Out-String
        [pscustomobject]@{ Branch = $b; Exit = $LASTEXITCODE; Out = $o }
    }
}
$jr = @($jobs | Wait-Job | Receive-Job); $jobs | Remove-Job
$win = @($jr | Where-Object Exit -eq 0)
Check 'P9' 'attaches concorrentes: um vence, o outro recusa, registro = git' ($win.Count -eq 1 -and (BranchOf 'g4') -eq $win[0].Branch -and (Reg)['g4'].branch -eq $win[0].Branch) (($jr | ForEach-Object { "$($_.Branch) exit=$($_.Exit)`n$($_.Out)" }) -join "`n")

# P10/P11 harvest
$r = Run 'Attach-WtSlot.ps1' @('-Repo', 'alpha', '-Branch', 'fb-h', '-Slot', 'g2', '-NoFetch')
$s2 = "$pool\g2"; New-Item -ItemType Directory -Force "$s2\dados" | Out-Null
Set-Content "$s2\notes.md" slot; Set-Content "$s2\new.md" novo; Set-Content "$s2\same.md" igual; Set-Content "$s2\dados\x.cache" c
Set-Content "$s2\config\local.settings.json" slot-config
Set-Content "$alpha\notes.md" raiz; Set-Content "$alpha\same.md" igual
$r = Run 'Detach-WtSlot.ps1' @('-Slot', 'g2', '-NoFetch')
Check 'P10' 'harvest com conflito: aborta e não copia nada' ($r.Exit -ne 0 -and $r.Out -match 'Harvest abortado' -and -not (Test-Path "$alpha\new.md") -and (BranchOf 'g2') -eq 'fb-h') $r.Out
Remove-Item "$alpha\notes.md"
$r = Run 'Detach-WtSlot.ps1' @('-Slot', 'g2', '-Stash', '-NoFetch')
$patch = @(Get-ChildItem "$pool\_backup" -Recurse -Filter 'local.settings.json.patch' -ErrorAction SilentlyContinue)
$stash = (G $alpha stash list) -join "`n"
Check 'P11a' 'harvest copia novos (new.md, notes.md) para o principal' ($r.Exit -eq 0 -and (Get-Content "$alpha\new.md") -eq 'novo' -and (Get-Content "$alpha\notes.md") -eq 'slot') $r.Out
Check 'P11b' 'idêntico não muda; Exclude não copia' ((Get-Content "$alpha\same.md") -eq 'igual' -and -not (Test-Path "$alpha\dados")) ''
Check 'P11c' 'PatchOnly: .patch + cópia no _backup, principal intocado' ($patch.Count -eq 1 -and (Test-Path ($patch[0].FullName -replace '\.patch$', '')) -and (Get-Content "$alpha\config\local.settings.json") -eq 'base') ''
Check 'P11d' '-Stash rotulado e slot livre limpo' ($stash -match 'wt-detach g2 fb-h' -and -not (BranchOf 'g2') -and -not (G $s2 status --porcelain)) $stash

# P12 divergência registro x git
$g = Reg; $g['g1']['repo'] = 'alpha'; $g | ConvertTo-Json -Depth 5 | Set-Content "$pool\.slots.json" -Encoding utf8NoBOM
$r = Run 'Update-WtStatus.ps1' @('-NoFetch')
Check 'P12a' 'painel acusa registro divergente do git' ((Panel) -match "registro diz 'alpha', git diz 'beta'") (Panel)
$r = Run 'Attach-WtSlot.ps1' @('-Repo', 'beta', '-Branch', 'fb-w', '-NoFetch')
Check 'P12b' 'attach idempotente corrige o registro' ($r.Exit -eq 0 -and (Reg)['g1'].repo -eq 'beta' -and (Panel) -notmatch 'registro diz') $r.Out

# P13 worktree de agente oculta
G $alpha worktree add -q --detach "$alpha\.claude\worktrees\agent-1" origin/develop
$r = Run 'Update-WtStatus.ps1' @('-NoFetch')
Check 'P13' 'worktree de agente só contada, não listada' ((Panel) -match 'oculta' -and (Panel) -notmatch 'agent-1') (Panel)

# P14 slot vazio dentro de outro repo (pasta vazia) recebe worktree
New-Item -ItemType Directory -Force "$pool\g7" | Out-Null
$r = Run 'Attach-WtSlot.ps1' @('-Repo', 'beta', '-Branch', 'fb-v', '-Slot', 'g7', '-NoFetch')
Check 'P14' 'pasta vazia dentro de outro repo é vazio (não o repo de fora)' ($r.Exit -eq 0 -and (RootOf 'g7') -eq $beta -and (BranchOf 'g7') -eq 'fb-v') $r.Out

# P15 migração: worktree move + attach idempotente
G $beta worktree add -q -b fb-old "$Sandbox\old-wt" origin/develop
Add-Content "$Sandbox\old-wt\README.md" 'mudança local'
G $beta worktree move "$Sandbox\old-wt" "$pool\g6"
$r = Run 'Attach-WtSlot.ps1' @('-Repo', 'beta', '-Branch', 'fb-old', '-Slot', 'g6', '-Purpose', 'adotado', '-NoFetch')
Check 'P15' 'adoção: registra sem mexer no git, mudança local preservada' ($r.Exit -eq 0 -and $r.Out -match 'já ocupa g6' -and (Reg)['g6'].purpose -eq 'adotado' -and (Get-Content "$pool\g6\README.md" -Raw) -match 'mudança local') $r.Out

# P16 -Meta em 4 formas de chamada
$att = Join-Path $tools 'Attach-WtSlot.ps1'
$r = Run 'Attach-WtSlot.ps1' @('-Repo', 'beta', '-Branch', 'fb-old', '-Meta', 'k1=v1;k2=v2', '-NoFetch')
Check 'P16a' "PowerShell, 'k1=v1;k2=v2': grava os dois" ($r.Exit -eq 0 -and (Reg)['g6'].k1 -eq 'v1' -and (Reg)['g6'].k2 -eq 'v2') $r.Out
Set-Content "$Sandbox\meta-dq.cmd" "@pwsh -NoProfile -File `"$att`" -Repo beta -Branch fb-old -NoFetch -Meta `"k3=v3;k4=v4`""
$o = & cmd /c "$Sandbox\meta-dq.cmd" 2>&1 | Out-String
Check 'P16b' 'cmd com aspas duplas e ;: grava os dois' ((Reg)['g6'].k3 -eq 'v3' -and (Reg)['g6'].k4 -eq 'v4') $o
Set-Content "$Sandbox\meta-sq.cmd" "@pwsh -NoProfile -File `"$att`" -Repo beta -Branch fb-old -NoFetch -Meta 'k5=v5'"
$before = Get-Content "$pool\.slots.json" -Raw
$o = & cmd /c "$Sandbox\meta-sq.cmd" 2>&1 | Out-String; $ex = $LASTEXITCODE
Check 'P16c' 'cmd com aspas simples: recusa, registro intacto' ($ex -ne 0 -and (Get-Content "$pool\.slots.json" -Raw) -eq $before) $o
$o = & pwsh -NoProfile -File $att -Repo beta -Branch fb-old -NoFetch -Meta 'k6=v6', 'k7=v7' 2>&1 | Out-String; $ex = $LASTEXITCODE
Check 'P16d' 'PowerShell com lista por vírgula: erro, registro intacto' ($ex -ne 0 -and (Get-Content "$pool\.slots.json" -Raw) -eq $before) $o

# ---- faixas: hf -> g1,g2; fb -> g3,g4,g5; g6 e g7 fora das faixas
Policy $true
$r = Run 'Attach-WtSlot.ps1' @('-Repo', 'beta', '-Branch', 'fb-p1', '-NoFetch')
Check 'P17' 'escolha automática dentro da faixa (g3)' ($r.Exit -eq 0 -and (BranchOf 'g3') -eq 'fb-p1') $r.Out
$r = Run 'Attach-WtSlot.ps1' @('-Repo', 'beta', '-Branch', 'fb-p2', '-Slot', 'g2', '-NoFetch')
Check 'P18' '-Slot fora da faixa recusado sem efeito' ($r.Exit -ne 0 -and $r.Out -match 'fora da faixa' -and -not (BranchOf 'g2')) $r.Out
$r = Run 'Attach-WtSlot.ps1' @('-Repo', 'beta', '-Branch', 'doc-x', '-NoFetch')
Check 'P19' 'branch sem regra recusada (estrito)' ($r.Exit -ne 0 -and $r.Out -match 'não casa com nenhuma faixa') $r.Out
$r = Run 'Attach-WtSlot.ps1' @('-Repo', 'beta', '-Branch', 'fb-p3', '-NoFetch')
$r2 = Run 'Attach-WtSlot.ps1' @('-Repo', 'beta', '-Branch', 'fb-p4', '-NoFetch')
Check 'P20' 'faixa cheia não transborda (g2 livre e g7 ficam de fora)' ($r.Exit -eq 0 -and (BranchOf 'g5') -eq 'fb-p3' -and $r2.Exit -ne 0 -and $r2.Out -match 'Nenhum slot livre ou vazio na faixa' -and -not (BranchOf 'g2')) "$($r.Out)`n$($r2.Out)"
$r = Run 'Attach-WtSlot.ps1' @('-Repo', 'beta', '-Branch', 'fb-w', '-Slot', 'g1', '-NoFetch')
Check 'P21' 'adoção fora da faixa só avisa' ($r.Exit -eq 0 -and $r.Out -match 'fora da faixa') $r.Out
$r = Run 'Update-WtStatus.ps1' @('-NoFetch')
Check 'P22' 'painel mostra faixa e aviso de branch fora dela' ((Panel) -match '\*\*g1\*\* _hotfix_' -and (Panel) -match 'branch fora da faixa') (Panel)

# Move
$r = Run 'Convert-WtSlot.ps1' @('-Slot', 'g2', '-Empty', '-NoFetch')
$r = Run 'Move-WtSlot.ps1' @('-From', 'g1', '-To', 'g2')
Check 'P23a' 'Move recusado para fora da faixa' ($r.Exit -ne 0 -and $r.Out -match 'fora da faixa' -and (BranchOf 'g1') -eq 'fb-w') $r.Out
$r = Run 'Move-WtSlot.ps1' @('-From', 'g1', '-To', 'g3')
Check 'P23b' 'Move recusado para slot ocupado' ($r.Exit -ne 0 -and $r.Out -match 'não está vazio') $r.Out
$r = Run 'Detach-WtSlot.ps1' @('-Slot', 'g5', '-NoFetch'); $r = Run 'Convert-WtSlot.ps1' @('-Slot', 'g5', '-Empty', '-NoFetch')
$h = Hold "$pool\g1\README.md"
try { $r = Run 'Move-WtSlot.ps1' @('-From', 'g1', '-To', 'g5') } finally { $h.Dispose() }
Check 'P23c' 'Move recusado com arquivo preso' ($r.Exit -ne 0 -and $r.Out -match 'arquivo preso' -and (BranchOf 'g1') -eq 'fb-w') $r.Out
New-Item -ItemType Directory -Force "$pool\g5" | Out-Null
Add-Content "$pool\g1\README.md" 'local em g1'
New-Item -ItemType Junction -Path "$pool\g1\lnk" -Target $shared | Out-Null
$r = Run 'Move-WtSlot.ps1' @('-From', 'g1', '-To', 'g5')
$g = Reg
Check 'P23d' 'Move para pasta vazia existente: sem aninhar, leva alterações, registro e junction' ($r.Exit -eq 0 -and (BranchOf 'g5') -eq 'fb-w' -and -not (Test-Path "$pool\g5\g1") -and (Get-Content "$pool\g5\README.md" -Raw) -match 'local em g1' -and (Test-Path "$pool\g5\lnk\keep.txt") -and $g['g5'].branch -eq 'fb-w' -and -not $g.ContainsKey('g1')) $r.Out

# Convert -Repo em slot fora das faixas
$r = Run 'Detach-WtSlot.ps1' @('-Slot', 'g7', '-NoFetch')
$r = Run 'Convert-WtSlot.ps1' @('-Slot', 'g7', '-Repo', 'alpha', '-NoFetch')
Check 'P24' 'Convert -Repo recusado em slot fora das faixas' ($r.Exit -ne 0 -and $r.Out -match 'nenhuma faixa' -and (RootOf 'g7') -eq $beta) $r.Out

# Modo não estrito
Policy $false
$r = Run 'Attach-WtSlot.ps1' @('-Repo', 'beta', '-Branch', 'doc-y', '-NoFetch')
Check 'P25' 'modo não estrito: branch sem regra aceita' ($r.Exit -eq 0 -and @('g1', 'g2', 'g7' | Where-Object { (BranchOf $_) -eq 'doc-y' }).Count -eq 1) $r.Out

# Fecho: pastas legadas e consistência registro x git
$g = Reg
$bad = @(foreach ($n in 1..7) { $s = "g$n"; $b = BranchOf $s; if ($b -and $g[$s].branch -ne $b) { "$s registro=$($g[$s].branch) git=$b" } })
Check 'P26' 'pastas legadas preservadas; registro = git em todo slot ocupado' ((Test-Path "$pool\_legado\velho.txt") -and (Test-Path "$pool\_manifesto_legado.md") -and $bad.Count -eq 0) ($bad -join "`n")

} catch {
    # Estado inesperado no meio da bateria: registra como falha e mostra o que já rodou.
    Check 'ABORT' "bateria interrompida depois de $($results.Count) verificação(ões)" $false "$($_.Exception.Message)`n$($_.ScriptStackTrace)"
} finally { Pop-Location }
$results | Format-Table Id, Ok, Desc -AutoSize | Out-String -Width 200
$results | Where-Object Ok -ne 'OK' | ForEach-Object { "---- $($_.Id)`n$($_.Detail)" }
