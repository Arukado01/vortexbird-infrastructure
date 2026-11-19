# Costos ECS Fargate — actualización operativa del 17 de noviembre de 2026

**Cuenta terminada en 1107, región Ohio (`us-east-2`). El titular autorizó subir VortexBird a AWS.** El importe y el conjunto de recursos del despliegue ECS siguen pendientes de revisión con un plan de la cuenta. El 17 de noviembre por la noche se verificó la sesión de consola. CloudShell mostró la verificación de cuenta pendiente al intentar crear su entorno. El intento de planificación desde la terminal del agente se detuvo en STS y en la carga del proveedor. El siguiente preplan de Windows puede ejecutarse con `-ReviewAwsPlan`.

Se consultaron tarifas regionales de AWS Price List Query API (`GetProducts`) con filtro `location=US East (Ohio)`, modalidad on-demand. El endpoint de Pricing utilizado está en `us-east-1`; **los productos cotizados son de Ohio**. Evidencia: `../qa/aws-ohio-pricing-2026-11-17.json`. Cálculo reproducible: `python ../qa/estimate-aws-costs.py` desde infraestructura, o `python qa/estimate-aws-costs.py` desde la raíz del proyecto.

## Escenarios comparables

Ambos incluyen identidad Keycloak y dos bases PostgreSQL privadas separadas. El piloto tiene una tarea por servicio: frontend 0.25 vCPU/0.5 GB, API 0.5/1, worker 0.5/1 e identidad 0.5/2; total 1.75 vCPU/4.5 GB. La alternativa de mayor disponibilidad duplica las cuatro tareas y usa dos NAT y dos RDS Multi-AZ `db.t4g.medium`. Requiere declarar las clases de ambas bases explícitamente; no equivale a un plan ya ejecutado.

Se suponen 730 horas/mes, Linux x86_64, 50 GB gp3 entre las dos bases, cargas bajas y réplicas mínimas. Keycloak comparte ALB/NAT sin otra IP pública. Redis TLS sigue condicionado a un grupo ACL válido; se muestra su costo cuando se habilite.

| Partida | Piloto USD/mes | Mayor disponibilidad USD/mes |
| --- | ---: | ---: |
| Fargate: frontend, API, worker y Keycloak | 66.32 | 132.63 |
| RDS PostgreSQL: aplicación e identidad separadas | 23.36 | 188.34 |
| RDS gp3: 30 GB aplicación + 20 GB identidad | 5.75 | 11.50 |
| ALB: 1 LCU piloto / 2 LCU mayor disponibilidad | 22.27 | 28.11 |
| NAT: 1 piloto / 2 mayor disponibilidad | 32.85 | 65.70 |
| IPv4 públicas: mínimo 3 / 4 | 10.95 | 14.60 |
| Secrets Manager: siete secretos | 2.80 | 2.80 |
| **Base con identidad, sin Redis** | **164.29** | **443.68** |
| **Redis opcional: uno / dos nodos** | **11.68** | **23.36** |

| Provisión según uso, no tarifa fija | Piloto USD/mes | Mayor disponibilidad USD/mes |
| --- | ---: | ---: |
| CloudWatch, Container Insights, ECR, SQS, S3 de estado y solicitudes | 20–35 | 40–70 |
| Almacenamiento adicional de respaldos | 5–10 | 10–25 |
| Datos procesados por NAT y transferencias | 10–25 | 20–60 |
| DNS | 0–1 | 0–1 |
| Tareas efímeras de migración | 0.10–1 | 0.20–2 |
| **Total con identidad, sin Redis** | **199.39–236.29** | **513.88–601.68** |
| **Total con identidad y Redis** | **211.07–247.97** | **537.24–625.04** |
| Reserva orientativa, no autorizada | 220–290 | 600–750 |

