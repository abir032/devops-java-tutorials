# AWS Infrastructure Guide (Terraform)

Deploys Order Desk on AWS with **two VPCs joined by VPC peering**, built from the Terraform code in
[`infra/`](../infra/). The app images are built **on each server** (no image registry).

## Contents

1. [Overview](#1-overview)
2. [Architecture and address plan](#2-architecture-and-address-plan)
3. [Networking](#3-networking)
4. [Security](#4-security)
5. [Compute and data](#5-compute-and-data)
6. [Terraform layout](#6-terraform-layout)
7. [Build it step by step](#7-build-it-step-by-step)
8. [Deploy the app](#8-deploy-the-app)
9. [Verify](#9-verify)
10. [Costs, pause and destroy](#10-costs-pause-and-destroy)
11. [Troubleshooting](#11-troubleshooting)

---

## 1. Overview

| VPC | CIDR | Holds |
| --- | --- | --- |
| **App VPC** | `10.10.0.0/16` | public **frontend** subnet (`web`, `nat`) and private **backend** subnet (`backend-1`, `backend-2`) |
| **DB VPC** | `10.30.0.0/16` | RDS MariaDB, ElastiCache Redis, Amazon MQ RabbitMQ. **No internet gateway.** |

- `web` runs the `od-frontend` container (nginx). It serves the React build and load-balances `/api`
  to both backends.
- The backends run the `od-backend` container (Spring Boot, port 8080) and read their settings from
  SSM Parameter Store through an IAM role.
- A **NAT instance** gives the private backends internet access (apt, Docker Hub, Maven Central).
- The data tier is reachable **only** from the backend subnet `10.10.2.0/24`, across the peering.

Compared with the local Docker setup in [SETUP.md](SETUP.md): Compose networks become VPCs, the three
data containers become managed services, and the `backend` DNS name becomes two fixed private IPs.

**One request, end to end**

1. The browser (from `my_ip` only) calls `http://<web public IP>/`; nginx returns the React build.
2. The page calls `/api/v1/...` on the same host (`VITE_API_URL` is empty, so there is no CORS).
3. nginx forwards `/api` to `10.10.2.11:8080` or `10.10.2.12:8080`.
4. The backend reads Redis (`X-Cache: HIT/MISS`), MariaDB, and publishes orders to RabbitMQ over TLS.
5. A listener on one of the backends processes the order and updates MariaDB.

## 2. Architecture and address plan

```
                  Internet (my_ip only)
                     │ HTTP :80, SSH :22
┌────────────────────▼──────── App VPC 10.10.0.0/16 ───────────────────────┐
│ frontend subnet 10.10.1.0/24 (public)                                    │
│   web: od-frontend (nginx :80, upstream pool)          nat: MASQUERADE   │
│        │ /api → :8080                                        ▲           │
│ backend subnet 10.10.2.0/24 (private)                        │ 0.0.0.0/0 │
│   backend-1 10.10.2.11     backend-2 10.10.2.12 ─────────────┘           │
└──────────────┬───────────────────────────────────────────────────────────┘
               │ VPC peering: 3306, 6379, 5671
┌──────────────▼──────── DB VPC 10.30.0.0/16 (no IGW) ─────────────────────┐
│ db-a 10.30.1.0/24 (AZ a): RDS, ElastiCache, Amazon MQ                    │
│ db-b 10.30.2.0/24 (AZ b): subnet groups only                             │
└──────────────────────────────────────────────────────────────────────────┘
```

| Network | CIDR | AZ | Holds |
| --- | --- | --- | --- |
| frontend subnet (public) | `10.10.1.0/24` | a | web, nat |
| backend subnet (private) | `10.10.2.0/24` | a | backend-1 `.11`, backend-2 `.12` |
| db-a (private) | `10.30.1.0/24` | a | RDS, ElastiCache, Amazon MQ |
| db-b (private) | `10.30.2.0/24` | b | subnet groups only (RDS and ElastiCache need 2 AZs) |

The VPC CIDRs must not overlap (a peering rule). Every subnet is computed with
`cidrsubnet(cidr, 8, n)` from the two variables in `variables.tf`.

## 3. Networking

| Route table | Subnets | Routes |
| --- | --- | --- |
| `orderdesk-frontend-rt` | frontend | local, `0.0.0.0/0 → igw` |
| `orderdesk-backend-rt` | backend | local, `10.30.0.0/16 → pcx`, `0.0.0.0/0 → nat ENI` |
| `orderdesk-db-rt` | db-a, db-b | local, `10.10.2.0/24 → pcx` |

- **Peering** ([peering.tf](../infra/peering.tf)): same account and region, so `auto_accept = true`.
  `allow_remote_vpc_dns_resolution` is on for both sides, so the RDS, ElastiCache and MQ names
  resolve to private IPs from the App VPC.
- **NAT instance** ([nat.tf](../infra/nat.tf), [nat_user_data.sh.tftpl](../infra/nat_user_data.sh.tftpl)):
  `source_dest_check = false`, `ip_forward=1` and an iptables MASQUERADE rule for `10.10.2.0/24`.
- Only the backend route table points at the DB VPC. `web` has no route there, so even a wrong
  security group could not expose the database.
- The backends depend on `aws_route.backend_default`, because their boot script needs the internet.

### 3.1 How VPC peering works

A peering connection is a private link between two VPCs. Traffic stays on the AWS network: no internet
gateway, NAT or VPN is involved, and there is no extra device to size or patch. Here
`aws_vpc_peering_connection.app_db` links the App VPC (requester) and the DB VPC (accepter). After
acceptance the roles no longer matter, and traffic flows both ways.

The peering alone carries nothing. Four things must all be in place:

| Layer | In the Terraform | Role |
| --- | --- | --- |
| Connection | `aws_vpc_peering_connection.app_db` | the link (`pcx-...`); `auto_accept = true` because both VPCs share an account and region |
| Route, App side | `aws_route.backend_to_db` | backend table: `10.30.0.0/16 → pcx` |
| Route, DB side | `aws_route.db_to_backend` | DB table: `10.10.2.0/24 → pcx`, so replies can return |
| Security group rule | `rds`, `redis`, `mq` SGs | allow `10.10.2.0/24` on 3306, 6379 and 5671 |

**A backend talking to RDS**

```
1. DNS      orderdesk-db...rds.amazonaws.com → 10.30.1.x   (private only with the DNS option below)
2. Route    backend-rt: 10.30.0.0/16 → pcx                  packet crosses into the DB VPC
3. Guard    rds-sg: 3306 from 10.10.2.0/24                  allowed
4. Reply    db-rt: 10.10.2.0/24 → pcx                       reply crosses back (SGs are stateful)
```

Both route tables are needed, because without the DB-side route the requests arrive and the replies
are lost.

**Rules and limits**

| Rule | Meaning here |
| --- | --- |
| No overlapping CIDRs | `10.10.0.0/16` and `10.30.0.0/16` are separate; overlapping ranges make the peering `failed` |
| Not transitive | A third VPC peered to the App VPC could not reach the DB VPC through it |
| No gateway sharing | The DB VPC cannot use the App VPC's IGW or NAT, which is why it has no internet at all |
| Routes are manual | Peering does not edit route tables; the two `aws_route` resources do |
| Same account and region | `auto_accept = true`; otherwise the other side needs `aws_vpc_peering_connection_accepter` |

**DNS.** Private DNS does not cross a peering by default. `aws_vpc_peering_connection_options.dns` sets
`allow_remote_vpc_dns_resolution` on both sides, so the RDS, ElastiCache and MQ names resolve to
`10.30.x.x` from the App VPC. Without it the names can resolve to public addresses and the
connection times out in a VPC with no gateway.

**Why the routes are narrow.** Only the backend route table points at the DB VPC, and the DB side
routes back to `10.10.2.0/24` only. The data tier then has three independent layers: no gateway,
routes for the backend subnet only, and security groups limited to three ports. A compromised `web`
server has no route to it.

**Alternatives.** Transit Gateway suits many VPCs or on-premises networks (hourly fee, transitive
routing). PrivateLink exposes a single service without opening whole networks. For two VPCs, peering is
the simplest choice and the connection itself is free.

**Cost.** The peering has no hourly fee. Cross-AZ traffic costs about $0.01/GB; the backends and data
tier mostly share AZ a, so the charge is small.

**Check it**

```bash
aws ec2 describe-vpc-peering-connections --filters "Name=tag:Name,Values=orderdesk-app-to-db" \
  --query "VpcPeeringConnections[].[Status.Code,RequesterVpcInfo.CidrBlock,AccepterVpcInfo.CidrBlock]" --output table
aws ec2 describe-route-tables --filters "Name=tag:Name,Values=orderdesk-backend-rt" \
  --query "RouteTables[].Routes[].[DestinationCidrBlock,VpcPeeringConnectionId]" --output text
```

Expected: `active 10.10.0.0/16 10.30.0.0/16` and a `10.30.0.0/16 pcx-...` route.

| Common mistake | Symptom |
| --- | --- |
| Route on one side only | connections hang; replies are lost |
| Overlapping CIDRs | status `failed` |
| Missing SG rule | timeouts although routes are correct |
| DNS option off | endpoint resolves to a public address or times out |
| `0.0.0.0/0 → pcx` | breaks outbound routing; peering does not carry internet traffic |

## 4. Security

Every path needs a route **and** a security group rule.

| Security group | VPC | Inbound | Outbound |
| --- | --- | --- | --- |
| `orderdesk-web-sg` | App | 22, 80 from `my_ip` | all |
| `orderdesk-nat-sg` | App | all from `10.10.2.0/24` | all |
| `orderdesk-backend-sg` | App | 8080, 22 from the web SG | all |
| `orderdesk-rds-sg` | DB | 3306 from `10.10.2.0/24` | none |
| `orderdesk-redis-sg` | DB | 6379 from `10.10.2.0/24` | none |
| `orderdesk-mq-sg` | DB | 5671 from `10.10.2.0/24` | none |

The data rules use a CIDR, not an SG reference, because the backend SG lives in another VPC.

| From → to | Allowed | Why |
| --- | --- | --- |
| your IP → web :80, :22 | yes | web SG |
| web → backends :8080, :22 | yes | backend SG references the web SG |
| backends → internet | yes | default route to NAT |
| backends → RDS, Redis, MQ | yes | peering routes on both sides + data SGs |
| web → data tier | no | no route in the frontend table |
| internet → backends or data tier | no | private IPs, no IGW in the DB VPC |

**Identity and secrets**

- `orderdesk-backend-role` (backends only) allows `ssm:GetParameter` on five exact parameters:
  `/orderdesk/db/endpoint`, `db/app_password`, `redis/endpoint`, `mq/endpoint`, `mq/password`.
  The DB master password is **not** in SSM; read it with `terraform output -raw db_master_password`.
- Passwords come from `random_password` and are also in the S3 state file, so the state bucket must
  stay private, encrypted and versioned.
- All instances enforce IMDSv2 and use encrypted gp3 root volumes. SSH reaches the backends only
  through `web` (`ProxyJump`); the private key never leaves your Mac.

## 5. Compute and data

| Name | Type | Subnet | Public IP | Notes |
| --- | --- | --- | --- | --- |
| `orderdesk-web` | t3.micro | frontend | yes | Docker, `od-frontend` |
| `orderdesk-backend-1`, `-2` | t3.small | backend | no | Docker, `od-backend`, IAM role, fixed IPs `.11` and `.12` |
| `orderdesk-nat` | t3.micro | frontend | yes | NAT |
| `orderdesk-db` | db.t4g.micro, MariaDB 11.4 | db-a / db-b group | no | database `orderdesk`, admin `dbadmin` |
| `orderdesk-redis` | cache.t4g.micro, Redis 7.1 | db-a / db-b group | no | one node, no TLS |
| `orderdesk-mq` | mq.m7g.medium, RabbitMQ 4.2 | db-a | no | single instance, TLS on 5671 |

Instance type choices (this account is on the Free Tier plan):

- `t3.nano` is not Free Tier eligible, so the NAT uses `t3.micro`. List allowed types with
  `aws ec2 describe-instance-types --filters Name=free-tier-eligible,Values=true`.
- The backends use `t3.small` because a Maven build and a JVM do not fit well in 1 GB.
- Keep the amd64 Ubuntu AMI. The `t4g` EC2 types are ARM and would not match it.
- `mq.t3.micro` is ActiveMQ only. RabbitMQ 4.x needs `mq.m7g.*` (check with
  `aws mq describe-broker-instance-options --engine-type RABBITMQ`).
- RDS 11.4 is used instead of the 11.8 in `docker-compose.yml`; check the available versions with
  `aws rds describe-db-engine-versions --engine mariadb`.

**Boot script** ([server_user_data.sh](../infra/server_user_data.sh)): adds 1 GB swap, installs git,
jq, mariadb-client, netcat, Docker CE with the compose plugin and the AWS CLI, then writes
`/var/tmp/user-data-done`. `user_data_replace_on_change = true`, so editing a script replaces the
server.

**Backend settings.** The same Spring variables as in [SETUP.md](SETUP.md#32-backendenvdocker-options-bc)
are written to `backend/.env.aws` on each backend from SSM. Differences from Compose:
`SPRING_RABBITMQ_PORT=5671`, `SPRING_RABBITMQ_SSL_ENABLED=true`, and a named MQ user (Amazon MQ
does not allow `guest`).

## 6. Terraform layout

One root module in `infra/`. State is in S3 (key `orderdesk/terraform.tfstate`, native lockfile),
AWS provider `~> 6.0`, Terraform `>= 1.10`.

| File | Holds |
| --- | --- |
| `versions.tf`, `providers.tf` | versions, S3 backend, provider, `default_tags` (`Project`, `ManagedBy`) |
| `variables.tf` | `project`, `region`, `my_ip` (validated `/32`), `ssh_public_key_path`, two VPC CIDRs |
| `network-app.tf` | AZ lookup, App VPC, IGW, 2 subnets, 2 route tables and associations |
| `network-db.tf` | DB VPC, 2 subnets, route table and associations |
| `peering.tf` | peering, DNS options, 2 routes |
| `security.tf` | 6 security groups and their rules |
| `compute-common.tf` | AMI lookup, key pair, backend IAM role, policy, instance profile |
| `nat.tf` + `nat_user_data.sh.tftpl` | NAT instance and the backend default route |
| `database.tf` | passwords, RDS, ElastiCache, Amazon MQ, 5 SSM parameters |
| `servers.tf` + `server_user_data.sh` | web and 2 backends |
| `outputs.tf` | IPs, sensitive master password, rendered `ssh_config` |

`terraform.tfvars` (only `my_ip`) is git-ignored. `.terraform.lock.hcl` is committed.

## 7. Build it step by step

Each step ends with `terraform fmt && terraform validate && terraform plan`, then `terraform apply`.

| Step | Files | What it builds |
| --- | --- | --- |
| 0 | by hand | tools, SSH key `~/.ssh/orderdesk-key`, state bucket, `.gitignore` |
| 1 | `versions.tf`, `providers.tf`, `variables.tf` | settings, `terraform init` |
| 2 | `network-app.tf` | App VPC, IGW, subnets, route tables |
| 3 | `network-db.tf` | DB VPC with no gateway |
| 4 | `peering.tf` | peering, DNS resolution, one route per side |
| 5 | `security.tf` | the 6 security groups |
| 6 | `compute-common.tf`, `nat.tf` | key pair, NAT, backend default route |
| 7 | `database.tf` | RDS, ElastiCache, Amazon MQ, SSM parameters (the broker takes 15 to 20 minutes) |
| 8 | `compute-common.tf`, `servers.tf`, `outputs.tf` | IAM role, web and backends |

Prerequisites (step 0):

```bash
terraform -version                 # 1.10 or newer
aws sts get-caller-identity
ssh-keygen -t ed25519 -f ~/.ssh/orderdesk-key -C "orderdesk"
cd infra && echo "my_ip = \"$(curl -s https://checkip.amazonaws.com)/32\"" > terraform.tfvars
terraform init
```

**SSH setup (once, and after every rebuild):**

```bash
terraform output -raw ssh_config > ~/.ssh/config.d-orderdesk
touch ~/.ssh/config
grep -qxF 'Include ~/.ssh/config.d-orderdesk' ~/.ssh/config || {
  printf 'Include ~/.ssh/config.d-orderdesk\n\n' | cat - ~/.ssh/config > ~/.ssh/config.tmp &&
  mv ~/.ssh/config.tmp ~/.ssh/config
}
```

Public IPs change on every stop/start or rebuild, so regenerate the file each time.

## 8. Deploy the app

Run from the repo root on your Mac. The servers clone the repo over plain `https`, so it must be
public (a private repo needs a deploy key on each server).

```bash
OWNER_REPO=$(git remote get-url origin | sed -E 's#^[^:]+:##; s#^https://[^/]+/##; s#\.git$##')
REPO="https://github.com/${OWNER_REPO}.git"
git ls-remote "$REPO" | head -2
```

**8.1 Create the app user in RDS.** Flyway needs DDL rights, because Hibernate only validates.

```bash
MASTER=$(cd infra && terraform output -raw db_master_password)

ssh orderdesk-backend-1 "MYSQL_PWD='$MASTER' bash -s" <<'EOF'
set -euo pipefail
H=$(aws ssm get-parameter --name /orderdesk/db/endpoint --query Parameter.Value --output text)
APP=$(aws ssm get-parameter --name /orderdesk/db/app_password --with-decryption --query Parameter.Value --output text)
mariadb -h "$H" -u dbadmin -e "
  CREATE USER IF NOT EXISTS 'orderdesk'@'%' IDENTIFIED BY '$APP';
  ALTER USER 'orderdesk'@'%' IDENTIFIED BY '$APP';
  GRANT ALL PRIVILEGES ON orderdesk.* TO 'orderdesk'@'%';"
EOF
```

**8.2 Backends** (repeat for `orderdesk-backend-1` and `orderdesk-backend-2`):

```bash
for h in orderdesk-backend-1 orderdesk-backend-2; do
  ssh $h "REPO=$REPO bash -s" <<'EOF'
set -euo pipefail
cd ~
[ -d app ] || git clone "$REPO" app
cd app && git pull --ff-only

get() { aws ssm get-parameter --with-decryption --name "/orderdesk/$1" --query Parameter.Value --output text; }

umask 077
cat > backend/.env.aws <<ENV
SPRING_DATASOURCE_URL=jdbc:mariadb://$(get db/endpoint):3306/orderdesk
SPRING_DATASOURCE_USERNAME=orderdesk
SPRING_DATASOURCE_PASSWORD=$(get db/app_password)
SPRING_DATA_REDIS_HOST=$(get redis/endpoint)
SPRING_RABBITMQ_HOST=$(get mq/endpoint)
SPRING_RABBITMQ_PORT=5671
SPRING_RABBITMQ_SSL_ENABLED=true
SPRING_RABBITMQ_USERNAME=orderdesk
SPRING_RABBITMQ_PASSWORD=$(get mq/password)
JAVA_TOOL_OPTIONS=-XX:MaxRAMPercentage=70
ENV

docker build -q -t od-backend:v1 backend
docker rm -f backend 2>/dev/null || true
docker run -d --name backend --env-file backend/.env.aws -p 8080:8080 --restart unless-stopped od-backend:v1

for i in $(seq 40); do curl -sf localhost:8080/actuator/health/readiness && break; sleep 5; done
echo
EOF
done
```

The environment variables map onto `application.properties` through Spring's relaxed binding, so the
same image runs locally, in Compose and on AWS.

**8.3 Web.** The repo's `frontend/nginx.conf` uses the Docker DNS name `backend`, which does not
exist across servers, so an AWS-specific config is mounted over it.

```bash
ssh orderdesk-web "REPO=$REPO bash -s" <<'EOF'
set -euo pipefail
cd ~
[ -d app ] || git clone "$REPO" app
cd app && git pull --ff-only

docker build -q -t od-frontend:v1 --build-arg VITE_API_URL= frontend

cat > ~/nginx.aws.conf <<'NGINX'
upstream orderdesk_backend {
    server 10.10.2.11:8080;
    server 10.10.2.12:8080;
}

server {
    listen 80;
    root /usr/share/nginx/html;
    index index.html;

    location / {
        try_files $uri /index.html;
    }

    location /api/ {
        proxy_pass http://orderdesk_backend;
        proxy_set_header Host $host;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    }
}
NGINX

docker rm -f frontend 2>/dev/null || true
docker run -d --name frontend -p 80:80 \
  -v ~/nginx.aws.conf:/etc/nginx/conf.d/default.conf:ro \
  --restart unless-stopped od-frontend:v1
docker exec frontend nginx -t
EOF
```

`/actuator` is not proxied, so health details stay private.

## 9. Verify

**Network (about 3 minutes after the apply)**

```bash
ssh orderdesk-web "cloud-init status --wait; cat /var/tmp/user-data-done"
ssh orderdesk-backend-1 "cloud-init status --wait; curl -s https://checkip.amazonaws.com"   # prints the NAT's public IP
ssh orderdesk-backend-1 '
  for n in db/endpoint redis/endpoint mq/endpoint; do
    H=$(aws ssm get-parameter --name /orderdesk/$n --query Parameter.Value --output text)
    echo "$n -> $(getent hosts $H | cut -d" " -f1)"
  done'
ssh -o ConnectTimeout=5 -i ~/.ssh/orderdesk-key ubuntu@10.10.2.11 || echo "no direct way in (good)"
```

Expected: the boot marker, the NAT's IP, three `10.30.x.x` addresses, and a timeout on the direct SSH.

**App**

```bash
WEB_IP=$(cd infra && terraform output -raw web_public_ip)

curl -s -D - -o /dev/null http://$WEB_IP/api/v1/products | grep -i x-cache      # MISS
curl -s -D - -o /dev/null http://$WEB_IP/api/v1/products | grep -i x-cache      # HIT

curl -s -X POST http://$WEB_IP/api/v1/orders -H "Content-Type: application/json" \
  -d '{"productId":1,"quantity":2}' | jq                                        # 202, PENDING
sleep 5; curl -s http://$WEB_IP/api/v1/orders | jq '.[0]'                       # CONFIRMED, processedBy set

for i in $(seq 10); do curl -s -o /dev/null -D - http://$WEB_IP/api/v1/products | grep -i x-instance; done | sort | uniq -c
```

Expected: `MISS` then `HIT`, the order moving from `PENDING` to `CONFIRMED`, and roughly half of the
requests on each backend hostname.

**Failover**

```bash
ssh orderdesk-backend-2 "docker stop backend"
for i in $(seq 6); do curl -s -o /dev/null -w "%{http_code} " http://$WEB_IP/api/v1/products; done; echo
ssh orderdesk-backend-2 "docker start backend"
```

All responses should be `200`.

**Readiness on a backend:** `curl localhost:8080/actuator/health/readiness` must return `UP`. It covers
`db`, `redis` and `rabbit`, so a `DOWN` shows which service the backend cannot reach.

## 10. Costs, pause and destroy

Approximate us-east-1 on-demand cost per day:

| Item | Per day |
| --- | --- |
| NAT t3.micro + public IPv4 | about $0.37 |
| web t3.micro + public IPv4 | about $0.37 |
| 2 × backend t3.small | about $1.00 |
| RDS db.t4g.micro + 20 GB | about $0.46 |
| ElastiCache cache.t4g.micro | about $0.40 |
| Amazon MQ mq.m7g.medium | check current pricing; the largest line item |
| EBS (4 volumes) | about $0.18 |

- **Pause:** `aws rds stop-db-instance --db-instance-identifier orderdesk-db` (restarts by itself after
  7 days) and `aws ec2 stop-instances` for the EC2s. **ElastiCache and Amazon MQ cannot be stopped**,
  so they keep billing until destroyed. Public IPs change after a start, so regenerate the SSH config.
- **Destroy:** `terraform plan -destroy`, then `terraform destroy` in `infra/`. RDS has no final
  snapshot and no deletion protection. The broker takes several minutes to delete. The S3 state bucket
  is outside this config and stays.

## 11. Troubleshooting

| Symptom | Likely cause | Fix |
| --- | --- | --- |
| `no file exists at ./nat_user_data.sh.tftpl` | file named `.tftp` | rename it to `.tftpl` |
| `InvalidParameterCombination ... not eligible for Free Tier` | instance type not allowed on this account | use a type from the free-tier list (`t3.micro`, `t3.small`) |
| `does not support host instance type [mq.t3.micro]` | `mq.t3.micro` is ActiveMQ only | use `mq.m7g.medium` with RabbitMQ 4.x |
| `Variables not allowed` in `versions.tf` | variable in the `backend` block | type the bucket name as plain text |
| Readiness `DOWN`, `rabbit` | SSL off, wrong port or `guest` user | port 5671, `SPRING_RABBITMQ_SSL_ENABLED=true`, user `orderdesk` |
| Readiness `DOWN`, `db` | app user missing or wrong password | re-run 8.1 |
| Flyway or schema validation error | user lacks DDL rights or wrong database | check `GRANT ALL ... ON orderdesk.*` and `db_name` |
| Endpoint resolves to a public IP or times out | peering DNS option is off | confirm `aws_vpc_peering_connection_options` was applied |
| Backend build `Killed` | out of memory | keep `t3.small` and the swap |
| `502 Bad Gateway` from nginx | a backend container is down | `docker ps` and `docker logs backend` on that server |
| Backend boot never finishes | no NAT route yet | keep the `depends_on`; read the NAT console output |
| Edited `user_data`, nothing changed | scripts only run at first boot | `user_data_replace_on_change = true` replaces the server |
| `REMOTE HOST IDENTIFICATION HAS CHANGED` | rebuilt server on a reused IP | `ssh-keygen -R <IP>` |
