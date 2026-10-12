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
        - name: trivy
          image: __TRIVY_IMG__
          args: ["image", "--quiet", "--format", "json", "--scanners", "vuln,secret", "__IMAGE__"]
