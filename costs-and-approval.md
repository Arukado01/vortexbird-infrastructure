# Inventario y estimación para aprobación

Fecha: 13 de noviembre de 2026. Región prevista: `us-east-2` (Ohio). **No hay recursos creados y no hay gasto autorizado.**

## Inventario existente

Se observaron perfiles AWS configurados. `aws sts get-caller-identity` con el perfil predeterminado falló al conectar al endpoint `us-east-2.signin.aws.amazon.com/v1/token`. No se verificaron cuenta, identidad, regiones habilitadas, recursos, cuotas ni costos actuales. No es correcto interpretar este bloqueo como que la cuenta está vacía. El script de inventario incluido permite repetir la lectura sin modificar recursos.

## Recursos nuevos propuestos

| Recurso | Demo AWS | Producción |
|---|---:|---:|
| VPC, Internet Gateway | 1 | 1 |
| Subredes public/app/data | 2 por nivel | 2 por nivel |
| NAT + IPv4 pública | 1 | 2 |
| EKS control plane | 1 | 1 |
| EKS Pod Identity | Agente + asociación backend | Agente + asociación backend |
| EKS Auth interface endpoint | 1 endpoint en 2 AZ | 1 endpoint en 2 AZ |
| Nodos on-demand | 2 t3.large | 3 m7i.large iniciales |
| RDS PostgreSQL | Single-AZ t4g.micro, 30 GB | Multi-AZ t4g.medium, 30 GB iniciales |
| ElastiCache Redis | 1 t4g.micro | 2 t4g.small, failover |
| SQS eventos/DLQ | 1 + 1 | 1 + 1 |
| ECR | 2 repositorios | 2 repositorios |
| Secrets Manager | 2 app/identity + maestro RDS | Igual, rotación requerida |
| S3 reportes | 1 privado con versionado | Igual |
| WAF regional | 1 + reglas | 1 + reglas |
| ALB | 1 creado por controller después | 1 creado por controller después |
| CloudWatch | Logs, métricas y 7 alarmas | Mayor retención |

No incluye VPN/Direct Connect al ERP on-prem, dominio, soporte AWS, IVA, tráfico relevante entre AZ o transferencia a internet. El entorno local con Compose no genera cargos AWS.

## Cálculo de orden de magnitud

Supuestos: 730 horas/mes, USD, on-demand, carga baja, 30 GB de base inicial, sin descuentos/free tier. No es una cotización vinculante ni un resultado de AWS Pricing Calculator. Solo EKS y NAT tienen tarifas puntuales verificadas en páginas oficiales; las demás líneas son provisiones presupuestales que deben reemplazarse por cotizaciones regionales antes de aprobar.

| Partida mensual | Demo USD | Producción USD | Base |
|---|---:|---:|---|
| EKS | 73.00 | 73.00 | 730 × $0.10/h, soporte estándar |
| NAT (solo horas) | 32.85 | 65.70 | 730 × $0.045/h × gateways |
| EKS Auth PrivateLink | 15-25 | 15-25 | Provisión por endpoint en 2 AZ; confirmar tarifa regional y GB |
| Nodos y discos | 125–170 | 230–330 | Presupuesto a validar por SKU |
| RDS y almacenamiento | 20–45 | 110–200 | Presupuesto; producción Multi-AZ |
| Redis | 15–35 | 55–110 | Presupuesto por nodos |
| ALB/LCU, WAF, IPv4 | 35–65 | 45–110 | Depende de uso/reglas |
| Logs/métricas, secretos, ECR, S3/SQS | 20–55 | 60–150 | Depende de retención/volumen |
| **Subtotal orientativo** | **335.85-500.85** | **653.70-1063.70** | Sin rubros excluidos |
| **Reserva de presupuesto sugerida** | **400–550** | **800–1400** | Margen operativo, no límite garantizado |

NAT agrega procesamiento de datos (tarifa verificada de referencia Ohio $0.045/GB), más transferencias aplicables. EKS fuera del soporte estándar puede costar más. Autoscaling aumenta el costo; las réplicas máximas no son gratuitas.

PrivateLink factura cada AZ-hora y los GB procesados. El endpoint EKS Auth se incorporó para las credenciales temporales Pod Identity de los nodos privados. La línea es una reserva, no una tarifa Ohio verificada ni un recurso creado; debe incluirse en el plan y presupuesto sometidos a aprobación.

## Alternativas

1. **Demostración local (recomendada inicialmente):** Compose, costo AWS cero; suficiente para mostrar flujos, arquitectura y fallas. No demuestra HA real de AWS.
2. **AWS EKS demo:** mayor fidelidad a infraestructura objetivo, costo permanente del control plane y NAT; apagar nodos no elimina todos los costos. No ofrece el diseño HA de producción.
3. **ECS Fargate + servicios administrados:** evita control plane EKS y reduce carga operativa; requiere adaptar manifests/pipeline y comparar costo por vCPU/memoria. No está implementado en esta entrega.

## Aprobación pendiente

Antes de crear recursos, confirmar: cuenta/perfil de AWS, plan Terraform concreto sin modificaciones a infraestructura existente, perfil demo/production, presupuesto mensual, tiempo de vida, región habilitada, dominios propios y certificado ACM, redes administrativas, propietario de operación y alertas. Los cambios a DNS, secretos, permisos IAM o add-ons se revisan en ese plan. No se ejecutó `terraform apply`.

Fuentes oficiales consultadas:

- https://aws.amazon.com/eks/pricing/
- https://aws.amazon.com/vpc/pricing/
- https://aws.amazon.com/privatelink/pricing/
- https://aws.amazon.com/ec2/pricing/on-demand/
- https://aws.amazon.com/rds/postgresql/pricing/
- https://aws.amazon.com/elasticache/pricing/
- https://aws.amazon.com/elasticloadbalancing/pricing/
- https://calculator.aws/
- https://www.keycloak.org/server/containers
- https://www.keycloak.org/server/hostname
- https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/eks_cluster
