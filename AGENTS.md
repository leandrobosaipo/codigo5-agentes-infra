# Regras do projeto de infraestrutura dos agentes

## Escopo

Este repositório contém somente fontes próprias sanitizadas, manifests e documentação de infraestrutura. Cada produto/cliente tem seu projeto separado; reutilize componentes por versão. Não copie históricos privados, sessões, credenciais ou arquivos pessoais para esta árvore ou para logs públicos.

## Trabalho

- Antes de agir, confira raiz, remoto, estado Git, fonte efetiva e escopo autorizado. Preserve alterações alheias.
- Avalie Rust para código novo. Para administrar Hyper-V, PowerShell com cmdlets nativos é uma exceção justificada pela compatibilidade e menor superfície de mudança.
- Scripts planejam por padrão e exigem opção explícita para escrever. Recuse objetos existentes ou identidade ambígua; não adote nem sobrescreva uma VM por nome.
- Leia o estado real antes de criar diretórios, VMs, discos, redes ou serviços. Não altere partições, rede física, firmware, WSL ou cargas existentes para completar um bootstrap.
- Confirme folga de disco com reserva do tamanho máximo dos discos virtuais e do runtime; interrompa antes de criar objetos se o limite falhar.
- Teste sintaxe e casos de recusa com fixtures ou mocks; mantenha testes sem efeitos em Hyper-V. Não fabrique prova com dados ou clientes reais.

## Publicação e execução

- Antes de executar uma alteração no host, confirme que suas fontes e configuração publicável estão enviadas ao repositório canônico. Use checkout limpo do commit escolhido.
- Segredos são injetados por canal privado; exemplos contêm somente placeholders seguros. Conteúdo sensível fora do Git requer backup e restauração próprios.
- Fixe os digests das imagens quando houver containers. Registre commit, hashes, parâmetros sem segredos, objetos criados e versão ativa observada.
- Uma chave com privilégio administrativo serve ao bootstrap autorizado; não implica permissão permanente para contornar futuros gates de deploy.
- Reversão inicial preserva VHDX e dados: pare/desconecte apenas objetos comprovadamente criados por este projeto. Exclusão exige escopo e prova próprios.
- Informe o que foi planejado, publicado e executado separadamente; sucesso de Git/PowerShell ou VM cadastrada não comprova serviço funcional.
