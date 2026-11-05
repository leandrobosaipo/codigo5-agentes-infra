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

## Imagem Ubuntu genérica

O workflow manual `Build Ubuntu VHDX`, executado em `main`, verifica o índice assinado da Canonical e converte uma imagem QCOW2 fixa para VHDX dinâmico em runner Ubuntu descartável. Não usa credenciais do laboratório, não inicia a imagem e não acessa nenhum host. O artifact público temporário contém somente a imagem genérica e o manifesto de origem/hashes; expira em um dia. Criar esse artifact não instala Ubuntu na VM.

Fonte fixada: [Ubuntu Noble 20261017](https://cloud-images.ubuntu.com/noble/20261017/). A impressão digital da chave Cloud está publicada no [procedimento oficial de verificação da Canonical](https://ubuntu.com/docs/public-images/public-images-how-to/verify-image-checksum/). O manifesto registra SHA do workflow, entrada assinada, hash/tamanho da saída e resultado da comparação dos discos. A etapa recusa backing files e discos acima de 20 GiB virtuais. Em pushes/PRs, roda somente uma conversão sintética pequena, com dados não nulos; o download Ubuntu exige disparo manual.

Python aqui orquestra `gpgv`/`qemu-img` e valida JSON com a biblioteca padrão do runner. Essa exceção à preferência por Rust evita introduzir compilação/dependências adicionais para um processo de preparação, mantendo a conversão no utilitário nativo apropriado.

`Set-LabUbuntuDisk.ps1` planeja por padrão. Ele verifica o ZIP/manifesto, a VM desligada e o recibo original antes de aceitar `-Apply` com SHA do script e commit de operação. Confere o VHDX com Hyper-V, amplia somente o novo disco até 20 GiB e muda o slot existente, preservando o arquivo anterior. Não cria rede nem inicia a VM. Depois de receber o ZIP, exige 49 GiB livres: 20 para crescimento do disco, 4 de runtime e 25 para o Windows. O orçamento deixa de incluir a ISO de instalador de 4 GiB porque este método usa uma imagem de disco; o ZIP já ocupa espaço no momento da medição. O seed privado pequeno permanece dentro da reserva de runtime.

## Status

Bootstrap e validações disponíveis. Conferir o histórico e os recibos privados de operação para saber o que foi efetivamente executado; este README não declara instalação no host ou em produção.
