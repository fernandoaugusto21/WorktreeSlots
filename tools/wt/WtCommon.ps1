#Requires -Version 7
# Núcleo do pool de Worktree Slots compartilhado entre repositórios (v3).
# Dot-source: . "$PSScriptRoot/WtCommon.ps1". Configuração por repo: profiles/<repo>.ps1.

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.Encoding]::UTF8

# ===================== CONFIGURAÇÃO GLOBAL DO POOL (ajuste aqui) =====================
# Pasta do pool: slots, painel README.md, registro .slots.json, .lock e _backup/.
$script:WtDir           = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../wt'))
$script:WtSlotPrefix    = 'g'                                    # slots = g1, g2, ...
$script:WtSlotCount     = 7
$script:WtProfilesDir   = Join-Path $PSScriptRoot 'profiles'     # um <repo>.ps1 por repositório
$script:WtHideWorktrees = '[\\/]\.claude[\\/]worktrees[\\/]'     # worktrees só contadas (não listadas) no painel; '' = listar todas
$script:WtLockTimeoutSec = 60                                    # espera máxima pelo lock do pool
$script:WtScriptsRel    = $PSScriptRoot                          # usado só nos textos do painel
# Política de faixas: que slots cada tipo de branch pode ocupar. @() = sem política (qualquer slot).
# A 1ª regra cujo Pattern casa com o nome da branch decide. Exemplo:
#   @( @{ Label = 'hotfix';      Pattern = '^(ht|hf)-';  Slots = @('g1', 'g2', 'g3') }
#      @{ Label = 'feature/doc'; Pattern = '^(fb|doc)-'; Slots = @('g4', 'g5', 'g6', 'g7') } )
$script:WtSlotPolicy    = @()
$script:WtSlotPolicyStrict = $true                               # branch sem regra: $true = recusa; $false = qualquer slot
$script:WtTicketLabel   = 'Ticket'                               # cabeçalho da coluna do id extraído da branch (TicketFromBranch)
$script:WtUserLabel     = 'Usuário'                              # cabeçalho da coluna da conta da credencial do push ('' = esconder)
# ====================================================================================

# Configuração por instalação: wt.config.json sobrepõe os valores acima, sem editar este arquivo.
# Procura em $env:WT_CONFIG (caminho do arquivo; usado por atalhos que chamam o motor de outra pasta)
# e depois ao lado dos scripts. Caminhos relativos valem a partir da pasta do JSON.
$script:WtConfigKeys = @('engineDir', 'poolDir', 'profilesDir', 'slotPrefix', 'slotCount', 'hideWorktrees',
    'lockTimeoutSec', 'scriptsLabel', 'ticketLabel', 'userLabel', 'slotPolicy', 'slotPolicyStrict')
$script:WtConfigPath = ''
function Import-WtConfig {
    $path = if ($env:WT_CONFIG) { $env:WT_CONFIG } else { Join-Path $PSScriptRoot 'wt.config.json' }
    if (-not (Test-Path -LiteralPath $path)) {
        if ($env:WT_CONFIG) { throw "WT_CONFIG aponta para um arquivo que não existe: $path" }
        return
    }
    $path = [IO.Path]::GetFullPath($path)
    $cfg = Get-Content -LiteralPath $path -Raw -Encoding utf8 | ConvertFrom-Json -AsHashtable
    $bad = @($cfg.Keys | Where-Object { $_ -cnotin $script:WtConfigKeys })
    if ($bad) { throw "$path`: chave(s) desconhecida(s): $($bad -join ', '). Válidas: $($script:WtConfigKeys -join ', ')." }
    $dir = Split-Path $path -Parent
    $full = { param([string]$p) [IO.Path]::GetFullPath([IO.Path]::Combine($dir, $p)) }
    # engineDir é lido só pelos atalhos (onde está o motor); aqui é aceito e ignorado.
    if ($cfg.ContainsKey('poolDir'))          { $script:WtDir = & $full $cfg.poolDir }
    if ($cfg.ContainsKey('profilesDir'))      { $script:WtProfilesDir = & $full $cfg.profilesDir }
    if ($cfg.ContainsKey('slotPrefix'))       { $script:WtSlotPrefix = [string]$cfg.slotPrefix }
    if ($cfg.ContainsKey('slotCount'))        { $script:WtSlotCount = [int]$cfg.slotCount }
    if ($cfg.ContainsKey('hideWorktrees'))    { $script:WtHideWorktrees = [string]$cfg.hideWorktrees }
    if ($cfg.ContainsKey('lockTimeoutSec'))   { $script:WtLockTimeoutSec = [int]$cfg.lockTimeoutSec }
    if ($cfg.ContainsKey('scriptsLabel'))     { $script:WtScriptsRel = [string]$cfg.scriptsLabel }
    if ($cfg.ContainsKey('ticketLabel'))      { $script:WtTicketLabel = [string]$cfg.ticketLabel }
    if ($cfg.ContainsKey('userLabel'))        { $script:WtUserLabel = [string]$cfg.userLabel }
    if ($cfg.ContainsKey('slotPolicyStrict')) { $script:WtSlotPolicyStrict = [bool]$cfg.slotPolicyStrict }
    if ($cfg.ContainsKey('slotPolicy')) {
        $script:WtSlotPolicy = @(foreach ($r in @($cfg.slotPolicy)) {
            foreach ($k in 'label', 'pattern', 'slots') { if (-not $r.ContainsKey($k)) { throw "$path`: regra de slotPolicy sem '$k'." } }
            @{ Label = [string]$r.label; Pattern = [string]$r.pattern; Slots = @($r.slots | ForEach-Object { [string]$_ }) }
        })
    }
    $script:WtConfigPath = $path
}
Import-WtConfig

$script:WtSlotNames = 1..$script:WtSlotCount | ForEach-Object { "$($script:WtSlotPrefix)$_" }
$script:WtPanelMarker = '<!-- wt-panel: gerado por Update-WtStatus.ps1 -->'

