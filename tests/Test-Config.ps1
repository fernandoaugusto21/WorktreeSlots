#Requires -Version 7
# Sandbox: configuração por wt.config.json (WT_CONFIG e arquivo ao lado dos scripts), rótulo da
# coluna do id, faixas de slot e modo estrito. Não toca em nada fora de -Sandbox.
param([Parameter(Mandatory)][string]$Engine, [Parameter(Mandatory)][string]$Sandbox)
$ErrorActionPreference = 'Stop'
$env:GIT_AUTHOR_NAME = 'sbx'; $env:GIT_AUTHOR_EMAIL = 'sbx@example.invalid'
$env:GIT_COMMITTER_NAME = 'sbx'; $env:GIT_COMMITTER_EMAIL = 'sbx@example.invalid'
Remove-Item Env:WT_CONFIG -ErrorAction SilentlyContinue

if (Test-Path $Sandbox) { throw "Sandbox já existe: $Sandbox" }
$eng = Join-Path $Sandbox 'engine'; $cfgDir = Join-Path $Sandbox 'cfg'; $demo = Join-Path $Sandbox 'repos\demo'
New-Item -ItemType Directory -Force $eng, "$cfgDir\profiles", $demo | Out-Null
Copy-Item "$Engine\*" $eng -Recurse
Remove-Item "$eng\profiles" -Recurse
function G { param([string]$Dir) $out = & git -C $Dir @args 2>&1; if ($LASTEXITCODE) { throw "git $args em ${Dir}: $out" }; $out }
G $Sandbox init -q --bare "$Sandbox\demo.git"
G $demo init -q -b develop; Set-Content "$demo\README.md" demo; G $demo add .; G $demo commit -q -m init
G $demo remote add origin ("$Sandbox\demo.git" -replace '\\', '/'); G $demo push -q -u origin develop

Set-Content "$cfgDir\profiles\demo.ps1" -Encoding utf8NoBOM -Value @"
@{ Root = '$demo'; TicketFromBranch = { param([string]`$Branch) if (`$Branch -match 'id-(\d+)') { "ID-`$(`$Matches[1])" } else { '' } } }
"@
$cfg = [ordered]@{
    poolDir = '../pool'; profilesDir = 'profiles'; ticketLabel = 'Pesquisa'; slotCount = 3; slotPolicyStrict = $true
    slotPolicy = @(@{ label = 'hotfix'; pattern = '^hf-'; slots = @('g1') }, @{ label = 'feature'; pattern = '^fb-'; slots = @('g2', 'g3') })
}
$cfg | ConvertTo-Json -Depth 5 | Set-Content "$cfgDir\wt.config.json" -Encoding utf8NoBOM
$pool = Join-Path $Sandbox 'pool'

$results = [Collections.Generic.List[object]]::new()
function Run([string]$Script, [string[]]$A) {
    $out = & pwsh -NoProfile -File (Join-Path $eng $Script) @A 2>&1 | ForEach-Object { "$_" }
    [pscustomobject]@{ Exit = $LASTEXITCODE; Out = ($out -join "`n") }
}
function Check([string]$Id, [string]$Desc, [bool]$Ok, [string]$Detail = '') {
    $results.Add([pscustomobject]@{ Id = $Id; Ok = $(if ($Ok) { 'OK' } else { 'FALHOU' }); Desc = $Desc; Detail = $Detail })
}

