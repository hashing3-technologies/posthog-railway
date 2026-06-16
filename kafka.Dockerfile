FROM confluentinc/cp-kafka:7.7.7@sha256:da2cad63aef7c80a68d46eb99f85fdaaed09dcf453e2a91ea63ffe3f9815ec00

# A Railway monta volumes como root:root, mas a imagem cp-kafka roda como
# appuser (uid 1000) — o preflight `dub path /var/lib/kafka/data writable`
# falha e o broker entra em crash-loop. Rodar como root garante escrita no
# volume persistente. Trade-off aceitável: broker interno em rede privada,
# sem exposição externa. (Causa raiz: ownership de volume da Railway, não a
# escolha cp-kafka vs Redpanda — Redpanda non-root teria o mesmo problema.)
USER root