function Assert-WtSlotName([string]$Slot) {
    if ($Slot -and $Slot -notin $script:WtSlotNames) {
        throw "Slot '$Slot' inválido. Válidos: $($script:WtSlotNames -join ', ')."
    }
}

function Invoke-Git {
    # Roda git em $Dir; lança exceção se falhar (a menos que -AllowFail).
    param(
        [Parameter(Mandatory)][string]$Dir,
        [Parameter(Mandatory)][string[]]$GitArgs,
        [switch]$AllowFail
    )
    $out = & git -c core.quotepath=false -C $Dir @GitArgs 2>&1
    $code = $LASTEXITCODE
    if ($code -ne 0 -and -not $AllowFail) {
        throw "git $($GitArgs -join ' ') falhou em ${Dir}:`n$($out -join "`n")"
    }
    [pscustomobject]@{ Ok = ($code -eq 0); Lines = @($out | ForEach-Object { "$_" }) }
}

function ConvertTo-WtPathKey([string]$Path) {
    return ([IO.Path]::GetFullPath($Path) -replace '\\', '/').TrimEnd('/').ToLowerInvariant()
}

# ---------------------------------------------------------------- perfis

function Get-WtProfiles {
    # Todos os perfis: hashtable nome -> perfil. Cada profiles/<nome>.ps1 devolve um hashtable.
    $all = [ordered]@{}
    if (-not (Test-Path $script:WtProfilesDir)) { return $all }
    foreach ($f in Get-ChildItem $script:WtProfilesDir -Filter '*.ps1' | Sort-Object Name) {
        $p = & $f.FullName
        if ($p -isnot [hashtable] -or -not $p['Root']) { throw "Perfil $($f.Name) inválido: precisa devolver um hashtable com Root." }
        $defaults = @{
            Remote = 'origin'; Base = 'develop'; BranchPattern = '.'; TicketFromBranch = { param($Branch) '' }
            ExtraColumns = @(); CleanKeep = @(); Harvest = @{ Enabled = $false }
            PostAttachHook = $null; PreDetachHook = $null
        }
        foreach ($k in $defaults.Keys) { if (-not $p.ContainsKey($k)) { $p[$k] = $defaults[$k] } }
        $p['Name'] = $f.BaseName
        $p['Root'] = [IO.Path]::GetFullPath($p['Root'])
        $all[$f.BaseName] = $p
    }
    return $all
}

function Get-WtRepoRootOf([string]$Dir) {
    # Raiz do checkout principal do repo que contém $Dir ('' se não for repo).
    $r = Invoke-Git -Dir $Dir -GitArgs @('rev-parse', '--path-format=absolute', '--git-common-dir') -AllowFail
    if (-not $r.Ok) { return '' }
    return (Split-Path ([IO.Path]::GetFullPath($r.Lines[0])) -Parent)
}

function Find-WtProfileByRoot($Profiles, [string]$Root) {
    if (-not $Root) { return $null }
    $key = ConvertTo-WtPathKey $Root
    foreach ($p in $Profiles.Values) { if ((ConvertTo-WtPathKey $p.Root) -eq $key) { return $p } }
    return $null
}

function Resolve-WtProfile($Profiles, [string]$Repo) {
    # -Repo explícito, ou o repo do diretório corrente (checkout principal ou slot dele).
    if ($Repo) {
        if (-not $Profiles.Contains($Repo)) { throw "Perfil '$Repo' não existe em $($script:WtProfilesDir). Disponíveis: $($Profiles.Keys -join ', ')." }
        return $Profiles[$Repo]
    }
    $p = Find-WtProfileByRoot $Profiles (Get-WtRepoRootOf (Get-Location).Path)
    if (-not $p) { throw "Não deu para inferir o repo pelo diretório corrente. Informe -Repo ($($Profiles.Keys -join ', '))." }
    return $p
}

function Get-WtSlotRule([string]$Branch) {
    # Regra da política para a branch: $null = sem restrição (política vazia, ou branch sem regra e não estrito).
    if (-not @($script:WtSlotPolicy).Count) { return $null }
    foreach ($r in $script:WtSlotPolicy) { if ($Branch -match $r.Pattern) { return $r } }
    if ($script:WtSlotPolicyStrict) {
        throw "Branch '$Branch' não casa com nenhuma faixa da política: $(($script:WtSlotPolicy | ForEach-Object { "$($_.Label) $($_.Pattern) -> $($_.Slots -join ',')" }) -join ' | ')."
    }
    return $null
}

function Get-WtAllowedSlots([string]$Branch) {
    # Slots que a branch pode ocupar (todos, sem política/regra).
    $r = Get-WtSlotRule $Branch
    if ($r) { return @($r.Slots) }
    return $script:WtSlotNames
}

function Get-WtSlotLabel([string]$Slot) {
    # Faixa(s) da política a que o slot pertence ('' sem política; '(fora das faixas)' se nenhuma).
    if (-not @($script:WtSlotPolicy).Count) { return '' }
    $l = @($script:WtSlotPolicy | Where-Object { $Slot -in $_.Slots } | ForEach-Object Label)
    if ($l) { return ($l -join '/') } else { return '(fora das faixas)' }
}

function Get-WtBaseRef($Prof) { "$($Prof.Remote)/$($Prof.Base)" }

function Get-WtTicketId($Prof, [string]$Branch) {
    if (-not $Branch) { return '' }
    return "$(& $Prof.TicketFromBranch $Branch)"
}

# ---------------------------------------------------------------- lock e registro

function Invoke-WtLocked([scriptblock]$Body) {
    # Exclusão mútua entre sessões/agentes: lock de arquivo em <pool>/.lock.
    New-Item -ItemType Directory -Force $script:WtDir | Out-Null
    $path = Join-Path $script:WtDir '.lock'
    $deadline = (Get-Date).AddSeconds($script:WtLockTimeoutSec)
    $lock = $null
    while (-not $lock) {
        try { $lock = [IO.File]::Open($path, 'OpenOrCreate', 'ReadWrite', 'None') }
        catch [IO.IOException] {
            if ((Get-Date) -gt $deadline) { throw "Pool ocupado por outra operação há mais de $($script:WtLockTimeoutSec)s ($path). Tente de novo." }
            Start-Sleep -Milliseconds 250
        }
    }
    try { & $Body } finally { $lock.Dispose() }
}

function Get-WtMetaPath { Join-Path $script:WtDir '.slots.json' }

function Read-WtMeta {
    $p = Get-WtMetaPath
    $meta = @{}
    if (Test-Path $p) {
        $obj = Get-Content $p -Raw | ConvertFrom-Json -AsHashtable
        if ($obj) { $meta = $obj }
    }
    return $meta
}

function Save-WtMeta([hashtable]$Meta) {
    New-Item -ItemType Directory -Force $script:WtDir | Out-Null
    $Meta | ConvertTo-Json -Depth 5 | Set-Content -Path (Get-WtMetaPath) -Encoding utf8NoBOM
}

function Assert-WtPanelOwnership {
    # O painel sobrescreve <pool>/README.md: recusa se houver ali um README que não foi gerado por ele.
    $readme = Join-Path $script:WtDir 'README.md'
    if ((Test-Path $readme) -and -not (Select-String -LiteralPath $readme -SimpleMatch $script:WtPanelMarker -Quiet)) {
        throw "$readme não foi gerado pelo painel (manifesto manual?). Renomeie-o (ex.: _manifesto_legado.md) antes de usar o pool — o painel o sobrescreveria."
    }
}

# ---------------------------------------------------------------- estado

function Get-WtTreeState([string]$Path) {
    # Contagem de alterações locais: rastreados modificados, não rastreados, ignorados.
    $lines = (Invoke-Git -Dir $Path -GitArgs @('status', '--porcelain', '--ignored')).Lines
    [pscustomobject]@{
        Modified  = @($lines | Where-Object { $_ -notmatch '^(\?\?|!!)' }).Count
        Untracked = @($lines | Where-Object { $_ -like '`?`? *' }).Count
        Ignored   = @($lines | Where-Object { $_ -like '!! *' }).Count
        Dirty     = @($lines | Where-Object { $_ -notlike '!! *' }).Count -gt 0
        Porcelain = @($lines | Where-Object { $_ -notlike '!! *' })
    }
}

function Get-WtGitlinks([string]$Dir, [string]$Rev) {
    # Submódulos (gitlinks, modo 160000) registrados em $Rev -> @{ caminho = sha }.
    $map = @{}
    foreach ($l in (Invoke-Git -Dir $Dir -GitArgs @('ls-tree', '-r', '--full-tree', $Rev)).Lines) {
        if ($l -match '^160000 commit ([0-9a-f]+)\t(.+)$') { $map[$Matches[2]] = $Matches[1] }
    }
    return $map
}

function Get-WtSubmodulePlan([string]$Path, [string]$TargetRef) {
    # Submódulos inicializados no slot que um `git switch` (sem --recurse-submodules) para $TargetRef
    # deixaria para trás. Orphan: o caminho não é submódulo no destino, e a working tree ficaria
    # como pasta não rastreada. Stale: submódulo nos dois lados, mas em commits diferentes, e o slot
    # ficaria "modificado".
    $here = Get-WtGitlinks $Path 'HEAD'
    $there = Get-WtGitlinks $Path $TargetRef
    foreach ($rel in $here.Keys) {
        $full = Join-Path $Path $rel
        if (-not (Test-Path -LiteralPath (Join-Path $full '.git'))) { continue }   # não inicializado: o switch resolve sozinho
        if (-not $there.ContainsKey($rel)) { [pscustomobject]@{ Rel = $rel; Full = $full; Kind = 'orphan' } }
        elseif ($there[$rel] -ne $here[$rel]) { [pscustomobject]@{ Rel = $rel; Full = $full; Kind = 'stale' } }
    }
}

function Assert-WtSubmoduleSafe($Item) {
    # Só mexe num submódulo que não tem nada a perder: sem alterações (fora ignorados) e com HEAD publicado.
    $st = @((Invoke-Git -Dir $Item.Full -GitArgs @('status', '--porcelain')).Lines | Where-Object { $_ })
    if ($st.Count -gt 0) {
        throw "Submódulo $($Item.Rel) tem alterações locais — commit (no submódulo) ou descarte conscientemente antes do detach:`n$($st -join "`n")"
    }
    $pub = @((Invoke-Git -Dir $Item.Full -GitArgs @('for-each-ref', '--contains', 'HEAD', '--format=%(refname)', 'refs/remotes')).Lines | Where-Object { $_ })
    if ($pub.Count -eq 0) {
        throw "Submódulo $($Item.Rel): o commit em HEAD não está em nenhuma branch remota — publique (ou registre) antes do detach."
    }
}

