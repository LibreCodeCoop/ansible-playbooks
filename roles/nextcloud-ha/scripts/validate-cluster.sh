#!/bin/bash
echo "=========================================="
echo "  Validação do Cluster Nextcloud HA"
echo "=========================================="
echo ""

# WireGuard
echo "📡 1. WireGuard Status:"
if command -v wg &> /dev/null; then
    wg show | head -20
else
    echo "   ⚠️  WireGuard não instalado"
fi
echo ""

# Conectividade
echo "🔗 2. Conectividade WireGuard:"
for ip in 10.0.0.10 10.0.0.11 10.0.0.12; do
    if ping -c 1 -W 2 $ip > /dev/null 2>&1; then
        echo "   ✅ $ip"
    else
        echo "   ❌ $ip"
    fi
done
echo ""

# VIP
echo "🎯 3. VIP Status (deve estar apenas no líder):"
if ip addr show wg0 2>/dev/null | grep -q "10.0.0.100"; then
    echo "   ✅ VIP 10.0.0.100 está ATIVO neste nó"
    echo "   ℹ️  Este nó é o LÍDER do cluster"
else
    echo "   ℹ️  VIP 10.0.0.100 NÃO está neste nó"
    echo "   ℹ️  Este nó é uma RÉPLICA"
fi
echo ""

# Patroni
echo "🗄️  4. Patroni Cluster Status:"
if command -v patronictl &> /dev/null; then
    patronictl -c /etc/patroni/patroni.yml list 2>/dev/null || echo "   ⚠️  Não foi possível conectar ao Patroni"
else
    echo "   ⚠️  patronictl não instalado"
fi
echo ""

# PostgreSQL
echo "🐘 5. PostgreSQL Replicação:"
if sudo -u postgres psql -c "SELECT pid, usename, application_name, client_addr, state FROM pg_stat_replication;" &>/dev/null; then
    sudo -u postgres psql -c "SELECT pid, usename, application_name, client_addr, state FROM pg_stat_replication;" 2>/dev/null | head -10
else
    echo "   ℹ️  Este nó pode ser uma réplica (sem pg_stat_replication)"
fi
echo ""

# Nextcloud
echo "☁️  6. Nextcloud Config:"
NEXTCLOUD_PROJECT_PATH="${NEXTCLOUD_PROJECT_PATH:-/opt/nextcloud-docker}"
COMPOSE_ARGS=(-f docker-compose-garages3.yml -f docker-compose-garages3.override.yml)
if [ -f "$NEXTCLOUD_PROJECT_PATH/docker-compose-garages3.yml" ]; then
    dbhost=$(cd "$NEXTCLOUD_PROJECT_PATH" && docker compose "${COMPOSE_ARGS[@]}" exec -T --user www-data app php occ config:system:get dbhost 2>/dev/null)
    echo "   dbhost: $dbhost"
    if [[ "$dbhost" == *"10.0.0.100"* ]]; then
        echo "   ✅ Nextcloud configurado para usar VIP"
    else
        echo "   ⚠️  Nextcloud NÃO está usando VIP"
    fi
    (cd "$NEXTCLOUD_PROJECT_PATH" && docker compose "${COMPOSE_ARGS[@]}" exec -T --user www-data app php occ status 2>/dev/null) || echo "   ⚠️  Nextcloud não respondeu"
else
    echo "   ⚠️  Nextcloud não configurado"
fi
echo ""

# Resumo
echo "=========================================="
echo "  ✅ Validação Completa"
echo "=========================================="