Las provisiones de tráfico, respaldo y observabilidad deben ajustarse al plan y al uso esperado. No son límites automáticos de facturación. Las tareas extra durante despliegues, autoscaling, crecimiento de discos y almacenamiento de versiones aumentan los cargos. Apagar tareas no elimina RDS, ALB, NAT ni almacenamiento.

## Tarifas verificadas

Fargate: 0.04048 USD/vCPU-h y 0.004445 USD/GB-h. RDS PostgreSQL: `db.t4g.micro` Single-AZ 0.016 USD/h; `db.t4g.medium` Multi-AZ 0.129 USD/h; gp3 0.115 USD/GB-mes Single-AZ y 0.23 Multi-AZ. Redis `cache.t4g.micro`: 0.016 USD/h, sin soporte extendido. ALB: 0.0225 USD/h y 0.008 USD/LCU-h. NAT: 0.045 USD/h y 0.045 USD/GB. IPv4: 0.005 USD/h. Secretos: 0.40 USD/secreto-mes y 0.000005 USD/solicitud.

Se excluyeron de la selección los SKU de Fargate Windows/ARM, reservas de capacidad RDS sin uso, ELB de red/gateway/Outposts y soporte extendido Redis. Esto evita comparar productos distintos con el despliegue propuesto.

## Cuenta existente y alcance

La consola mostró 103.27 USD acumulados en el mes y 187.45 USD de previsión de cierre **para la cuenta completa**, con proyectos existentes PGE/AUXO. No son costos de VortexBird ni cargos creados en esta intervención. Hay presupuestos existentes de 20 y 150 USD; ninguno autoriza el nuevo proyecto. La cuota Fargate on-demand es 12 vCPU, pero su consumo actual no se midió; no debe interpretarse como 12 vCPU libres.

Se verificaron dos clústeres ECS, cinco repositorios ECR, dos RDS privados y tres ALB de otros proyectos. No se modificaron. No se identificaron recursos VortexBird en los listados de Ohio ni nombres de secretos, stacks o roles asociados. El proveedor OIDC de GitHub existe; su confianza para los futuros repositorios VortexBird sigue sin verificar. No se reutilizarán dominio, VPC, roles, bases ni bucket ajenos sin una decisión explícita. La búsqueda GitHub no devolvió repositorios VortexBird accesibles y los repositorios locales no tienen remote.

## Exclusiones y decisión pendiente

No incluye IVA, tipo de cambio COP, compra/renovación de dominio, AWS Support, SMTP, sistemas externos, costos del proveedor de pago o GitHub Actions. Tampoco incluye KMS administrado por el cliente, créditos CPU RDS, soporte extendido, IOPS extra ni crecimiento fuera de los supuestos. Se supone un certificado público ACM no exportable, sin CA privada de pago. No se aplican créditos ni free tier como descuento garantizado.

Para pedir la única aprobación de gasto deben existir: aceptación local conectada, dominio de portal/identidad, repositorios destino y OIDC de alcance mínimo, estado remoto, imágenes inmutables, secretos preparados y un **plan real** con altas/cambios/destrucciones, duración del piloto y costo final revisable. Solo después se solicitará la decisión. No se han creado recursos facturables, publicado secretos ni ampliado permisos.

Fuentes primarias: [AWS Price List Query API](https://docs.aws.amazon.com/awsaccountbilling/latest/aboutv2/price-changes.html), [Fargate](https://aws.amazon.com/fargate/pricing/), [RDS PostgreSQL](https://aws.amazon.com/rds/postgresql/pricing/), [ElastiCache](https://aws.amazon.com/elasticache/pricing/), [ALB](https://aws.amazon.com/elasticloadbalancing/pricing/), [VPC](https://aws.amazon.com/vpc/pricing/), [Secrets Manager](https://aws.amazon.com/secrets-manager/pricing/).

La estimación anterior, incluida la alternativa histórica EKS, se conserva sin alteraciones en `../qa/history/costs-and-approval-before-document10.md`.
