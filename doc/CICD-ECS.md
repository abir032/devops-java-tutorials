# CI/CD and ECS Guide (Jenkins, ECR, ECS Fargate)

Runs Order Desk on **ECS Fargate** behind an Application Load Balancer, with a **Jenkins** pipeline that
tests the code, builds the images, pushes them to **ECR** and deploys them. Two Terraform stacks build
the AWS side: [`infra-cicd/`](../infra-cicd/) (registry and build agent) and [`infra-ecs/`](../infra-ecs/)
(network, data services, cluster). The pipelines are [`Jenkinsfile`](../Jenkinsfile) (the application) and
[`ci/infra.Jenkinsfile`](../ci/infra.Jenkinsfile) (Terraform).

This guide builds on [AWS-INFRA.md](AWS-INFRA.md), which runs the same app on plain EC2 servers. The
concepts that are identical (VPC peering, NAT, the data tier) are explained in short here and in full there.

## Contents

1. [Overview](#1-overview)
2. [Architecture](#2-architecture)
3. [Network and address plan](#3-network-and-address-plan)
4. [Security](#4-security)
5. [ECS, ECR and the data services](#5-ecs-ecr-and-the-data-services)
6. [Terraform layout](#6-terraform-layout)
7. [Build the AWS infrastructure](#7-build-the-aws-infrastructure)
8. [Jenkins setup, step by step](#8-jenkins-setup-step-by-step)
9. [The pipelines](#9-the-pipelines)
10. [First deploy and verify](#10-first-deploy-and-verify)
11. [Day-to-day operations](#11-day-to-day-operations)
12. [Costs and destroy](#12-costs-and-destroy)
13. [Troubleshooting](#13-troubleshooting)

---

## 1. Overview

| Part | Technology | What it does |
| --- | --- | --- |
| **Jenkins server** (controller) | Jenkins, already installed on an EC2 | Schedules jobs, shows the UI and logs. Does **not** build anything itself. |
| **Build agent** | EC2 (Ubuntu 24.04) with Docker, AWS CLI, Java 21 | Runs the pipeline: tests, `docker build`, `docker push`, deploy. |
| **ECR** | Two repositories (`backend`, `frontend`) | Stores the images. Tags are immutable. |
| **ECS Fargate** | One cluster, two services | Runs the containers. No servers to manage. |
| **ALB** | Application Load Balancer | The only public address. `/api/*` goes to the backend, the rest to the frontend. |
| **Data services** | RDS MariaDB, ElastiCache Redis, Amazon MQ RabbitMQ | Replace the three containers of the Compose setup. Reachable from the app only. |

Compared with the other setups in this repo: Compose networks became VPCs, the data containers became
managed services, nginx as entry point became the ALB, and "build on the server" became "build once, push
to a registry, deploy the same image".

**From commit to running container**

1. A commit reaches `main`. Jenkins polls GitHub every 2 minutes (or you start the job by hand).
2. The Jenkins server hands the job to the build agent, which checks out the code.
3. The agent runs the backend tests (Maven) and the frontend build (Node), each in a throw-away container.
4. The agent builds two images tagged `<build-number>-<git-sha>` and pushes them to ECR.
5. A person approves the deploy in Jenkins.
6. The deploy step copies the current ECS task definition with the new image, registers it as a new
   revision and updates the service.
7. ECS starts new tasks, waits until the ALB reports them healthy, and only then stops the old ones.
8. The script checks that the service did not roll back and that enough targets are healthy.

## 2. Architecture

```
                         Internet (my_ip only)
                              │ HTTP :80
 ┌────────────────────────────▼────── App VPC 10.40.0.0/16 ────────────────────────┐
 │  public subnets (AZ a, AZ b)                                                      │
 │   ┌─────────────────────────┐        ┌──────────────┐                             │
 │   │ ALB                     │        │ NAT instance │◄───────────┐                │
 │   │  /api/*  → backend TG   │        └──────────────┘            │ 0.0.0.0/0      │
 │   │  default → frontend TG  │                                    │                │
 │   └───────┬─────────┬───────┘                                    │                │
 │  private subnets (AZ a, AZ b)                                    │                │
 │   ┌───────▼───┐ ┌───▼───────┐                                    │                │
 │   │ frontend  │ │ backend   │  ECS Fargate tasks ────────────────┘                │
 │   │ tasks :80 │ │ tasks:8080│                                                     │
 │   └───────────┘ └─────┬─────┘                                                     │
 └───────────────────────┼───────────────────────────────────────────────────────────┘
                         │ VPC peering: 3306, 6379, 5671
 ┌───────────────────────▼────── DB VPC 10.50.0.0/16 (no internet gateway) ─────────┐
 │  RDS MariaDB · ElastiCache Redis · Amazon MQ RabbitMQ                              │
 └────────────────────────────────────────────────────────────────────────────────────┘

 Existing Jenkins VPC
 ┌───────────────────────────────────────────────────────────────────────────────────┐
 │  Jenkins server ──SSH :22──► build agent ──► ECR (push)  ──► ECS API (deploy)     │
 │   (UI, scheduling)           (Docker, AWS CLI; IAM instance role)                  │
 └───────────────────────────────────────────────────────────────────────────────────┘
```

Two separate Terraform stacks with separate state files:

| Stack | State key | Builds |
| --- | --- | --- |
| `infra-cicd` | `orderdesk-cicd/terraform.tfstate` | ECR repositories, build agent EC2, its IAM role and security group, the Jenkins server's IAM role |
| `infra-ecs` | `orderdesk-ecs/terraform.tfstate` | VPCs, peering, NAT, ALB, ECS cluster and services, RDS, ElastiCache, Amazon MQ, SSM parameters |

`infra-ecs` reads the ECR repositories made by `infra-cicd`, so **`infra-cicd` is applied first**.

## 3. Network and address plan

| Network | CIDR | AZ | Holds |
| --- | --- | --- | --- |
| App VPC | `10.40.0.0/16` | | everything the app runs on |
| frontend subnet (public) | `10.40.1.0/24` | a | ALB, NAT instance |
| frontend-b subnet (public) | `10.40.3.0/24` | b | ALB (it needs two AZs) |
| backend subnet (private) | `10.40.2.0/24` | a | ECS tasks (frontend and backend) |
| backend-b subnet (private) | `10.40.4.0/24` | b | ECS tasks |
| DB VPC | `10.50.0.0/16` | | data services only |
| db-a / db-b (private) | `10.50.1.0/24`, `10.50.2.0/24` | a, b | RDS, ElastiCache, Amazon MQ (subnet groups need two AZs) |

The two VPC ranges must not overlap (a peering rule). Subnets are computed with `cidrsubnet(cidr, 8, n)`
from the two variables in [variables.tf](../infra-ecs/variables.tf).

| Route table | Subnets | Routes |
| --- | --- | --- |
| `frontend-rt` | both public | local, `0.0.0.0/0 → igw` |
| `backend-rt` | both private | local, `10.50.0.0/16 → pcx`, `0.0.0.0/0 → NAT ENI` |
| `db-rt` | db-a, db-b | local, `10.40.0.0/16 → pcx` |

- **Peering** ([peering.tf](../infra-ecs/peering.tf)): same account and region, so `auto_accept = true`. DNS
  resolution is enabled on both sides, so the RDS, ElastiCache and MQ names resolve to private IPs from the
  App VPC. Both route tables are needed: without the DB-side route, requests arrive and replies are lost.
  The full explanation is in [AWS-INFRA.md, section 3.1](AWS-INFRA.md#31-how-vpc-peering-works).
- **NAT instance** ([nat.tf](../infra-ecs/nat.tf)): a `t3.micro` in the public subnet with
  `source_dest_check = false`, IP forwarding and an iptables MASQUERADE rule. Fargate tasks in the private
  subnets use it to pull images from ECR and Docker Hub. The ECS services `depend_on` the default route,
  so a task never starts without a way out.
- **Only the private route table points at the DB VPC.** The public subnets have no route there.
- **ALB** ([alb.tf](../infra-ecs/alb.tf)): listener on port 80. A rule for `/api/*` (priority 10) forwards
  to the backend target group; everything else goes to the frontend target group. Targets are registered by
  IP (`target_type = "ip"`), because Fargate tasks have no instance.

| Target group | Port | Health check |
| --- | --- | --- |
| backend | 8080 | `/actuator/health/readiness` (needs DB, Redis and RabbitMQ up), expect `200` |
| frontend | 80 | `/`, expect `200-399` |

## 4. Security

### 4.1 Network guards

| Security group | Inbound | Why |
| --- | --- | --- |
| `alb-sg` | TCP 80 from `my_ip` (a `/32`) | the only public door, limited to your address |
| `ecs-sg` | TCP 8080 and 80 from `alb-sg` | tasks accept traffic from the load balancer only |
| `nat-sg` | all from the App VPC CIDR | forwards traffic of the private subnets |
| `rds-sg` | TCP 3306 from the App VPC CIDR | MariaDB |
| `redis-sg` | TCP 6379 from the App VPC CIDR | Redis |
| `mq-sg` | TCP 5671 from the App VPC CIDR | RabbitMQ over TLS (AMQPS) |
| `build-agent-sg` | TCP 22 from the **Jenkins server's security group** | only Jenkins can SSH in; no inbound from the internet |

The data tier has three independent layers: no internet gateway, a route for the app range only, and
security groups limited to three ports.

### 4.2 IAM roles

| Role | Used by | Allowed to |
| --- | --- | --- |
| `<project>-exec-role` | ECS itself, **before** your code starts | pull images, write logs, read the two secrets (DB and MQ password) from SSM |
| `<project>-task-role` | your code, while it runs | nothing (Order Desk calls no AWS API) |
| `<project>-build-agent-role` | the build agent (instance role) | push and pull the two ECR repositories, register task definitions, update services of the one cluster, `iam:PassRole` for `<project>-ecs-*` roles only |
| `jenkins-terraform-role` | the Jenkins server (instance role), for the Terraform job | the state bucket, the services the two stacks manage in one region, SSM parameters `/<project>*`, IAM writes on `<project>-*` roles only |

No role uses stored access keys. The build agent and the Jenkins server get short-lived credentials from
the instance metadata service, which the AWS CLI and Terraform find automatically.

- The Jenkins role is named `jenkins-*`, not `<project>-*`, so its own policy never lets it edit itself.
  Change [jenkins_role.tf](../infra-cicd/jenkins_role.tf) from an admin workstation, not from the Jenkins job.
- Only the ECS execution managed policy may be attached to roles it creates, so it cannot hand out
  `AdministratorAccess`.
- Both instances require IMDSv2 (`http_tokens = required`) with a hop limit of 2, so containers on the host
  (Terraform, the AWS CLI image) can use the instance role too.
- Secrets are generated by Terraform (`random_password`), stored in SSM Parameter Store and injected into
  the task by the **execution** role at start. They never appear in the Jenkins job or the image.

### 4.3 Keep the Jenkins port closed

The Jenkins UI is an administration tool. Do not open its port to `0.0.0.0/0`. Reach it through an SSH
tunnel (`ssh -L 8080:localhost:8080 ubuntu@<jenkins-ip>`, then open `http://localhost:8080`) or allow
only your own `/32` in the Jenkins security group.

## 5. ECS, ECR and the data services

**ECR** ([ecr.tf](../infra-cicd/ecr.tf)): `<project>-backend` and `<project>-frontend`.

- `image_tag_mutability = IMMUTABLE`: a tag can never be overwritten, so build 42 is always build 42, and a
  rollback is exactly the old image.
- Scan on push, and a lifecycle policy that keeps only the last 10 images.

**ECS** ([ecs.tf](../infra-ecs/ecs.tf)):

| Service | Task size | Port | Subnets |
| --- | --- | --- | --- |
| backend | 0.5 vCPU, 1 GB | 8080 | both private, no public IP |
| frontend | 0.25 vCPU, 0.5 GB | 80 | both private, no public IP |

- The backend gets its settings as environment variables (the same Spring names as in Compose) and its two
  passwords as `secrets` from SSM. Logs go to CloudWatch.
- Rolling deploys: `minimum_healthy_percent = 100`, `maximum_percent = 200` (new tasks start before old ones
  stop). The backend has a 180 s health-check grace period for Spring Boot and Flyway.
- **Deployment circuit breaker with rollback**: a deployment whose tasks keep failing is rolled back by ECS.
- **`desired_count = 0` on the first apply.** The first task definitions point at a `bootstrap` image that
  does not exist. Nothing runs until the pipeline deploys a real image and sets the count (2).
- `lifecycle { ignore_changes = [task_definition, desired_count] }`: Jenkins owns these two values. Without
  it, the next `terraform apply` would undo the last deployment.

**Data services** ([database.tf](../infra-ecs/database.tf)):

| Service | Version | Size | Note |
| --- | --- | --- | --- |
| RDS MariaDB | 11.4 | `db.t4g.micro` | Flyway creates the schema on the first backend start |
| ElastiCache Redis | 7.1 | `cache.t4g.micro` | disposable product cache |
| Amazon MQ RabbitMQ | 4.2 | `mq.m7g.medium` | TLS on 5671; `guest` is not allowed, the user is `orderdesk` |

The endpoints and passwords are written to SSM parameters under `/<project>/...`.

## 6. Terraform layout

```
infra-cicd/
  versions.tf, providers.tf, variables.tf   settings, S3 backend, inputs
  ecr.tf                                    the two ECR repositories + lifecycle policy
  agent.tf                                  build agent: IAM role, security group, EC2
  agent_user_data.sh.tftpl                  first-boot script of the agent
  jenkins_role.tf                           IAM role/profile for the Jenkins server
  outputs.tf                                agent IP, ECR URLs
infra-ecs/
  versions.tf, providers.tf, variables.tf
  network-app.tf, network-db.tf, peering.tf the two VPCs and the link
  nat.tf, nat_user_data.sh.tftpl            NAT instance
  security.tf                               security groups
  alb.tf                                    load balancer, target groups, listener rule
  database.tf                               RDS, ElastiCache, Amazon MQ, SSM parameters
  iam.tf                                    ECS execution and task roles
  ecs.tf                                    cluster, task definitions, services, log group
  outputs.tf                                ALB URL, cluster name, log group
ci/
  infra.Jenkinsfile                         Terraform pipeline
  Dockerfile.deploy                         AWS CLI + jq image for the deploy step
  scripts/deploy-ecs-service.sh             the deploy logic
Jenkinsfile                                 application pipeline
```

Both stacks keep their state in one S3 bucket with a different key each, with `use_lockfile = true` (no
DynamoDB table). The bucket is created by hand once and lives outside both stacks. The `backend` block
accepts plain text only, so the bucket name is typed in, not a variable.

## 7. Build the AWS infrastructure

Run from your workstation the first time. Later changes can go through the `infra` Jenkins job
([section 9.2](#92-the-infra-pipeline)).

**Step 0, prerequisites**

```bash
terraform -version                    # 1.10 or newer
aws sts get-caller-identity           # the account you expect
aws s3 mb s3://<state-bucket>         # once; enable versioning on it
```

Find the values the agent stack needs from the existing Jenkins server (VPC, subnet, security group):

```bash
aws ec2 describe-instances --instance-ids <jenkins-instance-id> \
  --query 'Reservations[0].Instances[0].[VpcId,SubnetId,SecurityGroups[0].GroupId]' --output text
```

Put them in [variables.tf](../infra-cicd/variables.tf) (`jenkins_vpc_id`, `jenkins_subnet_id`,
`jenkins_security_group_id`) together with the EC2 key pair name (`key_name`, for admin SSH).

**Step 1, create the SSH key pair Jenkins uses to log in to the agent.** Do this **on the Jenkins server**:

```bash
ssh-keygen -t ed25519 -f ~/.ssh/build-agent-key -N "" -C "jenkins controller to build-agent"
cat ~/.ssh/build-agent-key.pub        # the PUBLIC key: safe to copy
```

Paste the single `.pub` line into `controller_public_key` in `variables.tf`. The first-boot script writes it to
`/home/jenkins/.ssh/authorized_keys` on the agent. The **private** key never leaves the Jenkins server except
into the Jenkins credential in step 8.2. If this variable still holds a placeholder, Jenkins cannot log in.

**Step 2, apply `infra-cicd`**

```bash
cd infra-cicd
terraform init
terraform fmt && terraform validate && terraform plan -out=tfplan
terraform apply tfplan
terraform output                      # agent_private_ip, ecr_backend_url, ecr_frontend_url
```

Wait 2 to 3 minutes: the agent installs Docker, the AWS CLI and Java on first boot. It writes
`/var/tmp/agent-ready` when it is done.

**Step 3, attach the instance role to the Jenkins server.** Terraform cannot attach a profile to an existing
instance, so this is a one-off CLI call (no downtime):

```bash
aws ec2 associate-iam-instance-profile --instance-id <jenkins-instance-id> \
  --iam-instance-profile Name=jenkins-terraform-profile
# on the Jenkins server, with no keys configured:
aws sts get-caller-identity           # shows assumed-role/jenkins-terraform-role
```

**Step 4, apply `infra-ecs`**

```bash
cd ../infra-ecs
echo "my_ip = \"$(curl -s https://checkip.amazonaws.com)/32\"" > terraform.tfvars
terraform init
terraform fmt && terraform validate && terraform plan -out=tfplan
terraform apply tfplan
terraform output                      # alb_url, cluster_name, log_group
```

`my_ip` must be a single address ending in `/32`; it is the only source the ALB accepts. Amazon MQ takes
15 to 20 minutes to create. Because `desired_count` is 0, the services are created but run no tasks.

## 8. Jenkins setup, step by step

All of this is done in the Jenkins web UI, except reading the private key in step 8.2.

### 8.1 Prepare the Jenkins server

1. **Plugins** (Manage Jenkins → Plugins): Pipeline, Docker Pipeline, SSH Build Agents, Credentials Binding,
   Git, JUnit.
2. **Docker on the Jenkins server.** The `infra` pipeline runs Terraform in a `hashicorp/terraform`
   container, so Docker must be installed and the `jenkins` user must be in the `docker` group:
   ```bash
   sudo usermod -aG docker jenkins && sudo systemctl restart jenkins
   sudo mkdir -p /var/lib/jenkins/tf-plugin-cache && sudo chown jenkins: /var/lib/jenkins/tf-plugin-cache
   ```
3. **Instance role attached** (step 3 above), so the Terraform job needs no AWS keys.

### 8.2 Credentials

Manage Jenkins → Credentials → System → Global credentials → Add Credentials.

| ID | Kind | Content |
| --- | --- | --- |
| `build-agent-ssh` | SSH Username with private key | Username `jenkins`; Private Key → Enter directly → paste the **whole** output of `cat ~/.ssh/build-agent-key` (with the `BEGIN` and `END` lines); passphrase empty |
| GitHub credential | SSH key or username/token | only if the repository is private |

Read the key on the Jenkins server and paste it nowhere else:

```bash
cat ~/.ssh/build-agent-key
```

Test that the key works before adding the node:

```bash
ssh -i ~/.ssh/build-agent-key jenkins@<agent-private-ip> 'cat /var/tmp/agent-ready && docker --version'
```

`agent ready` and a Docker version mean the agent and the key are fine. `Permission denied (publickey)` means
the agent holds a different public key (fix `controller_public_key` and re-apply).

> If you cannot use the instance role, store an IAM user's keys as two **Secret text** credentials
> (`aws-access-key-id`, `aws-secret-access-key`) and wrap the Terraform steps in `withCredentials`. Give that
> user a scoped policy, never `AdministratorAccess`. The instance role is preferred because nothing can leak
> or needs rotating.

### 8.3 Add the build agent node

Manage Jenkins → Nodes → New Node → name `build-agent` → **Permanent Agent**.

| Field | Value |
| --- | --- |
| Remote root directory | `/home/jenkins/agent` |
| Labels | `build-agent` (the `Jenkinsfile` selects the agent by this label) |
| Usage | Only build jobs with label expressions matching this node |
| Launch method | Launch agents via SSH |
| Host | the agent's private IP (`agent_private_ip` output) |
| Credentials | `build-agent-ssh` |
| Host Key Verification Strategy | Non verifying (switch to Known hosts file once it is stable) |

Save and open the node's **Log**. It must end with `Agent successfully connected and online`.

> The agent's private IP changes whenever the instance is replaced (for example after changing
> `controller_public_key`, because `user_data_replace_on_change = true`). Update the node's Host afterwards.

### 8.4 Create the two jobs

New Item → **Pipeline** → Pipeline script from SCM → Git → your repository URL, branch `*/main`.

| Job | Script Path | Purpose |
| --- | --- | --- |
| `infra` | `ci/infra.Jenkinsfile` | plan, apply or destroy one Terraform folder |
| `orderdesk-app` | `Jenkinsfile` | test, build, push and deploy the application |

Jenkins reads the Jenkinsfile from GitHub, so push your changes before running a job.

## 9. The pipelines

### 9.1 The application pipeline

[`Jenkinsfile`](../Jenkinsfile) runs entirely on the `build-agent` node.

| Stage | What happens |
| --- | --- |
| Prepare | reads the git SHA, builds the tag `<build>-<sha>`, finds the ECR registry from the caller identity |
| Test and build (parallel) | backend tests in `maven:3.9-eclipse-temurin-21`; frontend `npm ci` and `npm run build` in `node:24-alpine`. Skipped when `ROLLBACK_TAG` is set. |
| Build images | `docker build` for `backend` and `frontend` (`VITE_API_URL` empty, so the browser calls the same origin) |
| Push to ECR | `aws ecr get-login-password`, then `docker push` both images |
| Approve deploy | on `main` only: waits up to 30 minutes for a click (`REQUIRE_APPROVAL`) |
| Deploy to ECS | in a container built from [ci/Dockerfile.deploy](../ci/Dockerfile.deploy) (AWS CLI and jq), runs `deploy-ecs-service.sh` for each service |

Parameters:

| Parameter | Meaning |
| --- | --- |
| `ROLLBACK_TAG` | an image tag already in ECR. Skips tests and build and deploys that tag. |
| `REQUIRE_APPROVAL` | wait for a click before deploying (default on) |

The test and build stages run in containers, but `docker build` and `docker push` use the **agent's own
Docker**, because a container cannot build images without one. After every run the pipeline removes this
build's images and prunes dangling layers to protect the agent's disk.

**What the deploy script does** ([deploy-ecs-service.sh](../ci/scripts/deploy-ecs-service.sh)):

1. Reads the task definition the service runs now.
2. Copies it with the container's image replaced (and without the fields AWS fills in itself).
3. Registers it as a new revision and points the service at it, setting the desired count.
4. Waits until the service is stable.
5. **Verifies it did not roll back.** A rolled-back deployment is also "stable", so the script checks that the
   service runs the revision it just registered. Otherwise it fails.
6. Checks that enough targets are `healthy` in the load balancer.

### 9.2 The infra pipeline

[`ci/infra.Jenkinsfile`](../ci/infra.Jenkinsfile) runs Terraform for **one folder per run**.

| Parameter | Meaning |
| --- | --- |
| `TF_DIR` | `infra-cicd` or `infra-ecs` |
| `ACTION` | `plan` (only shows changes), `apply` or `destroy` (both wait for approval) |
| `MY_IP` | only for `infra-ecs`: your public IP with `/32` |

Stages: **Plan** (`fmt -check`, `init`, `validate`, `plan -out=tfplan`) → **Approve** (apply and destroy only)
→ **Apply** (`terraform apply tfplan`). The plan that was approved is the plan that is applied. To cover both
stacks, run the job twice. It uses the instance role of the Jenkins server for AWS access.

Changes to [jenkins_role.tf](../infra-cicd/jenkins_role.tf) cannot be applied by this job (the role does not
manage itself); apply them from an administrator workstation.

## 10. First deploy and verify

1. Run `orderdesk-app` (Build with Parameters, keep the defaults).
2. Watch the stages. After the push, click **Deploy** at *Approve deploy*.
3. The deploy script registers a revision for each service and sets the count to 2. ECS pulls the images
   from ECR through the NAT instance; the backend takes a few minutes to pass its health check.
4. Open the ALB URL (`terraform output alb_url` in `infra-ecs`) from the address you set as `my_ip`.

Checks:

```bash
CLUSTER=<project>-cluster
aws ecs describe-services --cluster "$CLUSTER" --services backend frontend \
  --query 'services[].[serviceName,runningCount,desiredCount]' --output table
curl -s http://<alb-dns>/api/v1/products | head -c 300      # JSON, header X-Cache: MISS then HIT
curl -sI http://<alb-dns>/ | head -1                        # HTTP/1.1 200
aws logs tail <log-group> --since 10m --follow              # backend logs
```

The task hostname (`ip-10-40-x-x.ec2.internal`) differs between requests and after every deploy. That is
normal: each task has its own private IP and the ALB spreads requests across them. If new addresses keep
appearing with no deploy, tasks are restarting; look at the stopped tasks and the logs
([section 13](#13-troubleshooting)).

## 11. Day-to-day operations

| Task | How |
| --- | --- |
| Deploy a change | push to `main`; the job polls every 2 minutes, then click **Deploy** |
| Roll back | run `orderdesk-app` with `ROLLBACK_TAG=<old tag>` (find tags in ECR). No rebuild, same approval. |
| Scale | change `DESIRED_COUNT` in the `Jenkinsfile` (the service ignores Terraform's `desired_count`) |
| Change infrastructure | edit the Terraform, run `infra` with `plan`, read it, then `apply` |
| Replace the agent | change `controller_public_key` or `user_data`; apply `infra-cicd`; update the node's host |
| Rotate the SSH key | generate a new pair, update `controller_public_key` and the `build-agent-ssh` credential |
| Look at logs | CloudWatch log group (`terraform output log_group`), stream prefix `backend` or `frontend` |

## 12. Costs and destroy

Always running: ALB, NAT instance, RDS, ElastiCache, Amazon MQ, the Fargate tasks (2 per service), the build
agent and its public IP. **Amazon MQ and ElastiCache cannot be stopped**, so they bill until destroyed. Check
current prices for your region; the broker is the largest single line.

Destroy in this order (the ECS stack reads the ECR repositories):

1. Run `infra` with `TF_DIR=infra-ecs`, `ACTION=destroy`, `MY_IP=<ip>/32`. The broker takes several minutes.
2. Run `infra` with `TF_DIR=infra-cicd`, `ACTION=destroy`. This removes the build agent and, because the
   Jenkins role is in the same stack, the Jenkins role too (do this last, or from a workstation).
3. ECR repositories have `force_delete = true`, so they go even with images in them. The S3 state bucket is
   outside both stacks and stays.
4. Remove the `build-agent` node and the credentials in Jenkins.

## 13. Troubleshooting

| Symptom | Likely cause | Fix |
| --- | --- | --- |
| Jenkins UI times out | the Jenkins security group has no inbound rule for its port | add your `/32` for that port, or use the SSH tunnel (section 4.3) |
| Node log: `Permission denied (publickey)` | the agent's `authorized_keys` holds a different (or placeholder) public key | set `controller_public_key` to the real `.pub` line and re-apply, or fix `/home/jenkins/.ssh/authorized_keys` by hand |
| Node cannot connect, no error | the agent was replaced and has a new private IP | update the node's Host |
| Node: `Connection timed out` | agent security group does not allow the Jenkins SG on 22, or agent still booting | check `agent_ssh` rule; wait for `/var/tmp/agent-ready` |
| `docker: permission denied` in a stage | `jenkins` user not in the `docker` group on that machine | `sudo usermod -aG docker jenkins`, restart the agent connection or Jenkins |
| Infra job: `NoCredentialProviders` or `AccessDenied` | instance profile not attached to the Jenkins server, or the policy lacks an action | `aws sts get-caller-identity` on the server; add the missing action named in the error to `jenkins_role.tf` |
| `tag invalid: The image tag ... already exists` on push | tags are immutable and this build number and SHA were pushed before | run a new build (the number changes) |
| Push to ECR: `no basic auth credentials` | login step failed or the instance role lacks `ecr:GetAuthorizationToken` | check the agent role; run `aws sts get-caller-identity` on the agent |
| Service stuck at `0` running tasks | `desired_count` is still 0, nothing deployed yet | run the app pipeline once |
| Tasks start and stop repeatedly | health check failing (database, Redis or RabbitMQ unreachable, out of memory) | `aws ecs list-tasks ... --desired-status STOPPED`, then `describe-tasks` for `stoppedReason`, and read the logs |
| `CannotPullContainerError` | no route out of the private subnets, or the image tag does not exist in ECR | check the NAT instance and `backend-rt` default route; check the tag in ECR |
| Deploy script: `FAILED: the service went back to ...` | the circuit breaker rolled the deployment back | read the service events and task logs of the new tasks; fix and redeploy |
| ALB returns `503` right after a deploy | no healthy targets yet | wait for the grace period (backend 180 s); check the target group health |
| Backend readiness `DOWN` for `rabbit` | SSL off, wrong port or `guest` user | port 5671, `SPRING_RABBITMQ_SSL_ENABLED=true`, user `orderdesk` |
| Endpoint resolves to a public IP or times out | peering DNS option is off | confirm `aws_vpc_peering_connection_options` was applied |
| `terraform apply` undoes the last deploy | `ignore_changes` removed from the services | keep `ignore_changes = [task_definition, desired_count]` |
| Browser cannot reach the ALB | your IP changed | update `my_ip` and apply `infra-ecs` |