function Move-WtOrphanSubmodule([string]$BackupDir, $Item) {
    # Tira a working tree órfã do slot sem apagar nada: vai para <BackupDir>/<caminho>, com nota de restauração.
    # O git dir do submódulo fica em <repo>/.git/worktrees/<slot>/modules e não é tocado.
    $dest = Join-Path $BackupDir $Item.Rel
    New-Item -ItemType Directory -Force -Path (Split-Path $dest -Parent) | Out-Null
    Move-Item -LiteralPath $Item.Full -Destination $dest
    $note = Join-Path $BackupDir 'RESTAURAR.txt'
    Add-Content -Path $note -Encoding utf8NoBOM -Value (
        "$($Item.Rel): reocupe o slot com a branch que tem o submódulo e mova esta pasta de volta para $($Item.Full) " +
        "(o .git do submódulo usa caminho relativo e só funciona lá). O checkout da branch recria esse caminho como " +
        "pasta VAZIA: apague a pasta vazia antes, senão o Move-Item põe o backup DENTRO dela.")
    return $dest
}

function Get-WtIgnoredFiles([string]$Path) {
    # Arquivos ignorados do slot, um por arquivo (sem colapsar pastas), caminhos com '/'.
    $set = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($l in (Invoke-Git -Dir $Path -GitArgs @('ls-files', '--others', '--ignored', '--exclude-standard')).Lines) {
        if ($l) { [void]$set.Add($l) }
    }
    return , $set
}

