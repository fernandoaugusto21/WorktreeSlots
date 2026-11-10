#Requires -Version 7
# Sandbox: coluna Usuário (conta da credencial do push) no painel. Cobre remoto https com helper de teste
# local ao repo (que conta as consultas), ssh, remoto local, pushRemote diferente do remote, helper sem
# usuário, cache por chamada, estados (ocupado, livre, vazio, bloqueado), a 2ª tabela, e userLabel custom
# e vazio. O git roda sem a config global da máquina (GIT_CONFIG_NOSYSTEM=1 e GIT_CONFIG_GLOBAL apontando
# para um arquivo vazio do sandbox). Não toca em nada fora de -Sandbox.
param([Parameter(Mandatory)][string]$Engine, [Parameter(Mandatory)][string]$Sandbox)
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.Encoding]::UTF8
if (Test-Path $Sandbox) { throw "Sandbox já existe: $Sandbox" }
New-Item -ItemType Directory -Force $Sandbox | Out-Null
$globalCfg = Join-Path $Sandbox 'gitconfig-vazio'; [IO.File]::WriteAllText($globalCfg, '')
$env:GIT_CONFIG_NOSYSTEM = '1'; $env:GIT_CONFIG_GLOBAL = $globalCfg
$env:GIT_AUTHOR_NAME = 'sbx'; $env:GIT_AUTHOR_EMAIL = 'sbx@example.invalid'
$env:GIT_COMMITTER_NAME = 'sbx'; $env:GIT_COMMITTER_EMAIL = 'sbx@example.invalid'
Remove-Item Env:WT_CONFIG -ErrorAction SilentlyContinue

# ---- montagem
$outer = Join-Path $Sandbox 'outer'; $tools = Join-Path $outer 'tools\wt'; $pool = Join-Path $outer 'wt'
$cfgDir = Join-Path $Sandbox 'cfg'; $repos = Join-Path $Sandbox 'repos'; $remotes = Join-Path $Sandbox 'remotes'
New-Item -ItemType Directory -Force $tools, $cfgDir, $repos, $remotes | Out-Null
Copy-Item "$Engine\*" $tools -Recurse
Remove-Item "$tools\profiles\*" -Force -ErrorAction SilentlyContinue
function G { param([string]$Dir) $out = & git -C $Dir @args 2>&1; if ($LASTEXITCODE) { throw "git $args em ${Dir}: $out" }; $out }
function Url([string]$Path) { $Path -replace '\\', '/' }
function New-Repo([string]$Name) {
    $dir = Join-Path $repos $Name; $bare = Join-Path $remotes "$Name.git"
    New-Item -ItemType Directory -Force $dir | Out-Null
    G $Sandbox init -q --bare $bare
    G $dir init -q -b develop; Set-Content "$dir\README.md" $Name; G $dir add .; G $dir commit -q -m init
    G $dir remote add origin (Url $bare); G $dir push -q -u origin develop
    Set-Content "$tools\profiles\$Name.ps1" -Encoding utf8NoBOM -Value "@{ Root = '$dir' }"
    return $dir
}
$web = New-Repo 'web'; $alpha = New-Repo 'alpha'; $sshr = New-Repo 'sshrepo'; $nohelp = New-Repo 'nohelper'
Set-Content "$tools\profiles\fantasma.ps1" -Encoding utf8NoBOM -Value "@{ Root = '$(Url (Join-Path $Sandbox 'nao-existe'))' }"

# web: origin https com helper que conta as consultas e devolve alice (sem tocar na config global).
$callsWeb = Join-Path $Sandbox 'calls-web.txt'; $callsNo = Join-Path $Sandbox 'calls-nohelper.txt'
G $web remote set-url origin 'https://example.invalid/alice/web.git'
G $web config credential.helper ''
G $web config --add credential.helper ("!f() { echo x >> '$(Url $callsWeb)'; echo username=alice; echo password=segredo; }; f")
# web: branch fb-push com pushRemote para um remoto local (precedência sobre o origin https).
$mirror = Join-Path $remotes 'mirror.git'; G $Sandbox init -q --bare $mirror
G $web remote add mirror (Url $mirror)
G $web config branch.fb-push.pushRemote mirror
# nohelper: https cujo helper não devolve username (só senha, que nunca pode aparecer).
G $nohelp remote set-url origin 'https://example.invalid/dave/nohelper.git'
G $nohelp config credential.helper ''
G $nohelp config --add credential.helper ("!f() { echo x >> '$(Url $callsNo)'; echo password=sem-usuario; }; f")
# sshrepo: usuário na URL ssh.
G $sshr remote set-url origin 'ssh://carol@example.invalid/sshrepo.git'

