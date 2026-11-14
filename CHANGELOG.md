# Changelog

## [Não lançado]

- **Novo — coluna Usuário no painel:** mostra a conta da credencial que o `git push` de cada slot vai
  usar (o `username` do helper; o usuário de uma URL ssh; `_(local)_` para remoto local). Fica logo
  depois de Repo nas duas tabelas. O cabeçalho vem de `userLabel` em `wt.config.json` (padrão `Usuário`;
  `""` esconde a coluna). Só o username é exibido: nunca e-mail, `user.name` nem a senha do helper.
  Uma consulta ao helper por (repo, URL) por painel.
- **Corrigido — painel desatualizado no `Convert` sem efeito:** `Convert-WtSlot` com o slot já livre
  no repo pedido, ou já vazio com `-Empty`, saía sem regerar o painel. Um painel escrito por outra versão
  do motor (por exemplo, sem a coluna Usuário) continuava assim. Agora regera também nesses casos.
- **Novo — coluna Usuário no console:** a tabela que o `Update-WtStatus` imprime ganha a coluna (texto
  puro: `alice`, `(local)`), logo depois de Repo, e some com `userLabel` vazio. Console e painel
  compartilham o cache: continua uma consulta ao helper por (repo, URL).
- Testes: `tests/Test-User.ps1` (U0–U24, 25 verificações; U18–U24 cobrem a coluna depois de cada
  operação e no console); `tests/Test-Config.ps1` ganha C7–C9
  (padrão, `userLabel` custom e vazio).

## [0.1.0] — não publicada
Pronta para publicação (sem pendências em `ISSUES.md`).
Primeira versão como projeto: os scripts deixam de "nascer" do Apêndice A da referência e passam a
viver em `tools/wt/`.

- Base: o engenho v3.2 (pool compartilhado entre repositórios, perfis por repo, lock, estado
  `vazio`, conversão de afinidade, *harvest*, `-Stash`, faixas de slot por tipo de branch, `Move`).
- **Corrigido — detach com submódulo:** uma branch que adicionou um submódulo e o inicializou no
  slot deixava a working tree dele como pasta não rastreada depois do detach (o `git switch` não a
  remove), e o slot ficava "sujo". Agora o detach:
  - recusa antes de qualquer efeito se o submódulo tiver alterações ou HEAD não publicado;
  - move a working tree do submódulo órfão para `<pool>/_backup/<slot>_<data>/`, com
    `RESTAURAR.txt` (nada é apagado);
  - alinha com `git submodule update` o submódulo que existe na base em outro commit;
  - avisa se o slot continuar sujo.
- **Novo — `wt.config.json`:** configuração por instalação (pool, perfis, faixas, nomes de slot,
  rótulos) num JSON ao lado dos scripts ou apontado por `WT_CONFIG`, sem editar `WtCommon.ps1`.
  Caminhos relativos à pasta do JSON; chave desconhecida é erro.
- **Novo — `ticketLabel`:** o cabeçalho da coluna do id extraído da branch é configurável.
- **Corrigido — ignorados que viravam não rastreados:** arquivos ignorados por um `.gitignore` que
  só existe na branch deixavam o slot sujo depois do detach. Agora vão para o mesmo
  `<pool>/_backup/<slot>_<data>/`; o que é ignorado também na base fica no slot.
- **Docs:** `docs/REFERENCIA.md` deixa de trazer o código (o antigo Apêndice A); `tools/wt/` é a
  fonte única. A validação manual da v3/v3.2 está preservada no README. Exemplos neutros (caminhos,
  tickets, prefixos, arquivos de configuração).
- Licença MIT.
- Testes: `tests/Test-Detach.ps1` (T1–T7), `tests/Test-Config.ps1` (C1–C6) e `tests/Test-Pool.ps1` (P1–P26, 41 verificações).
