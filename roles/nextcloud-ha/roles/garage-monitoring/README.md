# garage-monitoring

Instala observabilidade específica do Garage S3:

- coleta o endpoint Prometheus administrativo do Garage;
- instala um probe S3 sintético no Node Exporter;
- mede o tempo entre o upload local e a visibilidade do objeto no peer;
- publica a configuração de scrape para um Prometheus externo.

Esta role deve ser aplicada em cada nó do grupo `nextcloud_cluster`.
O hostname usado nas métricas e no probe vem do inventário, então um nó como
`nextcloud.example.invalid` aparece no Grafana com esse nome quando a role
é executada nesse host.

O probe usa um bucket exclusivo e remove o objeto de teste ao terminar.

Para aplicar em um único nó do cluster:

```bash
ansible-playbook -i inventory.ini garage-monitoring.yml -l nextcloud.example.invalid \
  --vault-password-file .vault.pass.txt
```

Métricas principais:

- `garage_replication_probe_success`;
- `garage_replication_probe_latency_seconds`;
- `garage_replication_probe_last_run_timestamp_seconds`;
- `garage_replication_probe_upload_size_bytes`.
