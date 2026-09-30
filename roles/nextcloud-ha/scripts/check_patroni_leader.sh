#!/bin/bash
# Verifica se este nó é o líder do Patroni (para monitoramento externo)
PATRONI_API="http://localhost:8008"
LOG_FILE="/var/log/patroni-leader-check.log"

log() {
    echo "$(date): $1" >> $LOG_FILE
}

response=$(curl -sf --connect-timeout 3 $PATRONI_API 2>/dev/null)
if [ $? -ne 0 ]; then
    log "❌ Patroni API não responde"
    exit 1
fi

role=$(echo "$response" | jq -r '.role' 2>/dev/null)

if [ "$role" = "master" ] || [ "$role" = "leader" ]; then
    log "✅ Este nó é o LÍDER (role: $role)"
    exit 0
else
    log "ℹ️  Este nó é RÉPLICA (role: $role)"
    exit 1
fi
