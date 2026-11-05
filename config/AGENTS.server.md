# Regras do servidor de agentes

Estas instruções pertencem ao perfil de automação deste servidor. Leia também as regras do projeto antes de agir. Não altere instruções de outros hosts ou usuários como consequência desta configuração.

## Projetos e preservação

- Identifique raiz, remoto canônico, stack, release ativo e escopo autorizado antes de editar ou operar.
- Cada projeto próprio tem pasta e repositório GitHub separados. Reutilize componentes compartilhados por versão; não misture clientes ou copie fontes divergentes entre projetos.
- Preserve alterações alheias, histórico, dados, backups, sessões e processos. Não use a árvore inteira de um checkout sujo como release.
- Avalie Rust primeiro para código novo. Preserve integrações existentes quando uma mudança pequena na stack atual reduzir risco e manutenção.

## GitHub antes da aplicação

- Código e configuração próprios publicáveis devem estar sanitizados no repositório público correto. Chaves, credenciais, sessões, dados de cliente, dumps, uploads privados e backups ficam fora do Git e dos logs públicos.
- Versione fontes, manifests, lockfiles, migrações, testes e runbooks necessários para reproduzir a aplicação. Use branches `codex/` para mudanças de projeto.
- Antes de aplicar configuração durável ou fazer deploy, confirme o SHA no remoto canônico e os checks do mesmo commit. Falha de push, identidade ou checks retém a aplicação.
- Gere o artefato de uma fonte limpa no SHA publicado. Fixe imagens/dependências por versão ou digest e confira a configuração do destino.
- Registre repositório, SHA, hashes/digests, ambiente, objetos criados, versão anterior e readback sem valores secretos. Não confunda push, build, deploy, aceite do provedor e resultado do consumidor.

## Operação e portabilidade

- Separe laboratório e produção em volumes, bancos, usuários, credenciais, redes, filas e quotas; prove o isolamento.
- Mantenha aplicações portáveis para Linux/VPS. Configurações de ambiente vêm de arquivos privados/cofre; evite dependência de IPs ou caminhos pessoais no código.
- GitHub guarda fontes; persistência exige backup privado externo e restauração testada. Não apague originais ou dados novos para facilitar retorno.
- Preserve autorizações específicas de mensagens, agenda, financeiro e janelas de manutenção. Estar no GitHub não concede autorização para efeitos adicionais.
- Use o executor de deploy com a menor permissão necessária. Instruções não substituem gates técnicos, e administrador/root pode contornar wrappers; declare o limite observado.

Ao concluir, informe o que foi versionado, executado e verificado, os arquivos/release envolvidos e o que continua pendente. Não declare ambiente pronto com instalação, restauração ou consumidor ainda sem prova.
