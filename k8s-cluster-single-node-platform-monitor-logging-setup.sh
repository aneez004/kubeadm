#!/bin/bash

kubectl create ns efk-logging

cat <<EOF> ~/elasticsearch-template.yml
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: cm-es
data:
  elasticsearch.yml: |
    cluster.name: "es-cluster"
    network.host: 0.0.0.0
    discovery.type: single-node
    path.repo: ["/usr/share/elasticsearch"]
    xpack.security.enabled: true

---
kind: Service
apiVersion: v1
metadata:
  name: elasticsearch
  namespace: efk-logging
  labels:
    app: elasticsearch
spec:
  selector:
    app: elasticsearch
  clusterIP: None
  ports:
    - port: 9200
      name: rest
---
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: es-cluster
  namespace: efk-logging
spec:
  replicas: 1
  selector:
    matchLabels:
      app: elasticsearch
  serviceName: elasticsearch
  template:
    metadata:
      labels:
        app: elasticsearch
    spec:
      containers:
      - env:
        - name: cluster.name
          value: es-cluster
        - name: node.name
          valueFrom:
            fieldRef:
              apiVersion: v1
              fieldPath: metadata.name
        - name: ES_JAVA_OPTS
          value: -Xms512m -Xmx512m
        image: 680187043231.dkr.ecr.ap-south-1.amazonaws.com/rp-logging-stack/elasticsearch:8.4.2
        imagePullPolicy: IfNotPresent
        name: elasticsearch
        ports:
        - containerPort: 9200
          name: rest
          protocol: TCP
        - containerPort: 9300
          name: inter-node
          protocol: TCP
        resources:
          limits:
            cpu: "1"
          requests:
            cpu: 100m
        terminationMessagePath: /dev/termination-log
        terminationMessagePolicy: File
        volumeMounts:
        - mountPath: /usr/share/elasticsearch/data
          name: rp-pods-log-pvc
        - mountPath: /usr/share/elasticsearch/config/elasticsearch.yml
          name: cm-es
          subPath: elasticsearch.yml
      dnsPolicy: ClusterFirst
      initContainers:
      - command:
        - sh
        - -c
        - chown -R 1000:1000 /usr/share/elasticsearch/data
        image: 680187043231.dkr.ecr.ap-south-1.amazonaws.com/rp-official-base-techstack/busybox:stable
        imagePullPolicy: Always
        name: fix-permissions
        resources: {}
        securityContext:
          privileged: true
        terminationMessagePath: /dev/termination-log
        terminationMessagePolicy: File
        volumeMounts:
        - mountPath: /usr/share/elasticsearch/data
          name: rp-pods-log-pvc
      - command:
        - sysctl
        - -w
        - vm.max_map_count=262144
        image: 680187043231.dkr.ecr.ap-south-1.amazonaws.com/rp-official-base-techstack/busybox:stable
        imagePullPolicy: Always
        name: increase-vm-max-map
        securityContext:
          privileged: true
        terminationMessagePath: /dev/termination-log
        terminationMessagePolicy: File
      - command:
        - sh
        - -c
        - ulimit -n 65536
        image: 680187043231.dkr.ecr.ap-south-1.amazonaws.com/rp-official-base-techstack/busybox:stable
        imagePullPolicy: Always
        name: increase-fd-ulimit
        securityContext:
          privileged: true
      volumes:
      - configMap:
          name: cm-es
        name: cm-es
  updateStrategy:
    rollingUpdate:
    type: RollingUpdate
  volumeClaimTemplates:
  - apiVersion: v1
    kind: PersistentVolumeClaim
    metadata:
      labels:
        app: elasticsearch
      name: rp-pods-log-pvc
    spec:
      accessModes:
      - ReadWriteOnce
      resources:
        requests:
          storage: 50Gi
      volumeMode: Filesystem
EOF


kubectl -n efk-logging apply -f ~/elasticsearch-template.yml

sleep 15

cat <<EOF> ~/fluentd.yml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: fluentd
  namespace: efk-logging
  labels:
    app: fluentd
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: fluentd
  labels:
    app: fluentd
rules:
- apiGroups:
  - ""
  resources:
  - pods
  - namespaces
  verbs:
  - get
  - list
  - watch
