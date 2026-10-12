# Grafana trên ADMIN cluster - NodePort 32000, datasource Loki + DB của DefectDojo
# Template: cần GRAFANA_PASS và DOJO_DB_PASS (cài SAU DefectDojo):
#   export GRAFANA_PASS='<đặt-mật-khẩu>'
#   export DOJO_DB_PASS=$(kubectl -n defectdojo get secret defectdojo-postgresql-specific -o jsonpath='{.data.postgresql-password}' | base64 -d)
#   envsubst '${GRAFANA_PASS} ${DOJO_DB_PASS}' < 05-admin-apps/grafana/values.yaml.tpl > /tmp/grafana-values.yaml
#   helm upgrade --install grafana grafana/grafana -n monitoring --create-namespace -f /tmp/grafana-values.yaml
adminPassword: "${GRAFANA_PASS}"
service: {type: NodePort, nodePort: 32000}
datasources:
  datasources.yaml:
    apiVersion: 1
    datasources:
    - name: Loki
      type: loki
      access: proxy
      url: http://loki-gateway.logging.svc.cluster.local
    - name: DefectDojo
      type: postgres
      url: defectdojo-postgresql.defectdojo.svc.cluster.local:5432
      user: defectdojo
      secureJsonData: {password: "${DOJO_DB_PASS}"}
      jsonData: {database: defectdojo, sslmode: disable, postgresVersion: 1500}
