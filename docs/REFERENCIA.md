# Referência: engenho de Worktree Slots (portável) — v3.2, pool compartilhado entre repositórios

Documento de referência para **um pool fixo de worktrees ("slots") compartilhado por vários
repositórios** na mesma máquina. Cobre o modelo, os scripts, a configuração por repositório, a
migração de worktrees existentes e as armadilhas. Os pontos a parametrizar estão marcados como
`<PARÂMETRO>`.

> **Código-fonte:** os scripts e um perfil de exemplo estão em `tools/wt/`, a única fonte do
> código; este documento descreve o modelo, os algoritmos e a operação. Para implantar: copie
> `tools/wt/` para a pasta de scripts, configure com um `wt.config.json` (seção 5), crie um perfil
> por repositório e siga o checklist da seção 6.2. A verificação feita está em `README.md` e em
> `tests/`.
>
> **Convenção de branch e fluxo de merge vêm de cada repositório**, não deste documento: no pool
> eles são campos do perfil (`BranchPattern`, `Base`, `TicketFromBranch`). Se encontrar referências
> a documentos de Git Flow de outro repositório, ignore-as e use a convenção local.
>
> **Da v2 para a v3:** um pool para vários repos (antes: um pool por repo); perfis por repo; estado
> `vazio`; conversão explícita de afinidade (`Convert-WtSlot.ps1`, `-Convert`); harvest embutido
> para o checkout principal; lock entre sessões; painel único com coluna Repo; proteção do
> `README.md` do pool.
>
> **v3.1:** `-Meta` com vários campos passa a ser **um argumento só**, `'k1=v1;k2=v2'`, com a chave
> validada; os scripts recusam argumento solto (sem binding posicional). Antes, uma lista com
> vírgula via `pwsh -File` chegava quebrada e os pedaços podiam cair em silêncio em `-Purpose`,
> `-Ticket` ou `-Base` (seção 7).
>
> **v3.2:** política opcional de **faixas de slot por tipo de branch** (`$WtSlotPolicy`, seção 2.6)
> e `Move-WtSlot.ps1` para mover a worktree de um slot para outro slot vazio (seção 4.6).

---

## 1. Problema que resolve

Tocar várias frentes ao mesmo tempo (features, hotfixes, investigações, MVPs), em **vários
repositórios**, sem:

- ficar trocando a branch do checkout principal (`git switch` + stash + rebuild a cada troca);
- clonar repos várias vezes (clones divergentes, `fetch` repetido, objetos duplicados);
- criar worktrees ad hoc com nomes/pastas aleatórios que ninguém lembra de limpar;
- manter um conjunto de pastas por repositório quando a atenção disponível é uma só.

A solução é um **conjunto fixo e pequeno de slots com nomes globais** (`g1..g7`), cada um ligado
por **afinidade** a um repositório, ocupados por uma branch e depois devolvidos.

## 2. Modelo

### 2.1 Layout

```
<base>\tools\wt\                  ← scripts do pool                          <PARÂMETRO: pasta dos scripts>
<base>\tools\wt\profiles\<repo>.ps1   ← um perfil por repositório
<pool>\                           ← $WtDir (fora de versionamento)           <PARÂMETRO: $WtDir>
    ├── README.md                 ← painel único, gerado
    ├── .slots.json               ← registro: slot → {repo, branch, ticket, propósito, ...}
    ├── .lock                     ← lock entre sessões/agentes
    ├── _backup\                  ← backups do harvest (PatchOnly)
    └── g1\ … g7\                 ← os slots                                 <PARÂMETRO: $WtSlotPrefix/$WtSlotCount>
<repos>\<projeto>\                ← checkouts principais (Root de cada perfil)
```

Por padrão `$WtDir` é `<pasta dos scripts>\..\..\wt` — com scripts em `C:\x\tools\wt`, o pool fica
em `C:\x\wt`. O pool pode morar dentro de outro repositório (desde que ignorado por ele): os scripts
nunca confundem uma pasta de slot vazia com aquele repositório (seção 7).

Cada worktree pertence ao `.git` de **um** repositório e compartilha com ele objetos, refs, remotes
e stash. Um `git fetch` no checkout principal vale para todos os slots daquele repo.

### 2.2 Estados de um slot

| Estado | Definição | Como se chega |
|---|---|---|
| **vazio** | não há worktree na pasta (ou a pasta não existe) | início; `Convert-WtSlot -Empty` |
| **livre@repo** | worktree do repo, HEAD *detached* em `<REMOTE>/<BASE>` do perfil, limpa | detach; conversão; provisionamento |
| **ocupado@repo** | worktree com uma branch em check-out | attach |
| **sujo** | detached, mas com alterações locais | anomalia — investigar à mão |
| **bloqueado** | a pasta existe, não é worktree e não está vazia | anomalia — investigar à mão |

