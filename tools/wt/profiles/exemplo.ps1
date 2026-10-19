# Perfil de repositório do pool de Worktree Slots. O nome do arquivo é o nome do repo (-Repo exemplo).
# Só Root é obrigatório; o resto tem default (origin, develop, sem ticket, sem harvest, sem ganchos).
@{
    Root          = 'C:\src\exemplo'                     # checkout principal
    Remote        = 'origin'
    Base          = 'develop'                            # base de corte e posição do slot livre@repo
    BranchPattern = '^(fb|hf)-'                          # só avisa
    # Id do ticket a partir do nome da branch, normalizado ('' se não houver). -Ticket sobrepõe.
    TicketFromBranch = {
        param([string]$Branch)
        if ($Branch -match '(?i)proj-?(\d+)') { return "PROJ-$($Matches[1])" }
        return ''
    }
    ExtraColumns  = @('diario', 'familia')               # chaves de -Meta exibidas no painel (união de todos os perfis)
    CleanKeep     = @()                                  # preservados por -CleanIgnored (links já são)
    Harvest       = @{
        Enabled   = $true                                # detach copia não rastreados/modificados para Root
        Exclude   = @('dados/*.cache')                   # nunca copiar (padrões -like, caminho com /)
        PatchOnly = @('config/local.settings.json')     # rastreado com config local: vira .patch + cópia em <pool>/_backup
    }
    PostAttachHook = {                                   # idempotente; roda em todo attach
        param($Ctx)                                      # Ctx: Root, Repo, Slot, Path, Branch, Created, Meta
        & 'C:\src\.compartilhado\Link-Compartilhado.ps1' -Path $Ctx.Path
    }
    PreDetachHook = $null                                # roda depois do harvest, antes do -Stash
}
