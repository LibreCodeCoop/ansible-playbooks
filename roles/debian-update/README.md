# debian-update

## Reinicialização (aprovação explícita)

A role executa `apt upgrade: dist` e limpeza de pacotes, podendo alterar serviços durante a atualização. Por padrão, **não reinicia o host** mesmo quando `/var/run/reboot-required` existe; informa a pendência no resultado. Planeje a janela e o rollback e obtenha autorização específica para o host antes de executar com `-e debian_update_allow_reboot=true`. Essa variável permite o reboot dentro da mesma execução; não autoriza automaticamente novas execuções ou outros hosts.