O **repo de um slot é sempre o que o git diz** (`git -C <slot> rev-parse --git-common-dir`); o
registro `.slots.json` guarda só metadados. Se os dois divergirem, o painel mostra ⚠️.

### 2.3 Por que o slot livre fica *detached*

O git não deixa a mesma branch estar em check-out em duas worktrees. Um slot "parqueado" em
`develop` seguraria essa branch e o checkout principal — ou outro slot — não poderia usá-la.
Detached em `<REMOTE>/<BASE>` não prende branch nenhuma e deixa o slot num ponto conhecido.

### 2.4 Afinidade e conversão

Trocar de tarefa **dentro do mesmo repo** reaproveita a worktree: caches de build (`bin/obj`,
`packages`, `.vs`, `node_modules`) e configuração local de IDE sobrevivem. Trocar o slot **de
repo** exige `git worktree remove` + `git worktree add` — e esses caches não servem de um repo para
outro de qualquer forma. Por isso:

- o attach prefere **livre@repo**, depois **vazio**;
- tomar um livre de **outro** repo é uma **conversão**: explícita (`-Convert` no attach ou
  `Convert-WtSlot.ps1`), escolhe o livre ocioso há mais tempo, e exige que a pessoa tenha
  confirmado;
- slot **ocupado nunca é convertido**; slot sujo/bloqueado também não.

### 2.5 Invariantes

1. **Slots não são removidos para "liberar".** Liberar = voltar a detached (livre@repo).
   `git worktree remove` só acontece dentro da conversão, com pré-condições: slot livre (detached e
   limpo), nenhum arquivo preso por processo, links desfeitos antes; **nunca `--force`**.
2. **Um slot = um tópico.** O slot segura *uma* branch; tópicos com várias branches na seção 6.6.
3. **Nada é descartado automaticamente.** O detach recusa slot sujo. Saídas conscientes: commit,
   harvest (copia para o checkout principal), `-Stash` (stash rotulado), descarte manual.
4. **Branch remota nunca é tocada.** Branch local só é apagada se já integrada na base.
5. **Uma operação por vez no pool.** Attach/detach/conversão/painel rodam sob lock de arquivo.
6. **Estado é local à máquina.** Painel, registro, lock e backups ficam no pool; o que se
   compartilha é a convenção (este doc), os scripts e os perfis.

### 2.6 Faixas de slot por tipo de branch (opcional)

`$WtSlotPolicy` reserva faixas do pool para tipos de branch — ex.: `g1..g3` só hotfix, `g4..g7` só
feature/doc — para que um tipo nunca esgote o pool do outro. Cada regra tem `Label`, `Pattern`
(regex sobre o nome da branch, igual para todos os repos) e `Slots`; a **primeira** regra que casa
decide. Com a política ativa:

- o attach só escolhe/aceita slots da faixa da branch; faixa cheia **não transborda** para outra;
- `$WtSlotPolicyStrict = $true` recusa branch que não casa com nenhuma regra; `$false` a libera
  para qualquer slot (inclusive slots fora de todas as faixas);
- adoção (attach idempotente) de branch que já está fora da faixa **só avisa**, para não travar a
  migração — corrija com `Move-WtSlot`;
- o painel mostra a faixa ao lado de cada slot e ⚠️ quando a branch está fora dela;
- `Convert-WtSlot -Repo` recusa slot que não pertence a nenhuma faixa (nenhuma branch poderia
  ocupá-lo). Detach e `Convert -Empty` ignoram a política.

`$WtSlotPolicy = @()` (padrão) desativa tudo isso.

## 3. Componentes

### 3.1 Scripts (PowerShell 7, Windows)

Código em `tools/wt/`. Todos aceitam `-NoFetch`.
Parâmetros são strings/switches para funcionarem via `pwsh -File` (que não aceita hashtable nem
lista): vários campos de `-Meta` vão num argumento só, separados por `;`. Nenhum script aceita
argumento posicional — sobra de argumento é erro, nunca vai parar noutro parâmetro.

| Arquivo | Papel |
|---|---|
| `WtCommon.ps1` | CONFIGURAÇÃO GLOBAL + núcleo (dot-source): perfis, lock, registro, estado, harvest, conversão, painel. |
| `Attach-WtSlot.ps1 -Branch <b> [-Repo <r>] [-Slot gN] [-Base <B>] [-Purpose "..."] [-Ticket <id>] [-Meta 'k1=v1;k2=v2'] [-Convert]` | Ocupa slot (ou adota/atualiza o que já está nele). Sem `-Repo`, infere pelo diretório corrente. |
| `Detach-WtSlot.ps1 -Slot gN \| -Branch <b> [-Stash] [-DeleteBranch] [-NoHarvest] [-CleanIgnored]` | Libera slot → livre@repo (afinidade mantida). |
| `Convert-WtSlot.ps1 -Slot gN -Repo <r> \| -Empty` | Muda a afinidade de um slot livre (ou provisiona um vazio). |
| `Move-WtSlot.ps1 -From gN -To gM` | Move a worktree (com alterações locais) para um slot vazio, levando o registro. |
| `Update-WtStatus.ps1` | Fetch de todos os repos com perfil + regera o painel. |

