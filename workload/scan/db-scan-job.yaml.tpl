apiVersion: batch/v1
kind: Job
metadata:
  name: __JOB__
  namespace: __NS__
  labels:
    app.kubernetes.io/part-of: vdt-scan
spec:
  backoffLimit: 0
  ttlSecondsAfterFinished: 3600
  template:
    spec:
      restartPolicy: Never
      containers:
        - name: db-scan
          image: __PSQL_IMG__
          env:
            - name: PGHOST
              value: "__PG_TARGET_IP__"
            - name: PGPASSWORD
              valueFrom:
                secretKeyRef: {name: pg-target, key: password}
          command: ["sh", "-c"]
          args:
            - |
              q() { psql -U postgres -Atc "$1"; }
              VER=$(q "show server_version"); SSL=$(q "show ssl"); ENC=$(q "show password_encryption")
              out=""
              add() { out="${out}${out:+,}{\"title\":\"$1\",\"severity\":\"$2\",\"description\":\"$3\"}"; }
              [ "$SSL" = "off" ] && add "PostgreSQL SSL disabled" "High" "ssl=off on $PGHOST"
              [ "$ENC" = "md5" ] && add "Weak password_encryption (md5)" "Medium" "Use scram-sha-256"
              [ "${VER%%.*}" -lt 15 ] && add "PostgreSQL outdated version $VER" "High" "Upgrade to a supported major version"
              printf '{"findings":[%s]}\n' "$out"