function Move-WtIgnoredLeftovers([string]$Path, [string]$BackupDir, $IgnoredBefore, [string]$Branch) {
    # Depois do switch: entradas não rastreadas cujos arquivos eram TODOS ignorados antes — a regra que
    # os ignorava morava num .gitignore que só existe na branch. Cada uma vai para <BackupDir>/<caminho>
    # (nada é apagado). Entrada com algum arquivo que não era ignorado fica no lugar (o detach avisa).
    $moved = @()
    $entries = @((Invoke-Git -Dir $Path -GitArgs @('status', '--porcelain', '--untracked-files=normal')).Lines |
        Where-Object { $_ -like '`?`? *' } | ForEach-Object { $_.Substring(3).Trim('"').TrimEnd('/') })
    foreach ($rel in $entries) {
        $files = @((Invoke-Git -Dir $Path -GitArgs @('ls-files', '--others', '--exclude-standard', '--', $rel)).Lines | Where-Object { $_ })
        if (-not $files -or @($files | Where-Object { -not $IgnoredBefore.Contains($_) }).Count) { continue }
        $dest = Join-Path $BackupDir $rel
        New-Item -ItemType Directory -Force -Path (Split-Path $dest -Parent) | Out-Null
        Move-Item -LiteralPath (Join-Path $Path $rel) -Destination $dest
        Add-Content -Path (Join-Path $BackupDir 'RESTAURAR.txt') -Encoding utf8NoBOM -Value (
            "${rel}: arquivos que a branch '$Branch' ignorava ($($files.Count) arquivo(s)) e que viraram não rastreados na base. " +
            "Para recuperar, reocupe um slot com essa branch e copie esta pasta de volta para o mesmo caminho.")
        $moved += $rel
    }
    return $moved
}

function Get-WtWorktrees([string]$Root) {
    # Parse de `git worktree list --porcelain` -> objetos {Path, Head, Branch, Detached}.
    $lines = (Invoke-Git -Dir $Root -GitArgs @('worktree', 'list', '--porcelain')).Lines
    $list = @(); $cur = $null
    foreach ($l in $lines + '') {
        if ($l -like 'worktree *') { $cur = [ordered]@{ Path = $l.Substring(9); Head = ''; Branch = ''; Detached = $false } }
        elseif ($l -like 'HEAD *' -and $cur) { $cur.Head = $l.Substring(5) }
        elseif ($l -like 'branch *' -and $cur) { $cur.Branch = $l.Substring(7) -replace '^refs/heads/', '' }
        elseif ($l -eq 'detached' -and $cur) { $cur.Detached = $true }
        elseif ($l -eq '' -and $cur) { $list += [pscustomobject]$cur; $cur = $null }
    }
    return $list
}

function Get-WtSlotInfo($Profiles) {
    # Um objeto por slot. O repo vem do git (verdade); o registro só complementa.
    $meta = Read-WtMeta
    foreach ($name in $script:WtSlotNames) {
        $path = Join-Path $script:WtDir $name
        $m = if ($meta.ContainsKey($name)) { $meta[$name] } else { @{} }
        $info = [ordered]@{
            Name = $name; Path = $path; State = 'vazio'; RepoRoot = ''; Profile = $null; RepoName = ''
            Branch = ''; Tree = $null; LastCommit = ''; Meta = $m; Warning = ''
            Ticket = $m['ticket']; Purpose = $m['purpose']; AttachedAt = $m['attachedAt']; FreedAt = $m['freedAt']
        }
        # Só é worktree se o toplevel for a própria pasta — senão o git "sobe" para o repo que contém o pool.
        $top = if (Test-Path (Join-Path $path '.git')) { Invoke-Git -Dir $path -GitArgs @('rev-parse', '--show-toplevel') -AllowFail } else { $null }
        if ($top -and $top.Ok -and (ConvertTo-WtPathKey $top.Lines[0]) -eq (ConvertTo-WtPathKey $path)) {
            $info.RepoRoot = Get-WtRepoRootOf $path
            $info.Profile = Find-WtProfileByRoot $Profiles $info.RepoRoot
            $info.RepoName = if ($info.Profile) { $info.Profile.Name } else { '' }
            $sym = Invoke-Git -Dir $path -GitArgs @('symbolic-ref', '-q', '--short', 'HEAD') -AllowFail
            $info.Branch = if ($sym.Ok) { $sym.Lines[0] } else { '' }
            $info.Tree = Get-WtTreeState $path
            $info.LastCommit = (Invoke-Git -Dir $path -GitArgs @('log', '-1', '--format=%h %cs %s')).Lines[0]
            $info.State = if ($info.Branch) { 'ocupado' } elseif ($info.Tree.Dirty) { 'sujo' } else { 'livre' }
            if (-not $info.Profile) { $info.Warning = "repo sem perfil: $($info.RepoRoot)" }
            elseif ($m['repo'] -and $m['repo'] -ne $info.RepoName) { $info.Warning = "registro diz '$($m['repo'])', git diz '$($info.RepoName)'" }
            if (-not $info.Ticket -and $info.Profile) { $info.Ticket = Get-WtTicketId $info.Profile $info.Branch }
            if ($info.Branch -and @($script:WtSlotPolicy).Count) {
                $allowed = try { Get-WtAllowedSlots $info.Branch } catch { @() }
                if ($name -notin $allowed) { $info.Warning = (@($info.Warning, "branch fora da faixa do slot ($(Get-WtSlotLabel $name))") | Where-Object { $_ }) -join '; ' }
            }
        } elseif ((Test-Path $path) -and (Get-ChildItem -Force $path | Select-Object -First 1)) {
            $info.State = 'bloqueado'; $info.Warning = 'pasta existe, não é worktree e não está vazia'
        }
        [pscustomobject]$info
    }
}