### 3.2 Perfis (`profiles\<repo>.ps1`)

Um arquivo por repositório; o nome do arquivo é o nome do repo (`-Repo <nome>`). Devolve um
hashtable — só `Root` é obrigatório:

| Chave | Default | Significado |
|---|---|---|
| `Root` | — | Checkout principal do repo. |
| `Remote` / `Base` | `origin` / `develop` | Base de corte das branches novas **e** posição do livre@repo. `-Base` no attach sobrepõe só o corte. |
| `BranchPattern` | `.` | Convenção de nomes. Só avisa. |
| `TicketFromBranch` | nenhum | Scriptblock `param($Branch)` → id do ticket ou `''`. Permite normalizar (ex.: `hf-proj123-x` → `PROJ-123`). `-Ticket` sobrepõe. |
| `ExtraColumns` | `@()` | Chaves de `-Meta` exibidas como colunas. O painel usa a união de todos os perfis. |
| `CleanKeep` | `@()` | Padrões preservados por `-CleanIgnored`. Junctions/symlinks já são preservados. |
| `Harvest` | desligado | `@{ Enabled; Exclude = @(...); PatchOnly = @(...) }` — seção 4.4. |
| `PostAttachHook` / `PreDetachHook` | `$null` | Ganchos — seção 3.5. |

### 3.3 Painel `<pool>\README.md`

Gerado a cada operação. Primeira linha: o marcador `<!-- wt-panel: ... -->`. **Se existir no pool
um `README.md` sem o marcador** (ex.: um manifesto manual), todos os scripts recusam até que ele
seja renomeado — o painel o sobrescreveria.

| Slot | Repo | Estado | Branch | Ticket | Propósito | *extras* | Sincronia | Alterações locais | Último commit |
|---|---|---|---|---|---|---|---|---|---|

- **Repo** = nome do perfil, vindo do git; ⚠️ se o repo não tem perfil ou se diverge do registro.
- **Sincronia** = `↑ahead ↓behind` do upstream + commits fora de `<REMOTE>/<BASE>` do perfil.
- **Alterações locais** = modificados · não rastreados · ignorados.
- **Outras worktrees** (segunda tabela): worktrees fora dos slots de todos os repos com perfil,
  inclusive os checkouts principais. As que casam com `$WtHideWorktrees` (padrão: worktrees de
  agente do Claude Code, `.claude\worktrees\*`) só são contadas.

O painel é **estado**; narrativa operacional vai para outro lugar (seção 6.7).

### 3.4 Registro `<pool>\.slots.json`

```json
{
  "g2": { "repo": "exemplo", "branch": "fb-Exp-llm", "ticket": "PROJ-42", "attachedAt": "2026-10-05",
          "purpose": "Parser do retorno", "familia": "staging > fb-Exp > fb-Exp-llm" },
  "g5": { "repo": "exemplo", "freedAt": "2026-10-06 09:30" }
}
```

Attach grava `repo`, `branch`, `ticket`, `purpose`, `attachedAt` e os `-Meta`. Detach reduz a
entrada a `{repo, freedAt}` (afinidade + desde quando está ocioso, usado para escolher o candidato
à conversão). `Convert -Empty` remove a entrada.

### 3.5 Ganchos

Scriptblocks no perfil, recebendo `$Ctx = {Root, Repo, Slot, Path, Branch, Created, Meta}`:

| Gancho | Quando roda | Uso típico |
|---|---|---|
| `PostAttachHook` | Depois de **todo** attach (inclusive o idempotente). `Created` = worktree recém-criada. Precisa ser idempotente. | Ligar uma pasta compartilhada (junction/symlink), copiar `.env` de modelo, restore. |
| `PreDetachHook` | Depois do harvest, antes do `-Stash`. Exceção aborta o detach. | Validações próprias, notificações. |

### 3.6 Integração com Claude Code

Skills que embrulham os scripts. O valor delas é **decidir repo e nome de branch pela convenção**,
**perguntar antes de `-Convert`/`-Stash`/descarte** e **não forçar** quando o script recusa.
Modelos na seção 8.

**Formato obrigatório:** cada skill é uma **pasta** com `SKILL.md` e frontmatter (`name`,
`description`). Com pool para vários repos, as skills ficam no nível do usuário:

```
~/.claude/skills/wt-attach/SKILL.md     ← carregada como skill
~/.claude/skills/wt-detach/SKILL.md     ← carregada como skill
<qualquer>/WorktreeSlots-Referencia.md  ← NÃO é skill: .md solto não é carregado
```

