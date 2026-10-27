#!/usr/bin/env bash
set -euo pipefail

# Migrates Sonarr, Radarr, Lidarr, and Prowlarr SQLite databases (/config/<app>.db)
# to the shared CloudNativePG PostgreSQL cluster after the apps have booted once
# with Postgres configured (so their target schemas exist).

NAMESPACE="media"
PG_HOST="postgres-rw.postgres.svc.cluster.local"
PG_PORT="5432"
PG_USER="media"
if [ "$#" -gt 0 ]; then
  APPS=("$@")
else
  APPS=("sonarr" "radarr" "lidarr" "prowlarr")
fi

for app in "${APPS[@]}"; do
  echo "=================================================================="
  echo "🚀 Migrating ${app} (/config/${app}.db -> ${app}-main)..."
  echo "=================================================================="

  echo "⏸️  Scaling down deployment/${app} to 0..."
  kubectl scale deployment "${app}" -n "${NAMESPACE}" --replicas=0
  kubectl wait --for=delete pod -l "app.kubernetes.io/name=${app}" -n "${NAMESPACE}" --timeout=120s || true

  POD_NAME="pgloader-${app}"
  kubectl delete pod "${POD_NAME}" -n "${NAMESPACE}" --ignore-not-found

  echo "📦 Running pgloader for ${app}..."
  kubectl apply -f - <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: ${POD_NAME}
  namespace: ${NAMESPACE}
spec:
  restartPolicy: Never
  nodeSelector:
    kubernetes.io/hostname: k8s-prod-cp-1
  containers:
    - name: pgloader
      image: ghcr.io/roxedus/pgloader:latest
      command:
        - /bin/sh
        - -c
        - |
          set -e
          if [ ! -f "/config/${app}.db" ]; then
            echo "⚠️  /config/${app}.db not found, skipping."
            exit 0
          fi
          cp /config/${app}.db* /tmp/
          pgloader \
            --with "quote identifiers" \
            --with "data only" \
            --with "truncate" \
            --with "reset sequences" \
            --with "prefetch rows = 100" \
            --with "batch size = 1MB" \
            "/tmp/${app}.db" \
            "postgresql://${PG_USER}:\${POSTGRES_PASSWORD}@${PG_HOST}:${PG_PORT}/${app}-main"
      env:
        - name: POSTGRES_PASSWORD
          valueFrom:
            secretKeyRef:
              name: media-secret
              key: POSTGRES_PASSWORD
      volumeMounts:
        - name: config
          mountPath: /config
          readOnly: true
  volumes:
    - name: config
      persistentVolumeClaim:
        claimName: ${app}-pvc
EOF

  echo "⏳ Waiting for ${POD_NAME} to start..."
  kubectl wait --for=condition=Ready "pod/${POD_NAME}" -n "${NAMESPACE}" --timeout=120s || true
  kubectl logs -f "${POD_NAME}" -n "${NAMESPACE}"

  kubectl wait --for=jsonpath='{.status.phase}'=Succeeded "pod/${POD_NAME}" -n "${NAMESPACE}" --timeout=30s
  kubectl delete pod "${POD_NAME}" -n "${NAMESPACE}"

  echo "▶️  Scaling deployment/${app} back to 1..."
  kubectl scale deployment "${app}" -n "${NAMESPACE}" --replicas=1
  echo "✅ ${app} migration complete!"
done

echo "🎉 All *arr databases migrated to PostgreSQL!"
