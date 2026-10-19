#Requires -Version 7
# Sandbox: detach contra repositório, remoto e submódulos reais — submódulo órfão/defasado (T1–T5)
# e ignorados que viram não rastreados (T6–T7).
param([Parameter(Mandatory)][string]$Engine, [Parameter(Mandatory)][string]$Sandbox)
$ErrorActionPreference = 'Stop'
# Submódulos com URL local exigem protocol.file.allow (git >= 2.38); vale só para este processo.
$env:GIT_CONFIG_COUNT = '1'; $env:GIT_CONFIG_KEY_0 = 'protocol.file.allow'; $env:GIT_CONFIG_VALUE_0 = 'always'
$env:GIT_AUTHOR_NAME = 'sbx'; $env:GIT_AUTHOR_EMAIL = 'sbx@example.invalid'
$env:GIT_COMMITTER_NAME = 'sbx'; $env:GIT_COMMITTER_EMAIL = 'sbx@example.invalid'

if (Test-Path $Sandbox) { throw "Sandbox já existe: $Sandbox" }
$tools = Join-Path $Sandbox 'store\tools\wt'
New-Item -ItemType Directory -Force $tools | Out-Null
Copy-Item "$Engine\*" $tools -Recurse
$pool = Join-Path $Sandbox 'store\wt'
$remotes = Join-Path $Sandbox 'remotes'; $demo = Join-Path $Sandbox 'repos\demo'
New-Item -ItemType Directory -Force $remotes, $demo | Out-Null
function G { param([string]$Dir) $out = & git -C $Dir @args 2>&1; if ($LASTEXITCODE) { throw "git $args em ${Dir}: $out" }; $out }

# Remoto do submódulo com dois commits (A, B).
$subW = Join-Path $Sandbox 'work-sub'; New-Item -ItemType Directory $subW | Out-Null
G $subW init -q -b main; Set-Content "$subW\a.txt" A; G $subW add .; G $subW commit -q -m A
$shaA = (G $subW rev-parse HEAD); Set-Content "$subW\a.txt" B; G $subW commit -q -am B; $shaB = (G $subW rev-parse HEAD)
G $Sandbox clone -q --bare $subW "$remotes\sub.git"
$subUrl = ("$remotes\sub.git" -replace '\\', '/')

# Repo demo: develop com submódulo libs/stale fixado em A.
G $Sandbox init -q --bare "$remotes\demo.git"
G $demo init -q -b develop; Set-Content "$demo\README.md" demo; Set-Content "$demo\.gitignore" '*.log'
G $demo add .; G $demo commit -q -m init
G $demo submodule -q add $subUrl libs/stale; G $demo -C libs/stale checkout -q $shaA
G $demo add libs/stale; G $demo commit -q -m "stale em A"
G $demo remote add origin ("$remotes\demo.git" -replace '\\', '/'); G $demo push -q -u origin develop

Set-Content "$tools\profiles\demo.ps1" "@{ Root = '$demo' }" -Encoding utf8NoBOM
Remove-Item "$tools\profiles\exemplo.ps1"

$results = [Collections.Generic.List[object]]::new()
function Run([string]$Script, [string[]]$A) {
    $out = & pwsh -NoProfile -File (Join-Path $tools $Script) @A 2>&1 | ForEach-Object { "$_" }
    [pscustomobject]@{ Exit = $LASTEXITCODE; Out = ($out -join "`n") }
}
function Check([string]$Id, [string]$Desc, [bool]$Ok, [string]$Detail = '') {
    $results.Add([pscustomobject]@{ Id = $Id; Ok = $(if ($Ok) { 'OK' } else { 'FALHOU' }); Desc = $Desc; Detail = $Detail })
}
$g1 = Join-Path $pool 'g1'

# T1 regressão: branch sem submódulo novo.
$r = Run 'Attach-WtSlot.ps1' @('-Repo', 'demo', '-Branch', 'fb-plain', '-Purpose', 'plain', '-NoFetch')
Set-Content "$g1\x.txt" x; G $g1 add .; G $g1 commit -q -m x; G $g1 push -q -u origin fb-plain
$r = Run 'Detach-WtSlot.ps1' @('-Slot', 'g1', '-NoFetch')
Check 'T1' 'detach sem submódulo novo (regressão)' ($r.Exit -eq 0 -and -not (G $g1 status --porcelain --ignored)) $r.Out

# T2 órfão: branch adiciona e inicializa submódulo novo.
$r = Run 'Attach-WtSlot.ps1' @('-Repo', 'demo', '-Branch', 'fb-orfao', '-Purpose', 'orfao', '-NoFetch')
G $g1 submodule -q add $subUrl libs/novo; G $g1 commit -q -m "add novo"; G $g1 push -q -u origin fb-orfao
$r = Run 'Detach-WtSlot.ps1' @('-Slot', 'g1', '-NoFetch')
$moved = @(Get-ChildItem (Join-Path $pool '_backup') -Directory -Filter 'g1_*' | Where-Object { Test-Path "$($_.FullName)\libs\novo\a.txt" })
Check 'T2' 'órfão movido para _backup, slot limpo' ($r.Exit -eq 0 -and -not (G $g1 status --porcelain --ignored) -and $moved.Count -eq 1) $r.Out

