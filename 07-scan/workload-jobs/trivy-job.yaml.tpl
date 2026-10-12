# Trivy image scan - 1 Job/image (WORKLOAD cluster, ns security-scan)
# Template: orchestrator thay ${JOB_NAME}, ${SCAN_IMAGE}. Chạy tay:
#   JOB_NAME=trivy-test SCAN_IMAGE=nginx:1.14.2 envsubst '${JOB_NAME} ${SCAN_IMAGE}' < trivy-job.yaml.tpl | kubectl apply -f -
apiVersion: batch/v1
kind: Job
metadata:
  name: ${JOB_NAME}
  namespace: security-scan
  labels: {app.kubernetes.io/part-of: vdt-scan, scanner: trivy}
spec:
  backoffLimit: 0
  ttlSecondsAfterFinished: 3600
  template:
    metadata:
      labels: {scanner: trivy}
    spec:
      restartPolicy: Never
      containers:
      - name: trivy
        image: aquasec/trivy:latest          # nên pin version
        args: ["image", "--quiet", "--format", "json", "--scanners", "vuln", "${SCAN_IMAGE}"]
