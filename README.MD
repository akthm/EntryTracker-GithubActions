# CI/CD Automation – Design Summary

This doc captures the key design choices behind our build–test–publish pipeline and the blue/green deployment strategy for staging on EC2.

---

## Overview

- **Source Control:** GitHub
- **Registry (CI):** GHCR (immutable `:sha-<short>` tags)
- **Registry (Release):** Amazon ECR Public (semantic `:vX.Y.Z` + channel tags)
- **Compute (Staging):** Single EC2 host running Docker Compose
- **LB:** NGINX (hot reload), **DB:** MySQL (persistent volume)
- **Deploy Orchestration:** AWS Systems Manager (Run Command) or SSH-over-SSM

---

## CI Strategy

### Stages
1. **Build**
   - `docker/build-push-action` with **Buildx** and **GHA cache** (`cache-from/to: type=gha`).
   - Push once to **GHCR** → `ghcr.io/<owner>/<repo>:sha-<short>`.
   - Output the **image_ref** as a job output for downstream jobs.

2. **Unit Tests**
   - Isolated Python **venv**, install from `requirements.txt`, run `pytest` + `pytest-cov`.

3. **E2E (Compose)**
   - Pull the **exact** GHCR image from Build.
   - Retag to `app:build` if compose expects it.
   - `docker compose up -d --wait` and hit `/health`.
   - On success, re-expose the **tested** image ref for publish.

4. **Publish**
   - Reusable workflow bumps **patch** in `VERSION` (only on `main`), commits bump, and **retags** GHCR image to **ECR Public**:
     - `:vX.Y.Z` (versioned), optional `:latest`, `:sha-<short>`.
   - Outputs `image_uri_versioned` for CD.

### Why GHCR (vs artifacts)
- **Layer reuse** & speed, no tar juggling.
- Same immutable image is used across **E2E** and **Publish**.
- Works across jobs/runners and integrates naturally with CD.

---

## CD Strategy – Blue/Green on EC2 (Docker Compose)

### Topology
- `nginx` (LB) → routes to **one** of: `app_blue` **or** `app_green`.
- `mysql` persists; **not** redeployed during app rollouts.
- `nginx/active_upstream.conf` symlinks to either `upstream.blue.conf` or `upstream.green.conf`.

### Deploy Flow
1. CI triggers SSM **Run Command** to execute `/opt/staging/blue_green_deploy.sh <ECR_IMAGE_URI>` on the staging EC2.
2. Script logic:
   - Identify **idle** color (read state file).
   - `docker pull` the **versioned** ECR image and start idle service.
   - Wait for **container health** (`/health`) to be **healthy**.
   - Flip `active_upstream.conf` to the new color and `nginx -s reload` (hot reload, minimal downtime).
   - Stop old color after a brief drain/soak.
3. **Rollback**: redeploy the previous version (flip back) using the same script.

### Why Blue/Green
- Near-zero downtime (LB **reload**, not restart).
- Safe rollout & **instant rollback**.
- DB untouched; app containers are stateless and replaceable.

---

## Security & IAM (Least Privilege)

- **Instance Role (EC2 host):**
  - `AmazonSSMManagedInstanceCore` (required).
  - `AmazonElasticContainerRegistryPublicReadOnly` (pull from ECR Public).
  - Optional: narrow **Parameter Store / Secrets Manager** read (if used), plus `kms:Decrypt` for the specific CMK.

- **CI Deploy Role (GitHub OIDC):**
  - `ssm:SendCommand` to `AWS-RunShellScript` + target instance ARN(s).
  - `ssm:GetCommandInvocation`, `ssm:ListCommandInvocations`, `ssm:ListCommands` (read outputs).
  - `ssm:DescribeInstanceInformation`, `ec2:DescribeInstances` (pre-checks).
  - If SSH-over-SSM: `ssm:StartSession`, `ssm:TerminateSession` (to `AWS-StartSSHSession` + instance ARNs).

- **Networking:**
  - Outbound **443** to `ssm`, `ssmmessages`, `ec2messages` (via IGW/NAT) **or** VPC **Interface Endpoints** with Private DNS.
  - Note: **ECR Public** has no VPC endpoint → needs Internet/NAT (or mirror images to private ECR + VPCE).

---

## Observability & Debuggability

- **CI logs**: group logs for inputs/outputs; dump compose logs on failure.
- **SSM**: use `list-commands`, `list-command-invocations`, `get-command-invocation` to view run results.
- **Deploy script**: writes timestamped logs (and last image marker) to `/opt/staging/deploy-trace/`.
- **Nginx**: access/error logs show which upstream is active; `nginx -T` to verify includes.

---

## Ops Tips

- **Gate publish** on E2E **success**; publish only the **tested** image.
- Prefer **OIDC** to assume AWS roles (no long-lived keys).
- Pin runtime to **versioned** tags (`:vX.Y.Z`); use `:latest` only as a convenience tag.
- Database migrations: use **expand/contract** pattern and run migrations **before** flipping traffic.
- Add a simple **flock** in deploy script to avoid concurrent runs.

---