$base = [ordered]@{ poolDir = '../outer/wt'; profilesDir = '../outer/tools/wt/profiles'; slotCount = 8 }
function Write-Cfg([string]$Name, [hashtable]$Extra) {
    $c = [ordered]@{}; foreach ($k in $base.Keys) { $c[$k] = $base[$k] }; foreach ($k in $Extra.Keys) { $c[$k] = $Extra[$k] }
    $c | ConvertTo-Json | Set-Content (Join-Path $cfgDir $Name) -Encoding utf8NoBOM
}
Write-Cfg 'base.json' @{}
Write-Cfg 'custom.json' @{ userLabel = 'User' }
Write-Cfg 'empty.json' @{ userLabel = '' }

# ---- utilitários
$results = [Collections.Generic.List[object]]::new()
$outs = [Collections.Generic.List[string]]::new()
function Run([string]$Script, [string[]]$A) {
    $out = & pwsh -NoProfile -File (Join-Path $tools $Script) @A 2>&1 | ForEach-Object { "$_" }
    $text = $out -join "`n"; $outs.Add($text)
    [pscustomobject]@{ Exit = $LASTEXITCODE; Out = $text }
}
function Check([string]$Id, [string]$Desc, [bool]$Ok, [string]$Detail = '') {
    $results.Add([pscustomobject]@{ Id = $Id; Ok = $(if ($Ok) { 'OK' } else { 'FALHOU' }); Desc = $Desc; Detail = $Detail })
}
function Panel { if (Test-Path "$pool\README.md") { Get-Content "$pool\README.md" -Raw } else { '' } }
function Lines([string]$Text) { $Text -split "`r?`n" }
function SlotRow([string]$Text, [string]$Slot) { Lines $Text | Where-Object { $_ -match ('^\| \*\*' + $Slot + '\*\* \|') } | Select-Object -First 1 }
function Calls([string]$File) { if (Test-Path $File) { @(Get-Content $File).Count } else { 0 } }
function PipeCounts([string]$Text) { Lines $Text | Where-Object { $_ -match '^\|' } | ForEach-Object { ([regex]::Matches($_, '(?<!\\)\|')).Count } | Sort-Object -Unique }

# ---- estado: g1 https ocupado; g2 https livre; g3 local; g4 pushRemote local; g5 ssh; g6 sem usuário;
# g7 bloqueado (pasta com arquivo); g8 vazio; worktree de fora do pool no repo web.
$env:WT_CONFIG = Join-Path $cfgDir 'base.json'
$r1 = Run 'Attach-WtSlot.ps1' @('-Repo', 'web', '-Branch', 'fb-web-1', '-Slot', 'g1', '-Purpose', 'https', '-NoFetch')
$r2 = Run 'Attach-WtSlot.ps1' @('-Repo', 'web', '-Branch', 'fb-web-2', '-Slot', 'g2', '-NoFetch')
$r3 = Run 'Detach-WtSlot.ps1' @('-Slot', 'g2', '-NoFetch')
$r4 = Run 'Attach-WtSlot.ps1' @('-Repo', 'alpha', '-Branch', 'fb-alpha-1', '-Slot', 'g3', '-NoFetch')
$r5 = Run 'Attach-WtSlot.ps1' @('-Repo', 'web', '-Branch', 'fb-push', '-Slot', 'g4', '-NoFetch')
$r6 = Run 'Attach-WtSlot.ps1' @('-Repo', 'sshrepo', '-Branch', 'fb-ssh', '-Slot', 'g5', '-NoFetch')
$r7 = Run 'Attach-WtSlot.ps1' @('-Repo', 'nohelper', '-Branch', 'fb-nh', '-Slot', 'g6', '-NoFetch')
New-Item -ItemType Directory -Force "$pool\g7" | Out-Null; Set-Content "$pool\g7\arquivo.txt" 'não é worktree'
$outside = Join-Path $Sandbox 'outside-web'
G $web worktree add -q -b fb-extra $outside origin/develop
$setupOk = @($r1, $r2, $r3, $r4, $r5, $r6, $r7) | Where-Object Exit -ne 0
Check 'U0' 'montagem: attaches e detach sem erro' (-not $setupOk) (($setupOk | ForEach-Object Out) -join "`n")

# Duas atualizações seguidas, contando as consultas ao helper só da 2ª.
$u1 = Run 'Update-WtStatus.ps1' @('-NoFetch')
$p1 = Panel
Remove-Item $callsWeb, $callsNo -ErrorAction SilentlyContinue
$u2 = Run 'Update-WtStatus.ps1' @('-NoFetch')
$p2 = Panel