---
kind: ClusterRoleBinding
apiVersion: rbac.authorization.k8s.io/v1
metadata:
  name: fluentd
roleRef:
  kind: ClusterRole
  name: fluentd
  apiGroup: rbac.authorization.k8s.io
subjects:
- kind: ServiceAccount
  name: fluentd
  namespace: efk-logging
---
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: fluentd
  namespace: efk-logging
  labels:
    app: fluentd
spec:
  selector:
    matchLabels:
      app: fluentd
  template:
    metadata:
      labels:
        app: fluentd
    spec:
      serviceAccount: fluentd
      serviceAccountName: fluentd
      tolerations:
      - key: node-role.kubernetes.io/master
        effect: NoSchedule
      containers:
      - name: fluentd
        image: 680187043231.dkr.ecr.ap-south-1.amazonaws.com/rp-logging-stack/fluentd-kubernetes-daemonset:v1.15-fluent-fluentd
        env:
          - name:  FLUENT_ELASTICSEARCH_HOST
            value: "elasticsearch.efk-logging.svc.cluster.local"
          - name:  FLUENT_ELASTICSEARCH_PORT
            value: "9200"
          - name: FLUENT_ELASTICSEARCH_SCHEME
            value: "https"
          - name: FLUENT_UID
            value: "0"
          - name: FLUENT_ELASTICSEARCH_USER
            value: "elastic"
          - name: FLUENT_ELASTICSEARCH_PASSWD
            valueFrom:
              secretKeyRef:
                name: elasticsearch-pw-elastic
                key: elastic_password
        resources:
          limits:
            memory: 512Mi
          requests:
            cpu: 100m
            memory: 200Mi
        volumeMounts:
        - name: varlog
          mountPath: /var/log
        - name: varlibdockercontainers
          mountPath: /var/lib/docker/containers
          readOnly: true
      terminationGracePeriodSeconds: 30
      volumes:
      - name: varlog
        hostPath:
          path: /var/log
      - name: varlibdockercontainers
        hostPath:
          path: /var/lib/docker/containers
EOF

kubectl -n efk-logging apply -f ~/fluentd.yml

sleep 15

cat <<EOF> ~/kibana.yml
apiVersion: v1
kind: Service
metadata:
  name: kibana
  namespace: efk-logging
  labels:
    app: kibana
spec:
  ports:
  - port: 5601
    nodePort: 30222
    targetPort: 5601
  selector:
    app: kibana
  type: NodePort
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: kibana
  namespace: efk-logging
  labels:
    app: kibana
spec:
  replicas: 1
  selector:
    matchLabels:
      app: kibana
  template:
    metadata:
      labels:
        app: kibana
    spec:
      containers:
      - name: kibana
        image: 680187043231.dkr.ecr.ap-south-1.amazonaws.com/rp-logging-stack/kibana:8.4.2
        resources:
          limits:
            cpu: 1000m
          requests:
            cpu: 100m
        env:
          - name: ELASTICSEARCH_URL
            value: http://elasticsearch:9200
          - name: ELASTICSEARCH_HOSTS
            value: http://elasticsearch:9200
          - name: XPACK_SECURITY_ENABLED
            value: "true"
          - name: ELASTICSEARCH_USERNAME
            value: "kibana"
          - name: ELASTICSEARCH_PASSWORD
            valueFrom:
              secretKeyRef:
                name: elasticsearch-pw-elastic
                key: kibana_password
        ports:
        - containerPort: 5601
        volumeMounts:
        - name: config
          mountPath: /usr/share/kibana/config/kibana.yml
          readOnly: true
          subPath: kibana.yml
      volumes:
      - name: config
        configMap:
          name: kibana-config
---
apiVersion: v1
kind: ConfigMap
metadata:
  namespace: efk-logging
  name: kibana-config
  labels:
    app: kibana
data:
  kibana.yml: |-
    server.host: 0.0.0.0
    elasticsearch:
      hosts: ${ELASTICSEARCH_URL}
      username: ${ELASTICSEARCH_USER}
      password: ${ELASTICSEARCH_PASSWORD}
EOF

kubectl apply -f ~/kibana.yml