## 4. Algoritmos

### 4.1 Estado de um slot

```
se <slot>\.git não existe                         → vazio (ou bloqueado, se a pasta tiver conteúdo)
top = git -C <slot> rev-parse --show-toplevel
se top ≠ <slot>                                   → vazio/bloqueado   (o git subiu para o repo que contém o pool)
repo = pai de (git -C <slot> rev-parse --path-format=absolute --git-common-dir)
perfil = o perfil cujo Root = repo  (⚠️ se nenhum, ou se ≠ registro)
branch = git symbolic-ref -q --short HEAD
com branch → ocupado · sem branch e limpo → livre · sem branch e sujo → sujo
```

### 4.2 Attach

```
perfil = -Repo | perfil do repo do diretório corrente
fetch <REMOTE> do perfil                                    (fora do lock)
LOCK
se a branch já está numa worktree do repo:
    é um slot → idempotente: só metadados + gancho          (é assim que se ADOTA — 6.3)
    senão     → ERRO (liberar lá, ou git worktree move para o slot)
faixa = slots permitidos para a branch pela política (todos, sem política)
slot = -Slot (precisa estar na faixa) | na faixa: 1º livre@repo | 1º vazio | (só com -Convert) livre@outro ocioso há mais tempo
       sem -Convert e só há livre@outro → ERRO apontando o candidato · faixa sem slot → ERRO (não transborda)
vazio      → git worktree add --detach <slot> <REMOTE>/<BASE>
livre@outro→ conversão (4.3)
ocupado/sujo/bloqueado → ERRO
branch local → switch · só remota → switch --track · nova → switch --no-track -c <b> <REMOTE>/<BASE>
registro (repo, branch, ticket, -Meta, purpose) · PostAttachHook · painel
UNLOCK
```

`--no-track` na criação é proposital: a branch nova não deve ter a base como upstream (senão
`git push` sem argumentos empurra para a base). O upstream nasce no primeiro `git push -u`.

### 4.3 Conversão (livre@A → livre@B ou vazio)

```
pré: slot livre (detached e limpo) — ocupado/sujo nunca
renomear a pasta e desfazer → falhou? ERRO "arquivo preso" (IDE, servidor web de desenvolvimento, build...) — sem --force
desfazer junctions/symlinks dentro do slot (remove o link, nunca o conteúdo do destino)
git -C <A> worktree remove <slot> ; git -C <A> worktree prune ; remover pasta se ficou vazia
destino B → git -C <B> worktree add --detach <slot> <REMOTE>/<BASE>   (vazio: para aqui)
```

Testado: `git worktree remove` com uma junction ignorada dentro **não** apagou o destino, mas deixou
a pasta para trás — por isso os links são desfeitos antes.

### 4.4 Detach e harvest

```
LOCK ; slot ocupado|sujo ; perfil = perfil do repo do slot ; fetch
-DeleteBranch e branch não contida em <REMOTE>/<BASE> → ERRO (antes de qualquer efeito)
HARVEST (se Harvest.Enabled e sem -NoHarvest):
    arquivos = git ls-files --others --modified --exclude-standard (no slot)
    Exclude   → ignora
    PatchOnly → <pool>\_backup\<slot>_<data>\<arq>.patch (git diff) + cópia do arquivo, hash conferido
    demais    → destino = <Root do perfil>\<mesmo caminho>
                destino não existe → copia · idêntico → nada · diferente → CONFLITO
    algum CONFLITO → ERRO listando todos, NADA copiado (plano antes de executar)
    copia com SHA-256 conferido
PreDetachHook
-Stash e sujo → git stash push --include-untracked -m "wt-detach <slot> <branch> <data>"
ainda sujo → ERRO listando
avisos: commits sem push; sem upstream e fora da base
submódulos inicializados no slot (gitlinks do HEAD com .git na pasta):
    alterações ou HEAD fora de refs/remotes → ERRO (antes de qualquer efeito)
ignorados = git ls-files --others --ignored --exclude-standard (antes do switch)
git switch --detach <REMOTE>/<BASE>
    órfão (não é submódulo na base) → working tree MOVIDA para <pool>\_backup\<slot>_<data>\<caminho> + RESTAURAR.txt
    defasado (submódulo nos dois, commit diferente) → git submodule update -- <caminho>
    não rastreado cujos arquivos eram TODOS ignorados antes → MOVIDO para o mesmo _backup
    ainda sujo → aviso (nada descartado)
registro → {repo, freedAt}
-DeleteBranch → git branch -d <b>   (no slot, não na raiz — seção 7)
-CleanIgnored → git clean -fdX -e !<links e CleanKeep>
painel ; UNLOCK
```