Check 'U1' 'padrão: cabeçalho "Usuário" logo depois de Repo nas duas tabelas' ($u2.Exit -eq 0 -and $p2 -match '\| Slot \| Repo \| Usuário \| Estado \|' -and $p2 -match '\| Repo \| Usuário \| Caminho \| Branch \| Alterações locais \|') $p2
Check 'U2' 'https: slot ocupado mostra a conta do helper' ((SlotRow $p2 'g1') -match '\| web \| `alice` \| 🔵 ocupado') (SlotRow $p2 'g1')
Check 'U3' 'slot livre do mesmo repo também mostra a conta' ((SlotRow $p2 'g2') -match '\| web \| `alice` \| 🟢 livre') (SlotRow $p2 'g2')
Check 'U4' 'remoto local mostra _(local)_' ((SlotRow $p2 'g3') -match '\| alpha \| _\(local\)_ \| 🔵 ocupado') (SlotRow $p2 'g3')
Check 'U5' 'pushRemote da branch vence o origin https (remoto local)' ((SlotRow $p2 'g4') -match '\| web \| _\(local\)_ \| 🔵 ocupado') (SlotRow $p2 'g4')
Check 'U6' 'ssh: usuário da URL' ((SlotRow $p2 'g5') -match '\| sshrepo \| `carol` \| 🔵 ocupado') (SlotRow $p2 'g5')
Check 'U7' 'helper sem username: _(desconhecido)_' ((SlotRow $p2 'g6') -match '\| nohelper \| _\(desconhecido\)_ \| 🔵 ocupado') (SlotRow $p2 'g6')
Check 'U8' 'slot vazio e bloqueado ficam com a coluna em branco' ((SlotRow $p2 'g8') -match '\*\*g8\*\* \|  \|  \| ⚪ vazio' -and (SlotRow $p2 'g7') -match '\|  \| ❌ bloqueado') ((SlotRow $p2 'g7') + "`n" + (SlotRow $p2 'g8'))
Check 'U9' 'Outras worktrees: worktree de fora do pool mostra a conta' ($p2 -match '(?m)^\| web \| `alice` \| `[^`]*outside-web` \| `fb-extra`') ''
Check 'U10' 'Outras worktrees: checkout principal também mostra a conta' ($p2 -match '(?m)^\| web \| `alice` \| `[^`]*repos[\\/]web` _\(checkout principal\)_') ''
Check 'U11' 'Outras worktrees: repo com checkout ausente deixa a coluna em branco' ($p2 -match '(?m)^\| fantasma \|  \| `[^`]*` \| _\(checkout principal não encontrado\)_ \|  \|') ''
Check 'U12' 'cache: uma consulta ao helper por (repo, URL) por painel' ((Calls $callsWeb) -eq 1 -and (Calls $callsNo) -eq 1) "web=$(Calls $callsWeb) nohelper=$(Calls $callsNo)"
$semData = { param($t) (Lines $t | Where-Object { $_ -notmatch '^> Gerado em' }) -join "`n" }
Check 'U13' 'duas atualizações seguidas dão o mesmo painel' ((& $semData $p1) -eq (& $semData $p2)) ''
$allText = (@($p2) + $outs) -join "`n"
Check 'U14' 'senha e conta do helper sem usuário nunca aparecem (painel nem saídas)' ($allText -notmatch 'segredo' -and $allText -notmatch 'sem-usuario') ''

# userLabel custom e vazio
$env:WT_CONFIG = Join-Path $cfgDir 'custom.json'
$uc = Run 'Update-WtStatus.ps1' @('-NoFetch'); $pc = Panel
Check 'U15' 'userLabel custom: cabeçalho "User" nas duas tabelas, sem "Usuário"' ($uc.Exit -eq 0 -and $pc -match '\| Slot \| Repo \| User \| Estado \|' -and $pc -match '\| Repo \| User \| Caminho' -and $pc -notmatch 'Usuário' -and (SlotRow $pc 'g1') -match '\| web \| `alice` \|') $pc

$env:WT_CONFIG = Join-Path $cfgDir 'empty.json'
$ue = Run 'Update-WtStatus.ps1' @('-NoFetch'); $pe = Panel
Check 'U16' 'userLabel "": coluna escondida nas duas tabelas' ($ue.Exit -eq 0 -and $pe -match '\| Slot \| Repo \| Estado \|' -and $pe -notmatch 'Usuário' -and $pe -notmatch '\| User \|' -and $pe -notmatch 'alice' -and (SlotRow $pe 'g1') -match '\| web \| 🔵 ocupado' -and $pe -match '(?m)^\| Repo \| Caminho \| Branch \| Alterações locais \|') $pe

$env:WT_CONFIG = Join-Path $cfgDir 'base.json'
Check 'U17' 'colunas consistentes: cada tabela tem o número de | do próprio cabeçalho (padrão, custom e vazio)' ((PipeCounts $p2).Count -eq 2 -and (PipeCounts $pc).Count -eq 2 -and (PipeCounts $pe).Count -eq 2) ("padrão=" + ((PipeCounts $p2) -join ',') + " custom=" + ((PipeCounts $pc) -join ',') + " vazio=" + ((PipeCounts $pe) -join ','))

$results | Format-Table Id, Ok, Desc -AutoSize | Out-String -Width 200
$results | Where-Object Ok -ne 'OK' | ForEach-Object { "---- $($_.Id)`n$($_.Detail)" }
