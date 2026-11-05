# Provisionamento e retorno da VM desligada

Execute o planejamento com Windows PowerShell 5.1 no host Hyper-V. A chamada sem parâmetros lê os recursos do host e produz JSON. A suíte de fixtures usa um host simulado em memória, inclusive para os casos de recusa. O PowerShell permite consultar e gerir o Hyper-V com os cmdlets que já vêm no Windows.

```powershell
.\scripts\New-LabVM.ps1
.\scripts\Test-NewLabVM.ps1
```

O executor de publicação verifica o commit e seus checks no repositório canônico e calcula os SHA256 dos bytes do script e da configuração desse commit. Transferir os dois arquivos preservando os bytes. A opção de escrita exige os parâmetros `-Apply`, `-SourceCommit`, `-ExpectedScriptSha256`, `-ConfigPath` e `-ExpectedConfigSha256`. O script compara os valores do JSON com os parâmetros efetivos. Registre a saída final e o hash do manifesto fora do host no recibo privado da operação. A prova de origem do commit e a verificação do GitHub cabem ao executor.

O planejamento padrão exige 53 GiB livres em C:, dos quais 20 GiB cobrem o crescimento do VHDX, 8 GiB cobrem ISO e estado do runtime e 25 GiB ficam reservados ao Windows. A VM nasce desligada e desconectada. O script pode criar as pastas intermediárias do espaço de nomes do projeto. A existência da pasta final ou do nome de VM encerra uma nova tentativa antes da escrita.

Se ocorrer uma falha, preserve a pasta e consulte os recibos privados na ordem. `01-claim.json` identifica nome, pasta, SHA do script/configuração e commit. `02-disk.json` identifica o disco. `03-registration.json` identifica o ID da VM. `04-verified.json` registra a configuração conferida, o hash inicial do VHDX e a referência ao recibo anterior. Cada etapa depois da primeira registra o hash do recibo que a precedeu. Compare a cadeia com o recibo externo. O hash do disco corresponde ao instante anterior ao primeiro boot.

Para desfazer **somente o registro da VM vazia recém-criada**, confira o objeto pelo ID do recibo, nome, estado desligado, localização da configuração, caminho e identificador do VHDX, ausência de placas e de checkpoints. Confirme que a VM não foi entregue a outro uso. Havendo concordância e escopo para o retorno, desregistre somente a VM identificada, preservando o VHDX e os recibos. Confira que o ID saiu do inventário e o VHDX continua no caminho com hash esperado. Se faltar identidade, houver mudança desde a criação ou a operação se interromper entre criação e recibo, encaminhe para conferência manual. Não execute exclusão em lote, remoção recursiva ou exclusão do VHDX.