# ---------------------------------------------------------------- operações de baixo nível

function Invoke-WtHook([scriptblock]$Hook, [string]$Name, [hashtable]$Ctx) {
    if (-not $Hook) { return }
    Write-Host "Gancho $Name ($($Ctx.Slot))..."
    & $Hook ([pscustomobject]$Ctx)
}

function Get-WtLinks([string]$Path) {
    # Junctions/symlinks dentro do slot (sem segui-los).
    @(Get-ChildItem -LiteralPath $Path -Recurse -Force -Attributes ReparsePoint -ErrorAction SilentlyContinue)
}

function Test-WtFolderLocked([string]$Path) {
    # Renomear a pasta falha se algum processo (IDE, servidor web de desenvolvimento, build...) segura arquivo nela.
    $probe = "$Path.wtprobe"
    try { Rename-Item -LiteralPath $Path $probe -ErrorAction Stop } catch { return $true }
    Rename-Item -LiteralPath $probe $Path
    return $false
}

function Get-WtCleanKeepArgs([string]$Path, $Prof) {
    # `-e !<padrão>` protegendo do `git clean -X` os padrões do perfil e todo link ignorado.
    $keep = @($Prof.CleanKeep)
    foreach ($l in (Invoke-Git -Dir $Path -GitArgs @('clean', '-ndX')).Lines) {
        if ($l -notlike 'Would remove *') { continue }
        $rel = $l.Substring(13)
        $item = Get-Item -LiteralPath (Join-Path $Path $rel) -Force -ErrorAction SilentlyContinue
        if ($item -and $item.LinkType) { $keep += "/$rel" }
    }
    $keep | Select-Object -Unique | ForEach-Object { '-e'; "!$_" }
}

function New-WtSlotWorktree($Slot, $Prof) {
    # vazio -> livre@repo
    if ((Test-Path $Slot.Path) -and (Get-ChildItem -Force $Slot.Path | Select-Object -First 1)) {
        throw "$($Slot.Path) existe e não está vazio. Verifique à mão (worktree noutro caminho: git worktree move <atual> $($Slot.Path))."
    }
    Invoke-Git -Dir $Prof.Root -GitArgs @('worktree', 'add', '--detach', $Slot.Path, (Get-WtBaseRef $Prof)) | Out-Null
}

function Remove-WtSlotWorktree($Slot) {
    # livre@repo -> vazio. Só slot livre (detached e limpo). Nunca --force.
    if ($Slot.State -ne 'livre') { throw "Slot $($Slot.Name) não está livre (estado: $($Slot.State)). Só slot livre pode ser esvaziado/convertido." }
    if (Test-WtFolderLocked $Slot.Path) {
        throw "Slot $($Slot.Name) tem arquivo preso por outro processo (IDE, servidor web de desenvolvimento, build, terminal aberto na pasta...). Feche e tente de novo — sem --force."
    }
    foreach ($link in Get-WtLinks $Slot.Path) {
        # Remove só o link (nunca o conteúdo do destino) antes do worktree remove.
        if ($link.PSIsContainer) { [IO.Directory]::Delete($link.FullName, $false) } else { [IO.File]::Delete($link.FullName) }
    }
    Invoke-Git -Dir $Slot.RepoRoot -GitArgs @('worktree', 'remove', $Slot.Path) | Out-Null
    Invoke-Git -Dir $Slot.RepoRoot -GitArgs @('worktree', 'prune') | Out-Null
    if (Test-Path $Slot.Path) {
        if (Get-ChildItem -Force $Slot.Path | Select-Object -First 1) { throw "Sobrou conteúdo em $($Slot.Path) após o worktree remove — verifique à mão." }
        Remove-Item -LiteralPath $Slot.Path
    }
}

function Invoke-WtHarvest($Slot, $Prof) {
    # Copia não rastreados + rastreados modificados do slot para o mesmo caminho no checkout
    # principal do repo, com hash. Conflito (destino existe e difere) aborta ANTES de copiar
    # qualquer coisa. Exclude: ignorados. PatchOnly: salvos como .patch + cópia em <pool>/_backup.
    $h = $Prof.Harvest
    if (-not $h -or -not $h['Enabled']) { return }
    $exclude = @($h['Exclude']); $patchOnly = @($h['PatchOnly'])
    $lines = (Invoke-Git -Dir $Slot.Path -GitArgs @('ls-files', '--others', '--modified', '--exclude-standard')).Lines | Select-Object -Unique
    $copy = @(); $patch = @(); $conflicts = @(); $same = 0; $skipped = @()
    foreach ($rel in $lines) {
        $src = Join-Path $Slot.Path $rel
        if (-not (Test-Path -LiteralPath $src -PathType Leaf)) { continue }   # apagado no slot
        if ($exclude | Where-Object { $_ -and $rel -like $_ }) { $skipped += $rel; continue }
        if ($patchOnly | Where-Object { $_ -and $rel -like $_ }) { $patch += $rel; continue }
        $dst = Join-Path $Prof.Root $rel
        if (Test-Path -LiteralPath $dst) {
            if ((Get-FileHash -LiteralPath $src).Hash -eq (Get-FileHash -LiteralPath $dst).Hash) { $same++; continue }
            $conflicts += $rel; continue
        }
        $copy += $rel
    }
    if ($conflicts) {
        throw "Harvest abortado (nada copiado): $($conflicts.Count) arquivo(s) já existem no checkout principal com conteúdo diferente:`n  $($conflicts -join "`n  ")`nResolva (commit no slot, PatchOnly/Exclude no perfil, ou ajuste o principal) e rode de novo."
    }
    foreach ($rel in $copy) {
        $src = Join-Path $Slot.Path $rel; $dst = Join-Path $Prof.Root $rel
        New-Item -ItemType Directory -Force (Split-Path $dst -Parent) | Out-Null
        Copy-Item -LiteralPath $src $dst
        if ((Get-FileHash -LiteralPath $src).Hash -ne (Get-FileHash -LiteralPath $dst).Hash) { throw "Harvest: hash divergente após copiar $rel." }
    }
    $backup = ''
    if ($patch) {
        $backup = Join-Path $script:WtDir "_backup/$($Slot.Name)_$(Get-Date -Format yyyyMMdd-HHmmss)"
        foreach ($rel in $patch) {
            $base = Join-Path $backup $rel
            New-Item -ItemType Directory -Force (Split-Path $base -Parent) | Out-Null
            (Invoke-Git -Dir $Slot.Path -GitArgs @('diff', '--', $rel)).Lines | Set-Content -LiteralPath "$base.patch" -Encoding utf8NoBOM
            Copy-Item -LiteralPath (Join-Path $Slot.Path $rel) $base
            if ((Get-FileHash -LiteralPath (Join-Path $Slot.Path $rel)).Hash -ne (Get-FileHash -LiteralPath $base).Hash) { throw "Harvest: hash divergente no backup de $rel." }
        }
    }
    Write-Host ("Harvest: {0} copiado(s) para {1} · {2} idêntico(s) · {3} excluído(s){4}" -f $copy.Count, $Prof.Root, $same, $skipped.Count,
        $(if ($patch) { " · $($patch.Count) salvo(s) como .patch em $backup" } else { '' }))
}