O harvest **não limpa** o slot: copiar não é descartar. Depois dele, o detach ainda exige commit,
`-Stash` ou descarte. Uso típico em slot "sujo por design": `Detach-WtSlot -Slot gN -Stash`.

"Contida na base" = `git merge-base --is-ancestor <b> <REMOTE>/<BASE>`: confiável com **merge
commit** (ou fast-forward), que é a regra do modelo. Squash pontual (sanitização de histórico)
muda os SHAs e `-DeleteBranch` recusa — ver 6.8.

### 4.5 Lock

`Invoke-WtLocked` abre `<pool>\.lock` com `FileShare.None`; quem não consegue tenta de novo a cada
250 ms até `$WtLockTimeoutSec` (padrão 60 s) e então falha com mensagem clara. O trecho protegido
vai da leitura do estado até gravar registro e painel — duas sessões nunca escolhem o mesmo slot.
O fetch fica fora do lock. Testado: dois attaches simultâneos disputando um único slot → um vence,
o outro recusa limpo, registro consistente.

### 4.6 Move (gN → gM)

```
LOCK ; origem com worktree (ocupado|livre|sujo) ; destino vazio
política e origem ocupada → destino precisa estar na faixa da branch
renomear a origem e desfazer → falhou? ERRO "arquivo preso"
destino existe como pasta vazia → removê-la   (senão o git move PARA DENTRO: <gM>\<gN>)
git -C <repo> worktree move <gN> <gM>    (alterações locais e links internos vão junto)
registro: gM ← gN ; PostAttachHook no destino ; painel ; UNLOCK
```

## 5. Configuração (`wt.config.json`)

A configuração de cada instalação fica num `wt.config.json`, sem editar o código. O motor procura o
arquivo no caminho de `$env:WT_CONFIG` e, sem a variável, ao lado dos scripts. Caminhos relativos
valem a partir da pasta do JSON; chave desconhecida é erro. Sem arquivo, valem os padrões do bloco
CONFIGURAÇÃO GLOBAL do `WtCommon.ps1`.

| Chave | Default | Significado |
|---|---|---|
| `poolDir` | `<scripts>\..\..\wt` | Pasta do pool. |
| `slotPrefix` / `slotCount` | `g` / `7` | Nomes dos slots. `-Slot` é validado contra a lista. |
| `profilesDir` | `<scripts>\profiles` | Perfis. |
| `hideWorktrees` | `.claude\worktrees\*` | Regex de worktrees só contadas no painel; `''` lista todas. |
| `lockTimeoutSec` | `60` | Espera máxima pelo lock. |
| `scriptsLabel` | pasta dos scripts | Só para os textos do painel. |
| `ticketLabel` | `Ticket` | Cabeçalho da coluna do id extraído por `TicketFromBranch`. |
| `slotPolicy` | sem faixas | Faixas por tipo de branch (2.6): lista de `{ "label", "pattern", "slots" }`. |
| `slotPolicyStrict` | `true` | Branch sem regra: `true` recusa, `false` libera qualquer slot. |
| `engineDir` | — | Ignorado pelo motor; serve a atalhos que moram fora da pasta dele e precisam achá-lo. |

Exemplo (hotfix em `g1..g3`, feature/doc em `g4..g7`):

```json
{
  "poolDir": "../../wt",
  "slotPolicy": [
    { "label": "hotfix",      "pattern": "^hf-",       "slots": ["g1", "g2", "g3"] },
    { "label": "feature/doc", "pattern": "^(fb|doc)-", "slots": ["g4", "g5", "g6", "g7"] }
  ]
}
```

O `BranchPattern` de cada perfil deve aceitar os mesmos prefixos da política. Para instalar o motor
fora da pasta da configuração (por exemplo, como submódulo), use atalhos que definem `WT_CONFIG` e
chamam o script do motor.

## 6. Implantação e operação

### 6.1 Novo repositório no pool

1. Criar `profiles\<repo>.ps1` (copie `tools/wt/profiles/exemplo.ps1`; só `Root` é obrigatório).
2. Revisar o `.gitignore` do repo: artefato de build **não ignorado** deixa todo slot sujo para
   sempre (seção 7). Links criados pelo gancho (ex.: `.claude`) devem ser ignorados.
3. Opcional: `Convert-WtSlot -Slot gN -Repo <repo>` para deixar um slot já provisionado.

### 6.2 Checklist de implantação do pool

1. Copiar `tools/wt/` para a pasta de scripts, criar o(s) perfil(is) e o `wt.config.json` (seção 5).
2. Se o pool fica dentro de um repositório, garantir que esse repo ignore a pasta do pool — e, se
   os scripts também estiverem dentro dele sem serem versionados ali, ignorá-los localmente
   (`.git\info\exclude`), não no `.gitignore` versionado.
3. Se já houver `README.md` no pool (manifesto manual), renomeá-lo (ex.: `_manifesto_legado.md`).
4. Resolver pendências do `.git` de cada repo antes de migrar: stashes órfãos, branches locais não
   publicadas, `git worktree prune`.
