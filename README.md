# Worktree Slots

Um conjunto fixo e pequeno de **git worktrees** (`g1`…`g7`) compartilhado por vários repositórios
na mesma máquina, para tocar várias frentes em paralelo (features, hotfixes, investigações) sem
trocar a branch do checkout principal e sem clonar o repositório de novo. Cada slot é ocupado por
uma branch (*attach*) e devolvido (*detach*) ao estado livre: HEAD *detached* na base do repo.

PowerShell 7 no Windows, só com `git`. Sem dependências externas.

## Estrutura

| Caminho | Conteúdo |
|---|---|
| `tools/wt/` | Os scripts (`WtCommon.ps1` + um script por operação) |
| `tools/wt/profiles/` | Um perfil `<repo>.ps1` por repositório que usa o pool |
| `docs/REFERENCIA.md` | Modelo, algoritmos, implantação, armadilhas e modelos de skill do Claude Code |
| `tests/` | Testes de integração em sandbox (repositórios e remotos descartáveis) |

## Instalação

1. Copie `tools/wt/` para a pasta de scripts escolhida, por exemplo `C:\x\tools\wt`.
2. Configure com um `wt.config.json` ao lado dos scripts (não é preciso editar `WtCommon.ps1`).
   Sem ele valem os padrões do bloco CONFIGURAÇÃO GLOBAL, e o pool fica em `<scripts>\..\..\wt`
   (no exemplo, `C:\x\wt`).
3. Crie um perfil por repositório na pasta de perfis (padrão `profiles/`; veja
   `profiles/exemplo.ps1`). Só `Root` é obrigatório.
4. Siga o checklist de implantação (seção 6.2 de `docs/REFERENCIA.md`).

### `wt.config.json`

O motor procura o arquivo no caminho de `$env:WT_CONFIG` e, se a variável não existir, ao lado dos
scripts. Caminhos relativos valem a partir da pasta do JSON. Chave desconhecida é erro.

```json
{
  "poolDir": "../../wt",
  "profilesDir": "profiles",
  "ticketLabel": "Ticket",
  "slotPolicyStrict": true,
  "slotPolicy": [
    { "label": "hotfix",  "pattern": "^hf-", "slots": ["g1", "g2"] },
    { "label": "feature", "pattern": "^fb-", "slots": ["g3", "g4", "g5"] }
  ]
}
```

| Chave | Padrão | Significado |
|---|---|---|
| `poolDir` | `<scripts>/../../wt` | Pasta do pool (slots, painel, registro, lock, `_backup`) |
| `profilesDir` | `<scripts>/profiles` | Pasta dos perfis `<repo>.ps1` |
| `slotPrefix` / `slotCount` | `g` / `7` | Nomes dos slots |
| `slotPolicy` / `slotPolicyStrict` | sem faixas / `true` | Faixas de slot por tipo de branch (seção 2.6 da referência) |
| `ticketLabel` | `Ticket` | Cabeçalho da coluna do id extraído por `TicketFromBranch` |
| `userLabel` | `Usuário` | Cabeçalho da coluna com a conta da credencial do push (`""` esconde a coluna) |
| `scriptsLabel` | pasta dos scripts | Caminho mostrado nos textos do painel |
| `hideWorktrees` / `lockTimeoutSec` | worktrees de agente / `60` | Ver bloco CONFIGURAÇÃO GLOBAL |
| `engineDir` | — | Ignorado pelo motor: serve a atalhos que moram fora da pasta dele e precisam achá-lo |

Para instalar o motor fora da pasta onde ficam a configuração e os perfis (por exemplo, como
submódulo), crie atalhos que definem `WT_CONFIG` e chamam o script do motor.

## Uso

```powershell
pwsh tools\wt\Attach-WtSlot.ps1 -Repo meu-repo -Branch fb-parser -Purpose "Parser novo"   # ocupa um slot
pwsh tools\wt\Detach-WtSlot.ps1 -Slot g3                                                    # devolve o slot
pwsh tools\wt\Update-WtStatus.ps1                                                           # regera o painel
```

