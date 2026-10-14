apiVersion: batch/v1
kind: Job
metadata:
  name: __JOB__
  namespace: __NS__
  labels:
    app.kubernetes.io/part-of: secplat-scan
spec:
  backoffLimit: 0
  ttlSecondsAfterFinished: 3600
  template:
    spec:
      hostPID: true
      restartPolicy: Never
      containers:
        - name: kube-bench
          image: __KB_IMG__
          # nếu kube-bench không nhận diện được version Kubernetes: thêm "--benchmark", "cis-x.y"
          command: ["kube-bench", "run", "--targets", "node", "--json"]
          volumeMounts:
            - {name: kubelet, mountPath: /var/lib/kubelet, readOnly: true}
            - {name: k8s, mountPath: /etc/kubernetes, readOnly: true}
            - {name: systemd, mountPath: /etc/systemd, readOnly: true}
      volumes:
        - {name: kubelet, hostPath: {path: /var/lib/kubelet}}
        - {name: k8s, hostPath: {path: /etc/kubernetes}}
        - {name: systemd, hostPath: {path: /etc/systemd}}