5. Registrar a convenção onde agentes/pessoas leem: `CLAUDE.md` do repo, ou — sem um — README da
   pasta compartilhada, memória do agente ou `CLAUDE.md` de usuário. Conteúdo mínimo no fim da seção 8.
6. Skills `/wt-attach` e `/wt-detach` em pastas próprias, no nível do usuário (3.6, 8).
7. Ciclo de teste num slot vazio com branch descartável: attach → commit → push → detach (avisa)
   → merge → detach `-DeleteBranch`. Depois as recusas: slot sujo, branch presa no checkout
   principal, `-DeleteBranch` antes do merge, attach sem slot disponível (sem `-Convert`).

### 6.3 Migração de worktrees existentes (adoção)

1. **Inventário:** `git worktree list` em cada repo; o painel lista em "Outras worktrees".
2. **Mover** cada worktree para o caminho do slot (funciona com alterações locais; não com
   submódulos inicializados):
   ```powershell
   git -C <Root> worktree move <pool>\antigo1 <pool>\g1
   ```
3. **Registrar** com attach idempotente, slot explícito e a branch que já está lá — nada muda no
   git; grava metadados e roda o gancho (idempotente):
   ```powershell
   pwsh <scripts>\Attach-WtSlot.ps1 -Repo <repo> -Slot g1 -Branch <branch atual> -Purpose "..." [-Ticket X] [-Meta 'familia=...;diario=...']
   ```
4. **Slot parqueado na base** (em `develop`, não detached): aparece como ocupado por `develop`;
   detach normal (sem `-DeleteBranch`) solta a base.
5. Pastas antigas no pool (backups, manifesto renomeado) são ignoradas pelos scripts.
6. Com política de faixas: a adoção fora da faixa só avisa; depois, `Move-WtSlot -From gN -To gM`
   (destino vazio, na faixa) — o registro vai junto e o gancho roda no destino.

### 6.4 Ganchos — exemplos

Ligar uma pasta compartilhada (pós-attach, idempotente):

```powershell
PostAttachHook = {
    param($Ctx)
    & 'C:\src\.compartilhado\Link-Compartilhado.ps1' -Path $Ctx.Path     # ou: New-Item -ItemType Junction ... se não existir
}
```

### 6.5 Slots sujos por design

| Tipo | Tratamento |
|---|---|
| Artefatos não versionados que devem sobreviver | Harvest → checkout principal; depois `-Stash` ou descarte. |
| Rastreado com config local (ex.: `config/local.settings.json` de ambiente) | `PatchOnly` no perfil: vira `.patch` + cópia em `<pool>\_backup`, sem tocar o arquivo do principal (que tem a config dele). Alternativas: `git update-index --skip-worktree`; tirar a config local do arquivo rastreado. |
| Diário/notas em andamento | Commitar na branch ou manter fora da worktree. Não commitados: harvest copia para o principal. |
| Artefato de build não ignorado | `Exclude` no perfil como paliativo; correção real é o `.gitignore`. |
| Arquivo que existe no principal com conteúdo diferente | Harvest aborta e lista. Decida: commit no slot, `PatchOnly`/`Exclude`, ou ajustar o principal. |

### 6.6 Tópicos com várias branches

Quando uma demanda usa várias branches (ex.: staging → feature → filha), o slot segura **uma** — a
que está em check-out. As demais existem só como refs e podem ser trocadas dentro do slot, desde que
não estejam presas noutra worktree. Registre a família: `-Meta 'familia=A > B > C'` (com
`familia` em `ExtraColumns`). Depois de um `git switch` manual dentro do slot, rode o attach
idempotente com a branch nova para atualizar o registro.

### 6.7 Onde fica a narrativa

O painel é estado (gerado, descartável). Ponto de retomada, histórico de ocupantes e desvios vão
para o **diário do ticket** (`-Meta 'diario=<caminho>'`) e, se quiser, um `HISTORICO.md` local no
pool, só de acréscimo.

### 6.8 Decisões a revisar

- **Merge commit** como regra (é o que torna `--is-ancestor` confiável). Squash pontual de
  sanitização: detach **sem** `-DeleteBranch`, conferir com `git diff <REMOTE>/<BASE> <b>` e apagar
  com `git branch -D <b>`. Não automatizar: o atrito é a proteção.
- **Quantidade de slots.** 7 é teto de atenção. Em repos grandes, cada slot custa disco.
- **Base por tipo de branch.** Hotfix de `main` e feature de `develop`: a skill escolhe `-Base` no
  attach; o livre@repo continua sempre na `Base` do perfil.

## 7. Armadilhas conhecidas

