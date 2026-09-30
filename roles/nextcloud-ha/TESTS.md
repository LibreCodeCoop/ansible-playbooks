# Testes do Nextcloud HA

O plano de testes foi automatizado no playbook [`tests.yml`](tests.yml). Por
padrao ele executa somente verificacoes de leitura e falha assim que encontra
um componente fora do estado esperado.

## Teste geral

```bash
ansible-playbook tests.yml
```

Para executar somente um componente, use as tags `inventory`, `services`,
`wireguard`, `etcd`, `patroni`, `vip`, `postgres`, `redis`, `docker`,
`nextcloud`, `garage`, `permissions` ou `recovery`:

```bash
ansible-playbook tests.yml --tags patroni,vip,postgres
```

O endpoint publico nao faz parte da execucao padrao, pois depende de DNS e TLS
acessiveis a partir do controlador Ansible:

```bash
ansible-playbook tests.yml --tags external
```

Para ambientes com certificado de homologacao, acrescente
`-e test_validate_certs=false`.

## Failover controlado

O failover altera o estado do cluster e exige tag, confirmacao e candidato
explicitos:

```bash
ansible-playbook tests.yml --tags failover \
  -e test_allow_destructive=true \
  -e test_failover_candidate=vps2
ansible-playbook tests.yml
```

Execute-o somente em homologacao ou durante uma janela de manutencao aprovada.

## Etapas que continuam manuais

O playbook nao desliga VPS, interrompe dois membros simultaneamente, faz upload
com uma sessao de usuario, renova certificados, varre portas a partir de uma
rede externa nem restaura backups. Esses cenarios exigem infraestrutura externa
ou intervencao humana e devem continuar em um runbook de homologacao. Antes de
produzir, valide manualmente:

- sintaxe e `--check` do `site.yml`, seguidos de duas execucoes completas para
  confirmar idempotencia;
- persistencia do WireGuard apos reiniciar `wg-quick` e quorum do etcd durante
  a interrupcao temporaria de um membro;
- upload e download durante failover da camada web, PostgreSQL e Garage;
- perda progressiva de um e dois membros, fencing e ausencia de split-brain;
- exposicao externa com `nmap` a partir de outra rede;
- renovacao ACME em staging e igualdade dos certificados nos tres proxies;
- restauracao isolada do PostgreSQL e de um objeto representativo do Garage,
  medindo RPO e RTO.


# Plano de testes do Nextcloud HA

Este documento define os testes mínimos antes de considerar o cluster pronto para produção.
Os testes destrutivos devem ser executados somente em ambiente de homologação ou com janela de manutenção aprovada.

## 1. Validação do inventário e do playbook

Executar:

```bash
ansible-inventory --graph
ansible all -m ping
ansible-playbook --syntax-check site.yml
ansible-playbook --check site.yml
```

Resultado esperado: os três nós aparecem no grupo `nextcloud_cluster`, respondem ao ping e não há erros de sintaxe ou variáveis obrigatórias ausentes.

## 2. Idempotência da configuração

Executar o playbook completo duas vezes:

```bash
ansible-playbook site.yml
ansible-playbook site.yml
```

Resultado esperado: a segunda execução não altera configurações estáveis, não recria chaves, não reinicia serviços sem necessidade e não gera novos valores para `instanceid`, `secret` ou `passwordsalt`.

## 3. Conectividade e persistência do WireGuard

Em cada nó, verificar:

```bash
wg show
ip addr show wg0
ping -c 3 10.0.0.10
ping -c 3 10.0.0.11
ping -c 3 10.0.0.12
```

Reiniciar `wg-quick@wg0` e repetir as verificações. `systemctl restart wg-quick@wg0`

Resultado esperado: os três peers têm handshake recente, os endereços existem na interface correta e a conectividade continua funcionando após o reinício.

- OK

## 4. Saúde e quorum do etcd

Executar:

```bash
etcdctl --endpoints=http://10.0.0.10:2379,http://10.0.0.11:2379,http://10.0.0.12:2379 endpoint health
etcdctl --endpoints=http://10.0.0.10:2379,http://10.0.0.11:2379,http://10.0.0.12:2379 member list
```

Parar temporariamente um nó do etcd e repetir o teste.

Resultado esperado: os três membros estão saudáveis inicialmente; com a perda de um nó, os dois restantes mantêm quorum e continuam aceitando operações.

- OK: desligado 2 VPS = cluster quebrado. Ligado 2 VPS novamente = cluster saudável

