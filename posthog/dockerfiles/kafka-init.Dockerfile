FROM redpandadata/redpanda:v25.1.9@sha256:8f7e9e4c1422baaa1a5e2a6c6c668cfe05442cb3cb476542c7dff61725e6fe31

COPY --chmod=755 <<EOF /entrypoint.sh
#!/bin/bash
set -e
set -x

KAFKA_HOSTS=\${KAFKA_HOSTS:-kafka:9092}

echo "Waiting for Kafka broker to accept connections at \$KAFKA_HOSTS..."
TIMEOUT=60
ELAPSED=0
until rpk topic list --brokers "\$KAFKA_HOSTS" 2>/dev/null; do
  echo "Kafka broker not ready yet (elapsed: \${ELAPSED}s)..."
  sleep 2
  ELAPSED=\$((ELAPSED + 2))
  if [ \$ELAPSED -ge \$TIMEOUT ]; then
    echo "Timeout waiting for Kafka broker after \${TIMEOUT}s"
    echo "Final attempt to list topics:"
    rpk topic list --brokers "\$KAFKA_HOSTS" || true
    exit 1
  fi
done

echo "Kafka broker is accepting requests, creating topics..."
for topic in exceptions_ingestion clickhouse_events_json; do
  if rpk topic create "\$topic" --brokers "\$KAFKA_HOSTS" -p 1 -r 1 2>&1; then
    echo "Topic \$topic created successfully"
  else
    if rpk topic list --brokers "\$KAFKA_HOSTS" | grep -q "\$topic"; then
      echo "Topic \$topic already exists, continuing"
    else
      echo "Failed to create topic \$topic"
      exit 1
    fi
  fi
done

echo "Final topic list:"
rpk topic list --brokers "\$KAFKA_HOSTS"
echo "Topics ready"
EOF

ENTRYPOINT [ "/entrypoint.sh" ]
