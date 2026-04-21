# AWS setup — RDS, S3, IAM, EC2 (manual, free tier)

Phase 1 provisions everything by hand through the AWS Console. All resources
should live in **one region** (e.g. `us-east-1`) so EC2 ↔ RDS ↔ S3 traffic
stays free.

## 1. S3 bucket

1. Console → S3 → **Create bucket**.
2. Name: `cdc-pipeline-events-<your-suffix>` (globally unique).
3. Region: the same one you'll use for RDS + EC2.
4. Block all public access: **on** (default).
5. Bucket versioning: off (Phase 1).
6. Leave everything else default.

## 2. RDS Postgres (db.t3.micro, free tier)

1. Console → RDS → **Create database**.
2. Engine: PostgreSQL 16.x.
3. Template: **Free tier**.
4. DB instance identifier: `cdc-pipeline`.
5. Master username: `postgres`. Master password: save it somewhere safe.
6. Instance class: `db.t3.micro`.
7. Storage: 20 GB gp3, **disable storage autoscaling** (keeps you inside free tier).
8. Connectivity:
   - VPC: default.
   - Public access: **Yes** (Phase 1 only — we'll connect from the EC2).
   - VPC security group: create a new one, e.g. `cdc-pg-sg`.
9. Additional config → Initial database name: `cdc`.
10. Create.

While it provisions, go to **Parameter groups**:
- Create a parameter group, family `postgres16`, name `cdc-pg-logical-repl`.
- Edit it, set `rds.logical_replication = 1`. Save.
- Back on the RDS instance → Modify → change DB parameter group to `cdc-pg-logical-repl` → Apply immediately.
- **Reboot** the instance so the new parameter takes effect.
- Verify after reboot:
  ```sql
  SHOW rds.logical_replication;  -- should be 'on'
  SHOW wal_level;                -- should be 'logical'
  ```

Details on roles/publications/slots live in [`rds-logical-replication.md`](./rds-logical-replication.md).

## 3. IAM — EC2 instance role

1. Console → IAM → **Roles** → **Create role**.
2. Trusted entity: AWS service → EC2.
3. Permissions: create a new inline/customer policy with **exactly** this scope:
   ```json
   {
     "Version": "2012-10-17",
     "Statement": [
       {
         "Sid": "CdcS3Write",
         "Effect": "Allow",
         "Action": [
           "s3:PutObject",
           "s3:GetObject",
           "s3:AbortMultipartUpload",
           "s3:ListMultipartUploadParts"
         ],
         "Resource": "arn:aws:s3:::cdc-pipeline-events-<your-suffix>/*"
       },
       {
         "Sid": "CdcS3List",
         "Effect": "Allow",
         "Action": ["s3:ListBucket", "s3:GetBucketLocation"],
         "Resource": "arn:aws:s3:::cdc-pipeline-events-<your-suffix>"
       }
     ]
   }
   ```
4. Role name: `cdc-pipeline-ec2`.

## 4. EC2 (t3.micro, free tier)

1. Console → EC2 → **Launch instance**.
2. Name: `cdc-pipeline`.
3. AMI: Amazon Linux 2023.
4. Instance type: `t3.micro` (free tier).
5. Key pair: use or create one.
6. Network: same VPC as RDS; create a new SG `cdc-ec2-sg` allowing your IP on SSH (22) and Connect REST (8083) only from your IP.
7. Storage: default 8 GB gp3 is fine.
8. Advanced → **IAM instance profile**: `cdc-pipeline-ec2`.
9. Launch.

**Allow EC2 → RDS**: edit the `cdc-pg-sg` inbound rules, add one rule for port 5432 sourced from `cdc-ec2-sg`.

## 5. Bootstrap the EC2

SSH in, then:

```bash
sudo dnf install -y git postgresql16 docker
sudo systemctl enable --now docker
sudo usermod -aG docker ec2-user && exec sg docker newgrp      # pick up group w/o logout

# Docker Compose v2 plugin
sudo mkdir -p /usr/local/lib/docker/cli-plugins
sudo curl -SL https://github.com/docker/compose/releases/latest/download/docker-compose-linux-x86_64 \
  -o /usr/local/lib/docker/cli-plugins/docker-compose
sudo chmod +x /usr/local/lib/docker/cli-plugins/docker-compose

# uv for the Python script
curl -LsSf https://astral.sh/uv/install.sh | sh
. ~/.bashrc

# 1 GB swap file — t3.micro is tight with Kafka + Connect JVMs
sudo fallocate -l 1G /swapfile
sudo chmod 600 /swapfile
sudo mkswap /swapfile && sudo swapon /swapfile
echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab
```

Clone the repo:

```bash
git clone <your-repo-url> ~/cdc_pipeline
cd ~/cdc_pipeline
cp .env.example .env
# edit .env with real values
uv sync
```

Next: [`rds-logical-replication.md`](./rds-logical-replication.md) to set up
the Debezium role + publication, then [`kafka-setup.md`](./kafka-setup.md) to
bring Kafka + Connect online, then
[`deployment-and-verify.md`](./deployment-and-verify.md) to watch data flow
end-to-end.
