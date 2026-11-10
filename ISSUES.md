# Backlog

Registrado localmente até o projeto ter repositório próprio com issues.

## Abertas

- **I6 — slot livre com submódulo inicializado não converte:** depois de `git submodule update --init`
  dentro de um slot livre, `Convert-WtSlot.ps1 -Empty` falha com "working trees containing submodules
  cannot be moved or removed". O `git worktree remove` barra mesmo depois do `git submodule deinit`,
  porque o git também recusa enquanto existir `<gitdir comum>/worktrees/<slot>/modules`.
  **Reprodução (sandbox, repo `exemplo` com submódulo `libs/tema` no slot `g1`):** attach, detach,
  `submodule update --init` no slot, `Convert-WtSlot -Slot g1 -Empty`: falha; com `submodule deinit -f`
  antes, continua falhando. **Contorno manual:** `git submodule deinit -f libs/tema`, mover
  `<gitdir comum>/worktrees/g1/modules` para `<pool>/_backup/`, e converter o slot de novo: passa.
  Achado na preparação da operação da coluna Usuário; não corrigido (fora do escopo dela).

## Resolvidas
- **I1 — ignorados que viram não rastreados no detach:** movidos para `<pool>/_backup` (T6, T7).
- **I2 — bateria de testes completa:** `tests/Test-Pool.ps1`, 41 verificações cobrindo a validação
  manual da v3/v3.2, conferida por mutação.
- **I3 — código duplicado na documentação:** Apêndice A removido; `tools/wt/` é a fonte única.
- **I4 — exemplos neutros:** caminhos, tickets, prefixos, arquivos de configuração e ferramentas
  de desenvolvimento trocados por exemplos genéricos.
- **I5 — idioma e licença:** pt-BR, licença MIT.