| Armadilha | Detalhe |
|---|---|
| Pool dentro de outro repositório | `git -C <pasta vazia>` sobe e responde pelo repo que contém o pool. Os scripts só aceitam worktree cujo `--show-toplevel` é a própria pasta do slot. |
| Dois ferramentais no mesmo pool | Outro script de slots usando a mesma pasta (outro `README.md`/`.slots.json`) corrompe o registro. Um pool, um ferramental; outros repos entram como perfil. |
| `README.md` manual no pool | O painel o sobrescreveria; os scripts recusam até ele ser renomeado. |
| `git branch -d` na raiz | Mede "integrada" contra o HEAD de onde roda. Rodar no slot já detached na base. |
| `git worktree move` para pasta existente | Se o destino já existe (mesmo vazio), o git move a worktree **para dentro** dele (`gM\gN`), como `mv`. O `Move-WtSlot` remove o destino vazio antes; à mão, garanta que o destino não exista. |
| `git worktree remove` à mão | Só via conversão. À mão, pode apagar caches, falhar com arquivo preso, ou deixar pasta. |
| Arquivo preso no Windows | IDE, servidor web de desenvolvimento, build, antivírus ou um terminal aberto na pasta impedem remover/renomear. A conversão detecta (rename de teste) e manda fechar. |
| `git clean -fdX` e links | Um link ignorado (ex.: `.claude` → pasta compartilhada) é candidato do clean; o slot perderia o vínculo. Os scripts preservam todo link; nunca rode `git clean` à mão num slot com links. |
| Artefato de build rastreado/não ignorado | Slot sempre sujo; detach recusa. Corrigir `.gitignore` (e `git rm --cached`). |
| Submódulos | Não vêm inicializados em worktrees; `git worktree move` não funciona com submódulos inicializados. |
| Submódulo órfão no detach | Branch que **adicionou** um submódulo (ainda fora da base) e o inicializou no slot: `git switch` sem `--recurse-submodules` não remove a working tree dele, que vira pasta não rastreada e deixa o slot "sujo" logo após o detach. O detach move a pasta para `<pool>\_backup` (e recusa antes se o submódulo tiver alterações ou HEAD não publicado). Restaurar: reocupar o slot com a branch, **apagar a pasta vazia** que o checkout recria e só então mover o backup de volta, senão ele vai parar dentro dela. |
| Ignorado que vira não rastreado | Arquivos ignorados por um `.gitignore` que só existe na branch (ex.: `saida/` de um projeto criado nela) perdem a regra depois do switch para a base e deixariam o slot sujo. O detach compara com a lista de ignorados de antes do switch e move para `<pool>\_backup` só as entradas cujos arquivos eram **todos** ignorados; o que é ignorado também na base fica no slot. |
| Ignorados não são compartilhados | `.env`, `appsettings.*.json` locais, `bin/obj`, `packages`, `node_modules`, `.venv`: cada slot tem os seus (gancho pós-attach para copiar/linkar). |
| Portas e recursos fixos | Slots rodando o mesmo serviço brigam por porta, banco local, servidor web de desenvolvimento. |
| Caminhos longos | `<pool>\gN\...` + `packages`/`node_modules` passa fácil de 260 chars: `git config --global core.longpaths true`, pool perto da raiz do disco. |
| Caminhos no Windows | git devolve `D:/a/b`, PowerShell `D:\a\b`, case varia: sempre normalizar antes de comparar. |
| `pwsh -File` e listas | Via `-File` não existe lista: `-Meta 'a=1','b=2'` chega quebrado (vindo do PowerShell, os pedaços viram argumentos extras). Use `-Meta 'a=1;b=2'`. Hashtable também não passa. |
| Binding posicional | Parâmetros de script são posicionais por padrão: argumentos extras eram encaixados em silêncio em `-Purpose`/`-Ticket`/`-Base` (registro corrompido). Os scripts usam `[CmdletBinding(PositionalBinding = $false)]`: sobra vira erro. |
| Aspas e `>` no `cmd` | O `cmd` não remove aspas simples (a chave chegaria como `'familia` — o attach recusa) e trata `>` fora de aspas duplas como redirecionamento. Pelo `cmd`, use aspas duplas: `-Meta "familia=A > B;diario=x"`. |
| `$PSBoundParameters` em scriptblock | Dentro de um scriptblock ele é o do bloco, não o do script: capture antes (o attach faz isso). |
| `$Profile` | Variável automática do PowerShell: não use como nome de parâmetro (os scripts usam `$prof`). |
| Encoding | `[Console]::OutputEncoding = UTF8` e gravação `utf8NoBOM`, senão acentos e ícones quebram. |
| Worktrees de agente | Claude Code cria `.claude\worktrees\agent-*`; não são slots; o painel só conta. Órfãs: `git worktree prune`. |
| Hooks do git | `.git\hooks` é compartilhado entre as worktrees de um repo; config por worktree exige `extensions.worktreeConfig`. |

