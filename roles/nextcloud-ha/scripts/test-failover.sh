#!/bin/bash
echo "🔄 Teste de Failover do Patroni Cluster"
echo "========================================"
echo ""

# Verificar estado atual
echo "Estado atual do cluster:"
patronictl -c /etc/patroni/patroni.yml list
echo ""

# Verificar VIP atual
echo "VIP atual:"
for ip in 10.0.0.10 10.0.0.11 10.0.0.12; do
    if ssh root@$ip "ip addr show wg0 2>/dev/null | grep -q 10.0.0.100" 2>/dev/null; then
        echo "  VIP está em: $ip"
        CURRENT_LEADER=$ip
    fi
done
echo ""

# Executar failover
echo "Iniciando failover..."
read -p "Digite o nome do novo líder (vps1/vps2/vps3) ou pressione Enter para eleição automática: " NEW_LEADER

if [ -n "$NEW_LEADER" ]; then
    patronictl -c /etc/patroni/patroni.yml failover nextcloud-cluster --candidate $NEW_LEADER
else
    patronictl -c /etc/patroni/patroni.yml failover nextcloud-cluster
fi

echo ""
echo "Aguardando 15 segundos para estabilização..."
sleep 15

# Verificar novo estado
echo "Novo estado do cluster:"
patronictl -c /etc/patroni/patroni.yml list
echo ""

# Verificar VIP moveu
echo "Verificando movimento do VIP:"
for ip in 10.0.0.10 10.0.0.11 10.0.0.12; do
    if ssh root@$ip "ip addr show wg0 2>/dev/null | grep -q 10.0.0.100" 2>/dev/null; then
        echo "  ✅ VIP agora está em: $ip"
        if [ "$ip" != "$CURRENT_LEADER" ]; then
            echo "  ✅ Failover do VIP funcionou!"
        fi
    fi
done
echo ""

# Testar conexão do Nextcloud
echo "Testando conexão do Nextcloud:"
NEXTCLOUD_PROJECT_PATH="${NEXTCLOUD_PROJECT_PATH:-/opt/nextcloud-docker}"
if (cd "$NEXTCLOUD_PROJECT_PATH" && docker compose -f docker-compose-garages3.yml -f docker-compose-garages3.override.yml exec -T --user www-data app php occ db:check) &>/dev/null; then
    echo "  ✅ Nextcloud conecta ao banco via VIP"
else
    echo "  ⚠️  Nextcloud pode ter problemas de conexão"
fi