# T3 recusa: submódulo com arquivo não rastreado.
$r = Run 'Attach-WtSlot.ps1' @('-Repo', 'demo', '-Branch', 'fb-orfao', '-Purpose', 'orfao', '-NoFetch')
G $g1 submodule -q update --init libs/novo
Set-Content "$g1\libs\novo\sujo.txt" s
$r = Run 'Detach-WtSlot.ps1' @('-Slot', 'g1', '-NoFetch')
Check 'T3' 'recusa com submódulo sujo, sem efeito' ($r.Exit -ne 0 -and (G $g1 branch --show-current) -eq 'fb-orfao' -and (Test-Path "$g1\libs\novo\.git")) $r.Out
Remove-Item "$g1\libs\novo\sujo.txt"

# T4 recusa só da checagem nova: HEAD do submódulo não publicado, invisível ao pai (ignore=all).
G $g1 config submodule.libs/novo.ignore all
Set-Content "$g1\libs\novo\c.txt" c; G "$g1\libs\novo" add .; G "$g1\libs\novo" commit -q -m local
$pai = G $g1 status --porcelain
$r = Run 'Detach-WtSlot.ps1' @('-Slot', 'g1', '-NoFetch')
Check 'T4' 'recusa HEAD de submódulo não publicado (pai não vê)' ($r.Exit -ne 0 -and -not $pai -and $r.Out -match 'não está em nenhuma branch remota' -and (G $g1 branch --show-current) -eq 'fb-orfao') $r.Out
G "$g1\libs\novo" reset -q --hard HEAD~1; G $g1 config --unset submodule.libs/novo.ignore
$r = Run 'Detach-WtSlot.ps1' @('-Slot', 'g1', '-NoFetch')
Check 'T4b' 'depois de corrigir, detach passa' ($r.Exit -eq 0 -and -not (G $g1 status --porcelain --ignored)) $r.Out

# T5 defasado: branch move libs/stale de A para B.
$r = Run 'Attach-WtSlot.ps1' @('-Repo', 'demo', '-Branch', 'fb-stale', '-Purpose', 'stale', '-NoFetch')
G $g1 submodule -q update --init libs/stale; G "$g1\libs\stale" checkout -q $shaB
G $g1 add libs/stale; G $g1 commit -q -m "stale em B"; G $g1 push -q -u origin fb-stale
$r = Run 'Detach-WtSlot.ps1' @('-Slot', 'g1', '-NoFetch')
$head = G "$g1\libs\stale" rev-parse HEAD
Check 'T5' 'defasado alinhado ao commit da base' ($r.Exit -eq 0 -and $head -eq $shaA -and -not (G $g1 status --porcelain --ignored)) $r.Out

# T6/T7 ignorados: a branch cria proj/ com .gitignore próprio (saida/); a regra '*.log' existe na base.
$r = Run 'Attach-WtSlot.ps1' @('-Repo', 'demo', '-Branch', 'fb-saida', '-Purpose', 'saida', '-NoFetch')
New-Item -ItemType Directory -Force "$g1\proj\saida" | Out-Null
Set-Content "$g1\proj\.gitignore" 'saida/'; Set-Content "$g1\proj\main.txt" m
G $g1 add proj; G $g1 commit -q -m proj; G $g1 push -q -u origin fb-saida
Set-Content "$g1\proj\saida\mapa.html" '<p>mapa</p>'; Set-Content "$g1\proj\saida\dados.json" '{}'
Set-Content "$g1\build.log" log
$r = Run 'Detach-WtSlot.ps1' @('-Slot', 'g1', '-NoFetch')
$bk = @(Get-ChildItem (Join-Path $pool '_backup') -Directory -Filter 'g1_*' | Where-Object { Test-Path "$($_.FullName)\proj\saida\mapa.html" })
Check 'T6' 'saída ignorada só pela branch movida para _backup, slot limpo' ($r.Exit -eq 0 -and -not (G $g1 status --porcelain) -and $bk.Count -eq 1 -and (Test-Path "$($bk[0].FullName)\proj\saida\dados.json") -and -not (Test-Path "$g1\proj")) $r.Out
$ign = G $g1 status --porcelain --ignored
Check 'T7' 'ignorado também na base fica no slot, ignorado' ((Test-Path "$g1\build.log") -and ($ign -match '!! build\.log')) ($ign -join "`n")

$results | Format-Table Id, Ok, Desc -AutoSize | Out-String -Width 200
$results | Where-Object Ok -ne 'OK' | ForEach-Object { "---- $($_.Id)`n$($_.Detail)" }
