FROM redis:7.2-alpine@sha256:dfa18828cbc07b3ae6a95ec7343f6c214fdee2d836197b4be8e9904420762cd8

ENTRYPOINT ["redis-server", "--maxmemory-policy", "allkeys-lru", "--maxmemory", "200mb"]