# ---------------------------------------------------------------- painel

function Get-WtSync([string]$Path, [string]$Branch, $Prof) {
    if (-not $Branch -or -not $Prof) { return '' }
    $baseRef = Get-WtBaseRef $Prof
    $parts = @()
    $up = Invoke-Git -Dir $Path -GitArgs @('rev-parse', '--abbrev-ref', "$Branch@{upstream}") -AllowFail
    if ($up.Ok) {
        $ab = (Invoke-Git -Dir $Path -GitArgs @('rev-list', '--left-right', '--count', "$Branch...$($up.Lines[0])")).Lines[0] -split '\s+'
        $parts += "↑$($ab[0]) ↓$($ab[1]) ``$($up.Lines[0])``"
    } else {
        $parts += 'sem upstream'
    }
    $pending = (Invoke-Git -Dir $Path -GitArgs @('rev-list', '--count', "$baseRef..$Branch") -AllowFail)
    if ($pending.Ok) {
        $parts += if ([int]$pending.Lines[0] -eq 0) { "✅ nada fora de $baseRef" } else { "$($pending.Lines[0]) commit(s) fora de $baseRef" }
    }
    return ($parts -join ' · ')
}

# ---------------------------------------------------------------- conta da credencial (coluna Usuário)

function Get-WtConfigMap([string]$Dir) {
    # `git config --list` numa chamada só: chave -> valor (o último vence, como no git).
    $map = @{}
    $r = Invoke-Git -Dir $Dir -GitArgs @('config', '--list') -AllowFail
    if (-not $r.Ok) { return $map }
    foreach ($l in $r.Lines) {
        $i = $l.IndexOf('=')
        if ($i -lt 0) { $map[$l] = 'true' } else { $map[$l.Substring(0, $i)] = $l.Substring($i + 1) }
    }
    return $map
}

function Get-WtPushRemote([hashtable]$Cfg, [string]$Branch, $Prof) {
    # Remote do push, na ordem do git: pushRemote da branch, remote.pushDefault, remote da branch, origin e
    # Remote do perfil. Vale o primeiro que existe no repo ('' se nenhum).
    $cands = @()
    if ($Branch) { $cands += $Cfg["branch.$Branch.pushRemote"] }
    $cands += $Cfg['remote.pushDefault']
    if ($Branch) { $cands += $Cfg["branch.$Branch.remote"] }
    $cands += 'origin'
    if ($Prof) { $cands += $Prof.Remote }
    foreach ($c in $cands) {
        if ($c -and ($Cfg.ContainsKey("remote.$c.url") -or $Cfg.ContainsKey("remote.$c.pushurl"))) { return $c }
    }
    return ''
}

function Invoke-WtCredentialFill([string]$Dir, [string]$Payload) {
    # `git credential fill` sem prompt, sem janela e com limite de 10 s. Devolve só o username ('' se não houver).
    # A saída traz a senha: fica numa variável local que morre com a função e nunca vai a log, erro ou painel.
    $psi = [Diagnostics.ProcessStartInfo]::new('git')
    foreach ($a in @('-c', 'core.quotepath=false', '-C', $Dir, 'credential', 'fill')) { $psi.ArgumentList.Add($a) }
    $psi.RedirectStandardInput = $true; $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
    $psi.StandardInputEncoding = [Text.UTF8Encoding]::new($false)
    $psi.StandardOutputEncoding = [Text.UTF8Encoding]::new($false)
    $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
    $psi.Environment['GIT_TERMINAL_PROMPT'] = '0'
    $psi.Environment['GCM_INTERACTIVE'] = 'never'
    $p = $null; $user = ''
    try {
        $p = [Diagnostics.Process]::Start($psi)
        $null = $p.StandardError.ReadToEndAsync()
        $stdout = $p.StandardOutput.ReadToEndAsync()
        $p.StandardInput.Write($Payload)
        $p.StandardInput.Close()
        if ($p.WaitForExit(10000)) {
            if ($p.ExitCode -eq 0 -and $stdout.Wait(2000)) {
                foreach ($l in ($stdout.Result -split "`r?`n")) { if ($l.StartsWith('username=')) { $user = $l.Substring(9); break } }
            }
        } else { $p.Kill($true) }
    } catch {
        $user = ''
    } finally {
        if ($p -and -not $p.HasExited) { try { $p.Kill($true) } catch { } }
        if ($p) { $p.Dispose() }
        $stdout = $null
    }
    return $user
}