## 5. Estado do cluster Patroni

Executar:

```bash
patronictl -c /etc/patroni/patroni.yml list
curl -fsS http://10.0.0.10:8008/cluster | jq
```

Resultado esperado: existe exatamente um líder, dois membros estão como réplicas e todos os membros aparecem como `running` ou estado equivalente saudável.


## 6. Redis, sessões e file locking

Em cada nó, confirmar que o Redis responde pela rede WireGuard e que o
Nextcloud está usando o mesmo endpoint em todos os nós:

```bash
source /opt/nextcloud-docker/.env
redis-cli -h 10.0.0.10 -p 6380 -a "$REDIS_HOST_PASSWORD" ping
redis-cli -h 127.0.0.1 -p 26379 sentinel get-master-addr-by-name nextcloud-redis
docker compose -f docker-compose-garages3.yml -f docker-compose-garages3.override.yml \
  exec -T --user www-data app php occ config:system:get redis host
docker compose -f docker-compose-garages3.yml -f docker-compose-garages3.override.yml \
  exec -T --user www-data app php occ config:system:get memcache.locking
```

Com uma sessão autenticada, iniciar um upload e interromper o processo em um
nó web. Repetir o acesso por outro nó e confirmar que a sessão continua válida,
que não há lock órfão e que o upload pode ser retomado ou cancelado.

Resultado esperado: Redis responde `PONG`, todos os nós usam o mesmo cache de
locks e a sessão não depende do container local.

## 7. Replicação PostgreSQL e conexão pelo VIP

No líder, criar um registro de teste e consultá-lo em uma réplica após a sincronização:

```bash
sudo -u postgres psql -d nextcloud -c "CREATE TABLE IF NOT EXISTS ha_test (id integer primary key, created_at timestamptz default now());"
sudo -u postgres psql -d nextcloud -c "GRANT SELECT ON ha_test TO nextcloud;"
sudo -u postgres psql -d nextcloud -c "INSERT INTO ha_test (id) VALUES (1) ON CONFLICT DO NOTHING;"
sudo -u postgres psql -d postgres -c "SELECT application_name, state, sync_state FROM pg_stat_replication;"
# Em uma réplica específica, não pelo VIP:
psql -h 10.0.0.12 -U nextcloud -d nextcloud -c 'SELECT * FROM ha_test;'
# Pelo VIP, confirmar que a escrita chega ao líder:
psql -h 10.0.0.100 -U nextcloud -d nextcloud -c 'SELECT * FROM ha_test;'
```

Resultado esperado: `pg_stat_replication` mostra as duas réplicas, o registro
chega diretamente à réplica e a conexão pelo VIP funciona. Não grave senhas
neste documento nem no histórico do shell.

## 8. Posicionamento, rota e migração automática do VIP

Executar em todos os nós:

```bash
ip addr show wg0 | grep 10.0.0.100
ip route get 10.0.0.100
wg show wg0
```

Depois, provocar um failover controlado:

```bash
patronictl -c /etc/patroni/patroni.yml failover nextcloud-cluster
```

Resultado esperado: o VIP existe em apenas um nó, acompanha o novo líder e
deixa de existir no líder anterior após a convergência. Nos demais nós,
`ip route get 10.0.0.100` deve apontar para o peer WireGuard que hospeda o
líder atual.

Repetir o teste provocando uma interrupção abrupta do PostgreSQL ou da VM do
líder, somente em homologação:

```bash
systemctl kill -s SIGKILL patroni
```

Medir o tempo até o novo líder, a reaparição do VIP e uma consulta bem-sucedida
em `10.0.0.100:5432`. Confirmar também que não há dois nós anunciando o VIP.

## 9. Instalação e funcionamento do Nextcloud em Docker

Em cada nó, executar:

```bash
cd /opt/nextcloud-docker
docker compose -f docker-compose-garages3.yml -f docker-compose-garages3.override.yml ps
docker compose -f docker-compose-garages3.yml -f docker-compose-garages3.override.yml exec -T --user www-data app php occ status
docker compose -f docker-compose-garages3.yml -f docker-compose-garages3.override.yml exec -T --user www-data app php occ db:check
docker compose -f docker-compose-garages3.yml -f docker-compose-garages3.override.yml exec -T --user www-data app php occ config:system:get dbhost
```

Resultado esperado: os containers `app`, `web`, `cron` e `garage` estão ativos, a verificação do banco passa e `dbhost` aponta para o VIP do PostgreSQL.

