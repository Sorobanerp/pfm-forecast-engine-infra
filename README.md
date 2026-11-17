# pfm-forecast-engine-infra

Repositório dedicado **1:1 de Infraestrutura como Código (IaC)** para o microsserviço `pfm-forecast-engine-go` (OpenTofu Multi-Cloud, Helm, NetworkPolicy e Alertas Prometheus para SLO de latência p99 `< 25ms`).

---

## Topologia de Portas: Local Host vs. Kubernetes Cloud

- **Host Local (`values-local.yaml`):** gRPC/HTTP `18110` (`GRPC_PORT`), Redis `16379`, Kafka `19092`.
- **Produção K8s (`values-prod.yaml`):** gRPC `9090` (Service & Container), Redis `6379`, Kafka `9092`.