function Get-WtHttpsUser([string]$Url, [string]$Path, [string]$RepoRoot, [hashtable]$Cache) {
    # Conta de uma URL http(s): pergunta ao helper da credencial, com a URL sem senha e sem caminho de token.
    try { $u = [Uri]$Url } catch { return '_(desconhecido)_' }
    $hostPort = if ($u.IsDefaultPort) { $u.Host } else { "$($u.Host):$($u.Port)" }
    $urlPath = [Uri]::UnescapeDataString($u.AbsolutePath.TrimStart('/'))
    $urlUser = if ($u.UserInfo) { [Uri]::UnescapeDataString(($u.UserInfo -split ':', 2)[0]) } else { '' }
    $key = "$(ConvertTo-WtPathKey $RepoRoot)|$($u.Scheme)://$hostPort/$urlPath|$urlUser"
    if ($Cache -and $Cache.ContainsKey($key)) { return $Cache[$key] }
    $payload = "protocol=$($u.Scheme)`nhost=$hostPort`n" + $(if ($urlPath) { "path=$urlPath`n" }) +
        $(if ($urlUser) { "username=$urlUser`n" }) + "`n"
    $user = Invoke-WtCredentialFill $Path $payload
    $shown = if ($user) { "``$user``" } else { '_(desconhecido)_' }
    if ($Cache) { $Cache[$key] = $shown }
    return $shown
}

function Get-WtPushUrl([string]$Path, [string]$Remote) {
    # URL de push do remote (`git remote get-url --push`); se não for http(s) (DISABLED, ssh, local), a de fetch.
    $push = Invoke-Git -Dir $Path -GitArgs @('remote', 'get-url', '--push', $Remote) -AllowFail
    $url = if ($push.Ok -and $push.Lines.Count) { $push.Lines[0] } else { '' }
    if ($url -notmatch '^https?://') {
        $fetch = Invoke-Git -Dir $Path -GitArgs @('remote', 'get-url', $Remote) -AllowFail
        $url = if ($fetch.Ok -and $fetch.Lines.Count) { $fetch.Lines[0] } else { '' }
    }
    return $url
}

function Get-WtCredentialUser {
    # Conta que o git usa no push do slot (coluna Usuário): só o username da credencial. Nunca e-mail,
    # user.name nem token. Cache opcional por chamada do painel: uma consulta ao helper por (repo, URL).
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$RepoRoot,
        [string]$Branch = '',
        $Prof = $null,
        [hashtable]$Cache = $null
    )
    # Config e URL são do repo, não do slot: com o cache, cada repo gasta uma leitura de config e uma de URL.
    $rk = ConvertTo-WtPathKey $RepoRoot
    if ($Cache -and $Cache.ContainsKey("cfg|$rk")) { $cfgMap = $Cache["cfg|$rk"] }
    else { $cfgMap = Get-WtConfigMap $Path; if ($Cache) { $Cache["cfg|$rk"] = $cfgMap } }
    $remote = Get-WtPushRemote $cfgMap $Branch $Prof
    if (-not $remote) { return '_(desconhecido)_' }
    $uk = "url|$rk|$remote"
    if ($Cache -and $Cache.ContainsKey($uk)) { $url = $Cache[$uk] }
    else { $url = Get-WtPushUrl $Path $remote; if ($Cache) { $Cache[$uk] = $url } }
    if ($url -match '^https?://') { return Get-WtHttpsUser $url $Path $RepoRoot $Cache }
    if ($url -match '^ssh://([^@/]+)@') { return "``$($Matches[1])``" }
    if ($url -match '^([^@/\\:]+)@[^/\\:]+:') { return "``$($Matches[1])``" }
    if ($url -match '^file://|^([A-Za-z]:[\\/]|\\\\|/|\.)') { return '_(local)_' }
    return '_(desconhecido)_'
}

