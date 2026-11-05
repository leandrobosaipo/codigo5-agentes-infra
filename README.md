# Código5 — infraestrutura portátil de agentes

Fontes e manifests para um laboratório Linux isolado, com preparação remota em Windows/Hyper-V e evolução posterior para servidor Linux/VPS. Este repositório não contém dados, sessões ou credenciais de clientes.

Repositório canônico: [leandrobosaipo/codigo5-agentes-infra](https://github.com/leandrobosaipo/codigo5-agentes-infra).

## Escopo inicial

- Preservar o Windows e ambientes preexistentes.
- Preparar uma VM nova de laboratório sem reconfigurar a rede física, partições ou serviços alheios.
- Operações de escrita exigem opção explícita; planejamento e validação são o padrão.
- Publicar as fontes no repositório canônico antes de aplicar a configuração.
- Registrar versão, parâmetros sanitizados, objetos criados e leitura posterior.

O primeiro estágio cria somente a VM **desligada**, com disco virtual novo, sem interface de rede e sem checkpoints automáticos. Instalar e iniciar Linux, configurar rede, containers ou aplicações são estágios posteriores. A imagem oficial do sistema e seus checksums deverão ser verificados antes do boot.

## Configuração proposta do primeiro estágio

Ver `config/lab.example.json`: dois processadores virtuais, 2 GiB de RAM e VHDX dinâmico com limite de 20 GiB. O planejamento deve reservar espaço para o tamanho máximo do disco e despesas adicionais, não apenas o tamanho inicial do arquivo esparso. Manter ao menos 25 GiB livres no host após o orçamento completo. São limites de um ensaio básico, não dimensionamento da pilha completa de atendimento.

## Operação

Os scripts em `scripts/` devem documentar seus parâmetros e plano antes de aceitar aplicação. Validar sintaxe com Windows PowerShell e testar recusas sem criar VMs. Publicação do repositório não comprova que um script foi aplicado, nem que a VM ou o serviço estão prontos.

Planejamento e testes sem alterar o Hyper-V:

```powershell
.\scripts\New-LabVM.ps1
.\scripts\Test-NewLabVM.ps1
```

`New-LabVM.ps1` planeja por padrão. `-Apply` exige commit, SHA256 do próprio arquivo e da configuração, além de concordância com todos os parâmetros efetivos. A origem do commit e seus checks são conferidos pelo executor antes da chamada. [Procedimento de recuperação](scripts/RECOVERY.md).

O workflow `Validate infrastructure` executa parser e fixtures no Windows PowerShell, sem criar VMs, instalar Hyper-V ou usar credenciais de operação.

Use uma cópia do exemplo fora do Git para parâmetros locais quando ela contiver identidade de máquina, endereços ou caminhos privados. Chaves ficam no cofre/perfil administrativo adequado, nunca no repositório.

## Portabilidade e dados

Aplicações futuras devem ter Dockerfiles/manifests e dependências fixadas por versão/digest, com configuração por ambiente. Levar um serviço para VPS exige também restauração consistente dos bancos/volumes, conectores e transferência controlada do único writer/relógio. GitHub guarda fontes e histórico; não substitui backup dos dados.

Os sistemas de atendimento, conectores WhatsApp e ambientes produtivos existentes ficam fora do escopo do bootstrap. Apenas um motor de IA deve ser selecionado por piloto. Integrações reais e envios permanecem desabilitados até validação e autorização próprias.

## Status

Repositório em preparação. Conferir o histórico e os recibos privados de operação para saber o que foi efetivamente executado; este README não declara instalação no host ou em produção.