Outras operações: `Convert-WtSlot.ps1` (muda o repo de um slot livre), `Move-WtSlot.ps1` (move
uma worktree de slot). Detalhes e parâmetros em `docs/REFERENCIA.md`, seção 3.

## Testes

```powershell
pwsh tests\Test-Detach.ps1 -Engine .\tools\wt -Sandbox <pasta-nova-vazia>
pwsh tests\Test-Config.ps1 -Engine .\tools\wt -Sandbox <outra-pasta-nova-vazia>
pwsh tests\Test-Pool.ps1   -Engine .\tools\wt -Sandbox <mais-uma-pasta-nova-vazia>
pwsh tests\Test-User.ps1   -Engine .\tools\wt -Sandbox <outra-pasta-nova-vazia>
```

Cada teste cria um pool e repositórios com remoto bare (e submódulo, no primeiro), tudo dentro de
`-Sandbox`, e roda os scripts de verdade. Não toca em nada fora dessa pasta.

## Estado da verificação (v0.1.0)

**Testado rodando** (PowerShell 7, Git for Windows, Windows 11), todas as verificações passando.

`tests/Test-Config.ps1`, 9 verificações: `WT_CONFIG` define pool, perfis e faixa (C1); nome da
coluna e id extraído no painel (C2); branch fora da faixa recusada (C3); branch sem regra recusada
no modo estrito (C4); chave desconhecida no JSON recusada (C5); `wt.config.json` ao lado dos
scripts, sem `WT_CONFIG` (C6); coluna Usuário com o padrão (C7), com `userLabel` custom (C8) e
vazio, que esconde a coluna (C9).

`tests/Test-User.ps1`, 25 verificações (U0–U24): coluna Usuário com helper https de teste (U2),
slot livre (U3), remoto local (U4), `pushRemote` vencendo o `origin` (U5), ssh (U6), helper sem
usuário (U7), slot vazio e bloqueado em branco (U8), worktrees de fora do pool (U9–U11), cache por
chamada (U12), painel repetível (U13), senha nunca exibida (U14), `userLabel` custom e vazio
(U15–U16), colunas consistentes (U17), painel regerado com a coluna por cima de um painel antigo em
cada operação (Convert sem conversão a fazer, Move, Detach e Attach: U18–U22), tabela do console do
`Update-WtStatus` com a coluna e o mesmo cache do painel (U23) e senha ausente das saídas (U24). Roda o git sem a config global da máquina
(`GIT_CONFIG_NOSYSTEM=1`, `GIT_CONFIG_GLOBAL` apontando para um arquivo vazio do sandbox).

`tests/Test-Detach.ps1`, 8 verificações:

| Id | Cenário |
|---|---|
| T1 | Detach sem submódulo novo (regressão) |
| T2 | Submódulo adicionado pela branch: working tree movida para `<pool>/_backup`, slot limpo |
| T3 | Submódulo com arquivo não rastreado: detach recusa sem efeito |
| T4 | HEAD do submódulo não publicado e invisível ao repo pai (`ignore=all`): detach recusa |
| T4b | Corrigido o submódulo, o detach passa |
| T5 | Submódulo em outro commit que o da base: alinhado com `git submodule update` |
| T6 | Saída ignorada só pelo `.gitignore` da branch: movida para `<pool>/_backup`, slot limpo |
| T7 | Arquivo ignorado também na base: fica no slot, ignorado |

`tests/Test-Pool.ps1`, 41 verificações, com dois repos com remoto bare e o pool dentro de um
terceiro repo:

| Área | Ids | Cenários |
|---|---|---|
| Painel | P1, P12, P13, P22 | `README.md` manual no pool recusado; divergência registro × git acusada e corrigida pelo attach idempotente; worktree de agente só contada; faixa e aviso de branch fora dela |
| Attach | P2–P4, P14, P15 | vazio vira worktree; ticket normalizado e `-Ticket`; `-Meta` e colunas extras; gancho pós-attach (junction); afinidade mantida no detach; livre@repo preferido a vazio; pasta vazia dentro de outro repo; adoção por `worktree move` + attach idempotente |
| Conversão | P5–P8, P24 | recusada sem `-Convert`; com `-Convert` não toca o destino da junction; recusada com arquivo preso; slot ocupado nunca convertido; `-Empty` e `-Repo`; recusada em slot fora das faixas |
| Lock | P9 | dois attaches concorrentes pelo mesmo slot: um vence, o outro recusa, registro = git |
| Harvest | P10, P11 | conflito aborta sem copiar nada; cópia, idêntico, `Exclude`, `PatchOnly` e `-Stash` rotulado |
| `-Meta` | P16 | PowerShell com `;`, `cmd` com aspas duplas (gravam); `cmd` com aspas simples e lista por vírgula (recusam, registro intacto) |
| Faixas | P17–P21, P25 | escolha dentro da faixa; `-Slot` fora recusado; branch sem regra recusada (estrito) ou aceita (não estrito); faixa cheia não transborda; adoção fora da faixa só avisa |
| Move | P23 | recusado fora da faixa, para slot ocupado e com arquivo preso; para pasta vazia existente sem aninhar, levando alterações, registro e junction |
| Fecho | P26 | pastas legadas preservadas; registro = git em todo slot ocupado |

A bateria foi conferida por mutação: com a proteção do `README.md` manual, o aborto do harvest em
conflito ou a checagem de faixa do Move removidos do motor, as verificações correspondentes falham.

### Validação histórica (antes de virar projeto)

A rodada manual em sandbox que validou a v3/v3.2 antes dos testes executáveis (hoje cobertos por
`tests/Test-Pool.ps1`):

> Testado (PowerShell 7.6, git for Windows, Windows 11) num sandbox que imita uma máquina real:
> pool dentro de outro repositório, dois repos com perfil (um com harvest, ticket normalizado e
> gancho de junction), worktrees legadas ocupadas e sujas, manifesto manual e worktree de agente.
> 38 verificações, todas passando: recusa com README manual; migração por `worktree move` +
> attach idempotente; ticket normalizado e explícito; colunas extras; worktree de agente oculta;
> slot vazio dentro de outro repo; preferência livre@repo > vazio; afinidade mantida no detach;
> conversão recusada sem `-Convert`, recusada com arquivo preso, executada com `-Convert` sem
> tocar o destino da junction; slot ocupado nunca convertido; dois attaches concorrentes por um
> slot (um vence, o outro recusa, registro consistente); harvest com conflito (nada copiado),
> cópia, idêntico, `Exclude`, `PatchOnly` (.patch + cópia, principal intocado) e `-Stash`;
> divergência registro x git no painel; `-Empty`; pastas legadas preservadas. v3.1, `-Meta` em
> 4 formas de chamada: PowerShell com `;` (grava), `cmd` com aspas duplas e `;` (grava), `cmd`
> com aspas simples (recusa, registro intacto), PowerShell com lista por vírgula (erro, registro
> intacto). v3.2, 25 verificações da política e do Move: escolha automática dentro da faixa;
> `-Slot` fora da faixa, branch sem regra (estrito) e slot fora das faixas recusados sem efeito
> colateral; faixa cheia não transborda; adoção fora da faixa só avisa; Move recusado para fora
> da faixa, para slot ocupado e com arquivo preso; Move com pasta de destino vazia pré-existente
> (sem aninhar), levando alterações locais, registro e junction; `Convert -Repo` recusado em slot
> fora das faixas; rótulos de faixa no painel; modo não estrito. Política vazia: as 38
> verificações originais seguem passando.

## Licença

[MIT](LICENSE).