## 8. Modelos de skill (Claude Code)

Cada bloco vai num `SKILL.md` dentro de pasta própria, em `~/.claude/skills/`. Troque `<scripts>`
pelo caminho real dos scripts.

`~/.claude/skills/wt-attach/SKILL.md`:

```markdown
---
name: wt-attach
description: Ocupa um slot do pool de Worktree Slots (g1~g7, compartilhado entre repositórios) com a branch de uma tarefa, sem trocar a branch do checkout principal. Use quando o usuário pedir para abrir/pegar um slot, começar uma tarefa num slot, adotar uma worktree existente, ou /wt-attach <repo> <branch|ticket>.
---

0. Se `<scripts>/Attach-WtSlot.ps1` não existir, os scripts não foram implantados: copiá-los de
   `tools/wt/` do projeto Worktree Slots (não inventar outra implementação).
1. Repo: o perfil em `<scripts>/profiles/` (nome do arquivo). Na dúvida, perguntar.
2. Branch pela convenção DO REPO (BranchPattern do perfil). Branch existente → nome exato.
   Ambíguo → propor e confirmar. Ticket fora do nome da branch → -Ticket. Família/diário → UM -Meta 'k1=v1;k2=v2'
   (nunca lista com vírgula). Conferir sempre o exit code/saída do script — não filtrar a saída.
3. Rodar: `pwsh -NoProfile -File <scripts>/Attach-WtSlot.ps1 -Repo <r> -Branch <b> -Purpose "<frase>" [-Slot gN] [-Ticket X] [-Meta 'k1=v1;k2=v2']`
4. Se recusar por falta de slot e apontar um candidato à conversão: PERGUNTAR ao usuário
   (mostrar o slot e o repo de origem) antes de repetir com -Convert. Com política de faixas, a recusa
   pode ser "fora da faixa"/"faixa sem slot": não contornar trocando o prefixo da branch — perguntar.
   Outras recusas: mostrar e perguntar.
5. Trabalhar com caminhos absolutos no slot; git sempre `git -C <slot>`.
6. Reportar slot, repo, branch (nova/existente/adotada/convertida), caminho e o painel.
```

`~/.claude/skills/wt-detach/SKILL.md`:

```markdown
---
name: wt-detach
description: Libera um slot do pool de Worktree Slots, devolvendo-o a livre no repo dele (detached na base), depois que a tarefa foi concluída ou pausada. Use quando o usuário pedir para liberar/devolver um slot, após merge de PR feita num slot, ou /wt-detach <gN|branch>.
---

1. Identificar o slot (gN ou branch); na dúvida rodar Update-WtStatus.ps1 e ler o painel.
2. Se o perfil tem harvest, ele roda no detach e copia não rastreados/modificados para o checkout
   principal; conflito aborta sem copiar nada — mostrar a lista e perguntar como resolver.
3. Sujo depois do harvest → o script recusa. NÃO descartar por conta própria: perguntar se é commit,
   -Stash (stash rotulado) ou descarte.
4. Commits sem push / PR aberta → avisar.
5. -DeleteBranch só se a PR já foi mergeada (merge commit). Squash de sanitização → sem -DeleteBranch.
6. Rodar: `pwsh -NoProfile -File <scripts>/Detach-WtSlot.ps1 -Slot gN [-Stash] [-DeleteBranch] [-CleanIgnored]`
7. Nunca `git worktree remove`/`git clean` à mão. Mudar o slot de repo é Convert-WtSlot.ps1, só com
   confirmação do usuário.
```

Conteúdo mínimo para o `CLAUDE.md` (ou equivalente): onde ficam pool, scripts e perfis; que slots
se ocupam/liberam/convertem só pelos scripts/skills; que o painel é gerado; que dentro de um slot o
git roda no slot; e a convenção de branch de cada repo.

## 9. Ciclo de vida, resumido

```powershell
pwsh <scripts>\Attach-WtSlot.ps1 -Repo exemplo -Branch fb-proj7-parser -Purpose "Parser"   # livre@exemplo > vazio
# ... trabalhar no slot: commit, push -u, PR ...
pwsh <scripts>\Update-WtStatus.ps1                                                          # painel
pwsh <scripts>\Detach-WtSlot.ps1 -Slot g3 -DeleteBranch                                     # após merge
pwsh <scripts>\Detach-WtSlot.ps1 -Slot g3 -Stash                                            # pausar (harvest + stash)
pwsh <scripts>\Attach-WtSlot.ps1 -Repo outro -Branch feature/x -Convert                     # tomar livre de outro repo (confirmado)
pwsh <scripts>\Convert-WtSlot.ps1 -Slot g7 -Empty                                           # devolver ao estado vazio
pwsh <scripts>\Move-WtSlot.ps1 -From g2 -To g4                                             # corrigir slot fora da faixa
```