$env:WT_CONFIG = "$cfgDir\wt.config.json"
$r = Run 'Attach-WtSlot.ps1' @('-Repo', 'demo', '-Branch', 'fb-id-7', '-Purpose', 'com espaço e acento', '-NoFetch')
$panel = if (Test-Path "$pool\README.md") { Get-Content "$pool\README.md" -Raw } else { '' }
Check 'C1' 'WT_CONFIG: pool, perfis e faixa (fb -> g2)' ($r.Exit -eq 0 -and (Test-Path "$pool\g2\.git") -and -not (Test-Path "$pool\g1")) $r.Out
Check 'C2' 'rótulo da coluna e id extraído no painel' ($panel -match '\| Pesquisa \|' -and $panel -match 'ID-7' -and $panel -match 'com espaço e acento') $panel
Check 'C7' 'userLabel padrão: "Usuário" logo depois de Repo nas duas tabelas' ($panel -match '\| Repo \| Usuário \| Estado' -and $panel -match '\| Repo \| Usuário \| Caminho') $panel
$r = Run 'Attach-WtSlot.ps1' @('-Repo', 'demo', '-Branch', 'hf-x', '-Slot', 'g3', '-NoFetch')
Check 'C3' 'hf fora da faixa recusado' ($r.Exit -ne 0 -and -not (Test-Path "$pool\g3\.git")) $r.Out
$r = Run 'Attach-WtSlot.ps1' @('-Repo', 'demo', '-Branch', 'doc-x', '-NoFetch')
Check 'C4' 'branch sem regra recusada (estrito)' ($r.Exit -ne 0) $r.Out

$bad = [ordered]@{}; foreach ($k in $cfg.Keys) { $bad[$k] = $cfg[$k] }; $bad['poolDirr'] = 'x'
$bad | ConvertTo-Json -Depth 5 | Set-Content "$cfgDir\bad.json" -Encoding utf8NoBOM
$env:WT_CONFIG = "$cfgDir\bad.json"
$r = Run 'Update-WtStatus.ps1' @('-NoFetch')
Check 'C5' 'chave desconhecida no JSON recusada' ($r.Exit -ne 0 -and $r.Out -match 'poolDirr') $r.Out

# userLabel custom e vazio (o padrão é C7)
$cfg['userLabel'] = 'User'; $cfg | ConvertTo-Json -Depth 5 | Set-Content "$cfgDir\user-custom.json" -Encoding utf8NoBOM
$cfg['userLabel'] = ''; $cfg | ConvertTo-Json -Depth 5 | Set-Content "$cfgDir\user-empty.json" -Encoding utf8NoBOM
$env:WT_CONFIG = "$cfgDir\user-custom.json"
$r = Run 'Update-WtStatus.ps1' @('-NoFetch'); $pc = Get-Content "$pool\README.md" -Raw
Check 'C8' 'userLabel custom: cabeçalho "User" nas duas tabelas' ($r.Exit -eq 0 -and $pc -match '\| Repo \| User \| Estado' -and $pc -match '\| Repo \| User \| Caminho' -and $pc -notmatch 'Usuário') $r.Out
$env:WT_CONFIG = "$cfgDir\user-empty.json"
$r = Run 'Update-WtStatus.ps1' @('-NoFetch'); $pe = Get-Content "$pool\README.md" -Raw
Check 'C9' 'userLabel "": coluna escondida nas duas tabelas' ($r.Exit -eq 0 -and $pe -match '\| Repo \| Estado \|' -and $pe -notmatch 'Usuário' -and $pe -notmatch '\| User \|') $r.Out

Remove-Item Env:WT_CONFIG
$side = [ordered]@{ poolDir = '../pool2'; profilesDir = '../cfg/profiles' }
$side | ConvertTo-Json | Set-Content "$eng\wt.config.json" -Encoding utf8NoBOM
$r = Run 'Attach-WtSlot.ps1' @('-Repo', 'demo', '-Branch', 'qualquer', '-NoFetch')
Check 'C6' 'wt.config.json ao lado dos scripts (sem WT_CONFIG)' ($r.Exit -eq 0 -and (Test-Path "$Sandbox\pool2\README.md")) $r.Out

$results | Format-Table Id, Ok, Desc -AutoSize | Out-String -Width 200
$results | Where-Object Ok -ne 'OK' | ForEach-Object { "---- $($_.Id)`n$($_.Detail)" }