function Write-WtReadme($Profiles) {
    # Regera <pool>/README.md (local) — painel único de todos os repos.
    Assert-WtPanelOwnership
    $slots = @(Get-WtSlotInfo $Profiles)
    $slotKeys = $slots | ForEach-Object { ConvertTo-WtPathKey $_.Path }
    $extra = @($Profiles.Values | ForEach-Object { $_.ExtraColumns } | Where-Object { $_ } | Select-Object -Unique)
    $icon = @{ 'livre' = '🟢 livre'; 'ocupado' = '🔵 ocupado'; 'sujo' = '⚠️ detached com alterações'; 'vazio' = '⚪ vazio'; 'bloqueado' = '❌ bloqueado' }
    $esc = { param($s) if ($s) { ("$s" -replace '\|', '\|') } else { '' } }
    $sr = $script:WtScriptsRel

    $sb = [Text.StringBuilder]::new()
    [void]$sb.AppendLine($script:WtPanelMarker)
    [void]$sb.AppendLine('# Worktree Slots — status do pool')
    [void]$sb.AppendLine()
    [void]$sb.AppendLine("> Gerado em $(Get-Date -Format 'yyyy-MM-dd HH:mm'). **Não edite à mão** — rode ``$(Join-Path $sr 'Update-WtStatus.ps1')``.")
    [void]$sb.AppendLine("> Perfis: $(($Profiles.Values | ForEach-Object { "``$($_.Name)`` ($($_.Root))" }) -join ', ').")
    [void]$sb.AppendLine()
    # Coluna Usuário (conta da credencial do push): logo depois de Repo; userLabel '' esconde nas duas tabelas.
    $userCol = if ($script:WtUserLabel) { @($script:WtUserLabel) } else { @() }
    $userCache = @{}
    $row = { param($c) '| ' + ($c -join ' | ') + ' |' }
    $head = @('Slot', 'Repo') + $userCol + @('Estado', 'Branch', $script:WtTicketLabel, 'Propósito') + $extra + @('Sincronia', 'Alterações locais', 'Último commit')
    [void]$sb.AppendLine('| ' + ($head -join ' | ') + ' |')
    [void]$sb.AppendLine('|' + ('---|' * $head.Count))
    foreach ($s in $slots) {
        $repo = if ($s.RepoName) { $s.RepoName } elseif ($s.Meta['repo']) { "_($($s.Meta['repo']))_" } else { '' }
        if ($s.Warning) { $repo = "$repo ⚠️ $(& $esc $s.Warning)" }
        # Slot livre, ocupado ou sujo pertence a um repo, então mostra a conta; vazio ou bloqueado fica em branco.
        $userCell = if (-not $script:WtUserLabel) { @() }
            elseif ($s.RepoRoot) { @(& $esc (Get-WtCredentialUser -Path $s.Path -RepoRoot $s.RepoRoot -Branch $s.Branch -Prof $s.Profile -Cache $userCache)) }
            else { @('') }
        $branch = if ($s.Branch) { "``$($s.Branch)``" } elseif ($s.Tree) { '_(detached)_' } else { '' }
        $changes = if ($s.Tree) {
            $t = $s.Tree
            if ($t.Dirty -or $t.Ignored) { "$($t.Modified) mod · $($t.Untracked) novos · $($t.Ignored) ignorados" } else { 'limpo' }
        } else { '' }
        $since = if ($s.State -eq 'ocupado' -and $s.AttachedAt) { " _(desde $($s.AttachedAt))_" } elseif ($s.State -eq 'livre' -and $s.FreedAt) { "_(livre desde $($s.FreedAt))_" } else { '' }
        $purpose = if ($s.State -eq 'ocupado') { & $esc $s.Purpose } else { '' }
        $label = Get-WtSlotLabel $s.Name
        $cells = @("**$($s.Name)**$(if ($label) { " _$($label)_" })", $repo) + $userCell + @($icon[$s.State], $branch, $(if ($s.Branch) { & $esc $s.Ticket } else { '' }), "$purpose$since")
        $cells += $extra | ForEach-Object { if ($s.State -eq 'ocupado') { & $esc $s.Meta[$_] } else { '' } }
        $cells += @((Get-WtSync $s.Path $s.Branch $s.Profile), $changes, (& $esc $s.LastCommit))
        [void]$sb.AppendLine('| ' + ($cells -join ' | ') + ' |')
    }
    [void]$sb.AppendLine()
    [void]$sb.AppendLine('## Outras worktrees (fora dos slots, repos com perfil)')
    [void]$sb.AppendLine()
    $ohead = @('Repo') + $userCol + @('Caminho', 'Branch', 'Alterações locais')
    [void]$sb.AppendLine('| ' + ($ohead -join ' | ') + ' |')
    [void]$sb.AppendLine('|' + ('---|' * $ohead.Count))
    $hidden = 0
    foreach ($p in $Profiles.Values) {
        if (-not (Test-Path $p.Root)) {
            $noUser = if ($script:WtUserLabel) { @('') } else { @() }
            [void]$sb.AppendLine((& $row (@($p.Name) + $noUser + @("``$($p.Root)``", '_(checkout principal não encontrado)_', ''))))
            continue
        }
        foreach ($o in Get-WtWorktrees $p.Root) {
            if ((ConvertTo-WtPathKey $o.Path) -in $slotKeys) { continue }
            if ($script:WtHideWorktrees -and $o.Path -match $script:WtHideWorktrees) { $hidden++; continue }
            $b = if ($o.Branch) { "``$($o.Branch)``" } else { '_(detached)_' }
            $t = if (Test-Path $o.Path) { Get-WtTreeState $o.Path } else { $null }
            $c = if (-not $t) { '_(pasta ausente — `git worktree prune`?)_' } elseif ($t.Dirty) { "$($t.Modified) mod · $($t.Untracked) novos" } else { 'limpo' }
            $label = if ((ConvertTo-WtPathKey $o.Path) -eq (ConvertTo-WtPathKey $p.Root)) { ' _(checkout principal)_' } else { '' }
            $u = if (-not $script:WtUserLabel) { @() }
                elseif ($t) { @(& $esc (Get-WtCredentialUser -Path $o.Path -RepoRoot $p.Root -Branch $o.Branch -Prof $p -Cache $userCache)) }
                else { @('') }
            [void]$sb.AppendLine((& $row (@($p.Name) + $u + @("``$($o.Path)``$label", $b, $c))))
        }
    }
    if ($hidden) {
        [void]$sb.AppendLine()
        [void]$sb.AppendLine("_+ $hidden worktree(s) oculta(s) pelo filtro ``$($script:WtHideWorktrees)`` (ex.: worktrees de agente)._")
    }
    [void]$sb.AppendLine()
    [void]$sb.AppendLine('## Operação rápida')
    [void]$sb.AppendLine()
    [void]$sb.AppendLine('```powershell')
    [void]$sb.AppendLine("pwsh $(Join-Path $sr 'Attach-WtSlot.ps1') -Repo <repo> -Branch <branch> -Purpose ""...""   # livre@repo > vazio; -Convert p/ tomar livre de outro repo")
    [void]$sb.AppendLine("pwsh $(Join-Path $sr 'Detach-WtSlot.ps1') -Slot $($script:WtSlotPrefix)N [-Stash] [-DeleteBranch]           # devolve à base do repo (afinidade mantida)")
    [void]$sb.AppendLine("pwsh $(Join-Path $sr 'Convert-WtSlot.ps1') -Slot $($script:WtSlotPrefix)N -Repo <outro> | -Empty           # muda a afinidade de um slot livre")
    [void]$sb.AppendLine("pwsh $(Join-Path $sr 'Update-WtStatus.ps1')                                                  # só regera este painel")
    [void]$sb.AppendLine('```')

    $readme = Join-Path $script:WtDir 'README.md'
    Set-Content -Path $readme -Value $sb.ToString() -Encoding utf8NoBOM -NoNewline
    return $readme
}
