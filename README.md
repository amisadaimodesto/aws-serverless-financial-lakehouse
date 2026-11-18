# AWS Serverless Financial Lakehouse (Terraform + LocalStack)



Um **Data Lakehouse Financeiro Serverless** orientado a eventos e com custo zero, construído com **Terraform**, **AWS Lambda (Python 3.12)**, **S3 (Arquitetura Medallion)**, **SQS + DLQ**, **DynamoDB** e **Step Functions**, executando 100% localmente via **LocalStack Community**.



## Arquitetura



```text

[Raw JSONL Batch] ──▶ S3 (Bronze) ──▶ S3 Event Notification ──▶ SQS Ingestion Queue ──▶ (DLQ on 3x failure)

                                                                       │

                                                                       ▼

                                                        Lambda: silver_processor

                                                       ┌───────────────┴───────────────┐

                                                       ▼                               ▼

                                            DynamoDB (Idempotency)          S3 (Silver / Quarantine)

                                                                                       │

                                                                                       ▼

                                                                      Step Functions: gold_workflow

                                                                                       │

                                                                                       ▼

                                                                        Lambda: gold_aggregator

                                                                                       │

                                                                                       ▼

                                                                           S3 (Gold Financial KPIs)

```



## Principais Destaques de Engenharia



* **100% Infraestrutura como Código (Terraform):** Provisionamento reproduzível de buckets S3, roles e políticas IAM com privilégio mínimo, filas SQS com Dead Letter Queue (`maxReceiveCount = 3`), tabelas DynamoDB, empacotamento de funções Lambda (`archive_file`) e fluxos no Step Functions.

* **Ingestão Idempotente:** Utiliza escritas condicionais (`attribute_not_exists(file_id)`) no DynamoDB indexadas por `bucket/key#etag` para evitar processamento duplicado em retentativas do SQS.

* **Qualidade de Dados e Quarentena:** Valida esquema, limites numéricos e moedas suportadas (`BRL`, `USD`, `EUR`), isolando registros malformados em um prefixo particionado `quarantine/` sem interromper o fluxo dos dados válidos.

* **Camada Analítica Gold:** O Step Functions orquestra a agregação de KPIs (volume bruto e aprovado, taxa de aprovação, ticket médio e alertas de alto valor) em snapshots versionados e em um resumo consolidado mais recente.



## Pré-requisitos



* Docker & Docker Compose

* Terraform (`>= 1.5.0`)

* AWS CLI v2

* `jq` e `zip`



## Guia Rápido de Execução



1. **Subir o LocalStack:**

   ```bash

   docker compose up -d

   ```



2. **Provisionar a Infraestrutura com Terraform:**

   ```bash

   terraform -chdir=terraform init

   terraform -chdir=terraform apply -auto-approve

   ```



3. **Executar a Ingestão e Validação Ponta a Ponta:**

   ```bash

   chmod +x scripts/ingest_and_test.sh

   ./scripts/ingest_and_test.sh

   ```



4. **Destruir os Recursos:**

   ```bash

   terraform -chdir=terraform destroy -auto-approve

   docker compose down

   ```



---


## Pré-requisitos



* Docker & Docker Compose

* Terraform (`>= 1.5.0`)

* AWS CLI v2

* `jq` e `zip`



## Guia Rápido de Execução



1. **Subir o LocalStack:**

   ```bash

   docker compose up -d

   ```



2. **Provisionar a Infraestrutura com Terraform:**

   ```bash

   terraform -chdir=terraform init

   terraform -chdir=terraform apply -auto-approve

   ```



3. **Executar a Ingestão e Validação Ponta a Ponta:**

   ```bash

   chmod +x scripts/ingest_and_test.sh

   ./scripts/ingest_and_test.sh

   ```



4. **Destruir os Recursos:**

   ```bash

   terraform -chdir=terraform destroy -auto-approve

   docker compose down

   ```