Verificar também permissões e identidade dos volumes em todos os nós:

```bash
docker compose -f docker-compose-garages3.yml -f docker-compose-garages3.override.yml \
  exec -T app sh -c 'id && stat -c "%U:%G %a %n" /var/www/html/config /var/www/html/data'
```

Resultado esperado: UID/GID e permissões são compatíveis entre os nós e não há
arquivos criados por `root` onde o PHP-FPM precise escrever.

## 10. Tráfego web, sessão e falha de um nó

Executar contra o domínio configurado:

```bash
curl -I https://nextcloud.example.invalid/status.php
dig +short A nextcloud.example.invalid
```

Fazer upload de um arquivo, provocar o failover do banco e baixar o mesmo arquivo novamente.

Parar somente o `web` ou `app` de um nó enquanto há uma sessão autenticada:

```bash
docker compose -f docker-compose-garages3.yml -f docker-compose-garages3.override.yml stop web
```

Repetir a requisição pelos demais endpoints públicos.

Resultado esperado: Nginx, TLS e PHP-FPM respondem corretamente; o tráfego é
retirado do nó indisponível, a sessão continua válida via Redis e o arquivo
permanece disponível depois do failover do banco e da camada web. Sem
ferramenta externa de failover, o DNS deve publicar os três IPs públicos e cada
IP deve responder o domínio do Nextcloud diretamente.

```bash
ansible-playbook tests.yml --tags external -e test_validate_certs=false
```

## 11. Renovação e distribuição de certificados TLS

Em cada nó, validar a configuração e simular a renovação sem substituir o
certificado ativo:

```bash
docker exec nginx-proxy nginx -t
openssl s_client -connect nextcloud.example.invalid:443 -servername nextcloud.example.invalid \
  </dev/null 2>/dev/null | openssl x509 -noout -subject -issuer -dates
curl -fsSI https://nextcloud.example.invalid/status.php
```

Confirmar que o certificado, a cadeia e a data de expiração são iguais nos
três proxies. O desafio HTTP-01 deve usar o armazenamento compartilhado ou um
balanceador que encaminhe para o nó que contém o desafio. Executar a renovação
em modo de simulação/staging conforme o cliente ACME utilizado; nunca usar um
comando de renovação real como teste de rotina.

## 12. Garage S3 e uploads grandes

Em cada nó, verificar:

```bash
cd /opt/nextcloud-docker
docker compose -f docker-compose-garages3.yml -f docker-compose-garages3.override.yml ps garage
docker compose -f docker-compose-garages3.yml -f docker-compose-garages3.override.yml exec -T garage /garage status
docker compose -f docker-compose-garages3.yml -f docker-compose-garages3.override.yml exec -T garage /garage bucket info nextcloud-data
ip link show wg0 | grep mtu
```

Testar o endpoint S3 pela rede WireGuard com uma ferramenta compatível, fazer
upload de um arquivo grande no Nextcloud e confirmar que o objeto aparece no
Garage. Derrubar um nó do Garage durante uma leitura não deve interromper o
acesso se `garage_s3_endpoint_host` apontar para um endpoint com failover.

Resultado esperado: os três nós aparecem saudáveis no Garage, os arquivos de
usuário estão no Garage e o MTU está em 1380.

Durante um upload e um download simultâneos, pare o serviço Garage em um nó:

```bash
docker compose -f docker-compose-garages3.yml -f docker-compose-garages3.override.yml stop garage
```

Confirme que o Nextcloud continua acessível e que o arquivo não retorna 404.
Depois inicie o serviço novamente e verifique a convergência com `garage
status`. Esse teste só é válido quando `garage_s3_endpoint_host` aponta para um
VIP, HAProxy ou DNS interno com failover; o IP de um único nó não é HA.

O Garage não substitui backup. Faça backup externo do bucket e continue
fazendo dump/snapshot do PostgreSQL. Teste também a restauração em um ambiente
separado.

## 13. Backup e restauração

Executar periodicamente um teste de restauração isolado:

```bash
pg_dump -h 10.0.0.100 -U nextcloud -Fc nextcloud > /tmp/nextcloud.dump
# Exportar também um objeto representativo do bucket Garage para o ambiente de teste.
```

Em um ambiente separado, restaurar o dump e o objeto, configurar o mesmo
`datadirectory`/endpoint S3 e validar login, listagem e download do arquivo.

Resultado esperado: o RPO/RTO medido atende ao objetivo definido e a
restauração não depende dos nós de produção.

## 14. Firewall, exposição externa e recuperação

De uma máquina externa, executar:

```bash
nmap -Pn -p 22,80,443,2379,2380,5432,8008 203.0.113.10
```

Depois, desligar um nó, reiniciá-lo e acompanhar seu retorno:

```bash
patronictl -c /etc/patroni/patroni.yml list
wg show
systemctl --failed
```

Resultado esperado: somente as portas públicas necessárias ficam expostas; etcd, Patroni e PostgreSQL não são acessíveis pela Internet; o nó reintegrado retorna como réplica sem tomar o papel de líder automaticamente.

## 15. Chaos test: quorum, split-brain e recuperação progressiva

Este é um teste destrutivo. Execute somente em homologação ou com uma janela
de manutenção aprovada, usando três terminais de observação independentes. Não
desligue uma VPS pela sessão SSH que será usada para coletar os resultados.

Antes de começar, registre o estado inicial e crie um arquivo com identificador
único:

```bash
date -Is
patronictl -c /etc/patroni/patroni.yml list
ETCDCTL_API=3 etcdctl --endpoints=http://10.0.0.10:2379,http://10.0.0.11:2379,http://10.0.0.12:2379 endpoint health
curl -sk -o /dev/null -w '%{http_code} %{time_total}s\n' https://nextcloud.example.invalid/status.php
```

Em uma máquina externa, manter um monitoramento contínuo e anotar os intervalos
de erro:

```bash
while true; do
  curl -sk -o /dev/null -w '%{http_code} %{time_total}s\n' \
    https://nextcloud.example.invalid/status.php
  sleep 2
done
```

### 15.1. Três para dois nós

1. Fazer upload de um arquivo de teste e registrar seu hash.
2. Desligar uma VPS por console de recuperação ou `shutdown -h now`.
3. Em cada nó sobrevivente, acompanhar `wg show`, `etcdctl endpoint health`,
   `patronictl list` e `ip addr show wg0`.
4. Repetir o upload depois da convergência.

Resultado esperado: dois membros etcd mantêm quorum; existe um único líder
Patroni; o VIP migra se o líder caiu; e o serviço retorna após o RTO definido.
Falhas transitórias devem ser registradas, não apenas observadas visualmente.

### 15.2. Dois para um nó

1. Desligar uma segunda VPS somente depois de confirmar o estado 2/3.
2. Verificar que o endpoint etcd perde quorum e que não existe um segundo
   líder Patroni.
3. Tentar login e upload no Nextcloud e registrar todas as respostas.
4. Consultar o PostgreSQL local e pelo VIP, sem criar ou aceitar dados de
   negócio durante a condição sem quorum.

Com a configuração atual (`synchronous_mode_strict: false`), não assumir que o
PostgreSQL será automaticamente encerrado apenas porque o etcd perdeu quorum:
isso deve ser medido. Se escritas forem aceitas sem DCS e sem uma política
explícita de fencing, o teste deve ser considerado falho por risco de
split-brain. O critério de aprovação é zero divergência de dados e nenhuma
escrita confirmada em dois líderes distintos.

### 15.3. Recuperação de um para dois nós

1. Ligar uma VPS e aguardar o WireGuard, o etcd e o Patroni voltarem.
2. Confirmar quorum 2/3, um único líder e o VIP em apenas um nó.
3. Repetir a leitura do arquivo criado na etapa 15.1 e comparar o hash.
4. Confirmar que o nó reintegrado volta como réplica, sem sobrescrever o líder.

### 15.4. Recuperação de dois para três nós

1. Ligar a última VPS e acompanhar sua reintegração no etcd e no Patroni.
2. Confirmar `patronictl list` com um líder e duas réplicas sincronizadas.
3. Confirmar três membros saudáveis no etcd e handshakes WireGuard recentes.
4. Executar `garage status` e verificar a convergência dos objetos do arquivo.
5. Repetir o teste HTTP e registrar o downtime total, RTO e eventual RPO.

O resultado só é aprovado quando o cluster retorna ao estado inicial sem
split-brain, corrupção, perda além do RPO acordado ou intervenção manual para
reposicionar o VIP. O Garage deve ser avaliado conforme o
`garage_replication_factor` configurado; neste inventário ele é `2`, portanto
não se deve afirmar tolerância a duas perdas sem elevar esse valor e validar a
capacidade disponível.
