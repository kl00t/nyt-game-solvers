# NYT Game Solvers — Implementation Plan

A step-by-step plan for hosting the **Wordle Solver** and **Connections Solver** as a public "games page" — a static website served directly from an S3 bucket.

| Requirement | How it's met |
|---|---|
| Static site hosted in S3 | S3 bucket with static website hosting enabled, publicly readable |
| Openly accessible on the web | Public bucket policy — no login, no restrictions |
| Source in GitHub `nyt-game-solvers` | Repository under your personal GitHub account: `kl00t/nyt-game-solvers` |
| CI/CD on every change | GitHub Actions: PRs are validated, merges to `main` deploy to production |
| All infrastructure as code | Terraform (≥ 1.10), remote state in S3 |
| Cost effective | ~£0.05/month — S3 storage and request pennies only |

**Confirmed decisions:** Terraform · **no authentication — fully public site** · S3 website endpoint URL (no custom domain) · region `eu-west-1` (Ireland) · GitHub OIDC role for CI (no stored AWS keys) · deploy on push to `main`.

> **Revision note:** an earlier version of this plan secured the site behind a Cognito login enforced by CloudFront + Lambda@Edge. That requirement has been removed — the site is now intentionally public, which eliminates Cognito, Lambda@Edge, CloudFront, and the SSM parameter entirely. If login is ever wanted again, the previous architecture is in this file's git history.

---

## 1. Architecture overview

```
Browser ──HTTP──> S3 static website endpoint
                  http://<bucket>.s3-website-eu-west-1.amazonaws.com
                  (public-read bucket policy; serves index.html
                   and the two solver pages directly)
```

That's the whole runtime architecture. S3's static website hosting mode serves objects to anyone over HTTP with `index.html` as the default document.

### Components

| Component | Region | Purpose |
|---|---|---|
| S3 bucket `nyt-game-solvers-site-<account-id>` | eu-west-1 | Holds and serves `index.html` + the two solver pages. Website hosting enabled, public read. |
| S3 bucket `nyt-game-solvers-tfstate-<account-id>` | eu-west-1 | Terraform remote state (native S3 locking — no DynamoDB table needed). Private. |
| GitHub OIDC provider + IAM role `nyt-game-solvers-deploy` | global (IAM) | Lets GitHub Actions deploy with short-lived credentials — no secrets stored in GitHub. |

### Known trade-off: HTTP only

S3 website endpoints **do not support HTTPS**. Visitors get a plain-HTTP URL and browsers may show "Not secure" in the address bar. For a public puzzle-helper page with no accounts and no sensitive data this is acceptable; if you later want HTTPS (or a custom domain), put CloudFront in front of the bucket — see §12. Everything else in this plan stays the same if you do.

> The Connections solver's optional "Solve with Claude" feature sends the user's API key from the browser straight to `api.anthropic.com` over HTTPS — that call is encrypted regardless of the page being served over HTTP. Even so, if you expect real use of that feature, the CloudFront/HTTPS enhancement is worth doing so the page itself can't be tampered with in transit.

---

## 2. Estimated monthly cost

| Service | Cost |
|---|---|
| S3 storage (site + state) | < £0.01 — a few hundred KB |
| S3 requests / data transfer | Pennies at personal traffic; first 100 GB/month of transfer out is free-tier |
| IAM / OIDC | Free |
| **Total** | **~£0–0.05 / month** |

No fixed or hourly charges anywhere. Add an AWS Budget alert (§12) as a safety net.

---

## 3. Prerequisites

1. **AWS account** with admin access for the one-time bootstrap (Step 2).
2. **AWS CLI v2** installed and configured (`aws configure`).
3. **Terraform ≥ 1.10** (needed for native S3 state locking).
4. **Git + your GitHub account** (repo already exists: `kl00t/nyt-game-solvers`).
5. Your **AWS account ID** (`aws sts get-caller-identity --query Account --output text`) — substitute wherever you see `<ACCOUNT_ID>`.

---

## 4. Step 1 — Repository structure  ✅ (done)

Repository layout:

```
nyt-game-solvers/
├── site/                          # everything deployed to S3
│   ├── index.html                 # games landing page (Step 4)
│   ├── connections-solver.html
│   └── wordle-solver.html
├── infra/                         # main Terraform config (remote state)
│   ├── providers.tf
│   ├── s3.tf
│   ├── outputs.tf
│   └── bootstrap/                 # one-time bootstrap config (local state)
│       └── main.tf
├── .github/
│   └── workflows/
│       ├── pr-validate.yml
│       └── deploy.yml
├── .gitignore                     # .terraform/, *.tfstate*, etc.
└── README.md
```

This step has been completed (the `lambda/` folder created for the earlier authenticated design is no longer needed and has been removed).

**Branch protection:** not used — enforced branch protection isn't available on this repository's GitHub plan. Work via pull requests by convention: the Validate workflow still runs on every PR and shows a pass/fail status, it just can't hard-block the merge. Anything pushed or merged to `main` deploys to production.

---

## 5. Step 2 — One-time bootstrap (state bucket + CI role)

Terraform needs an S3 bucket for its state, and GitHub Actions needs an IAM role to assume — neither can be created by the pipeline that depends on them. A **small separate Terraform config with local state** creates them once, run from your machine with admin credentials.

`infra/bootstrap/main.tf`:

```hcl
terraform {
  required_version = ">= 1.10"
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 5.80" }
  }
}

provider "aws" {
  region = "eu-west-1"
}

data "aws_caller_identity" "current" {}

locals {
  account_id  = data.aws_caller_identity.current.account_id
  github_repo = "kl00t/nyt-game-solvers"
}

# ---- Terraform remote state bucket ----
resource "aws_s3_bucket" "tfstate" {
  bucket = "nyt-game-solvers-tfstate-${local.account_id}"
}

resource "aws_s3_bucket_versioning" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id
  versioning_configuration { status = "Enabled" }
}

resource "aws_s3_bucket_public_access_block" "tfstate" {
  bucket                  = aws_s3_bucket.tfstate.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id
  rule {
    apply_server_side_encryption_by_default { sse_algorithm = "AES256" }
  }
}

# ---- GitHub Actions OIDC provider ----
resource "aws_iam_openid_connect_provider" "github" {
  url             = "https://token.actions.githubusercontent.com"
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = ["6938fd4d98bab03faadb97b34396831e3780aea1"]
}

# ---- Deploy role assumable only by this repo's workflows ----
resource "aws_iam_role" "deploy" {
  name = "nyt-game-solvers-deploy"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Federated = aws_iam_openid_connect_provider.github.arn }
      Action    = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
        }
        StringLike = {
          "token.actions.githubusercontent.com:sub" = "repo:${local.github_repo}:*"
        }
      }
    }]
  })
}

# The stack is S3-only, so the deploy role is S3-only.
resource "aws_iam_role_policy" "deploy" {
  name = "deploy-permissions"
  role = aws_iam_role.deploy.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid    = "ManageSiteAndState"
      Effect = "Allow"
      Action = ["s3:*"]
      Resource = [
        aws_s3_bucket.tfstate.arn,
        "${aws_s3_bucket.tfstate.arn}/*",
        "arn:aws:s3:::nyt-game-solvers-site-${local.account_id}",
        "arn:aws:s3:::nyt-game-solvers-site-${local.account_id}/*"
      ]
    }]
  })
}

output "deploy_role_arn" { value = aws_iam_role.deploy.arn }
output "state_bucket"    { value = aws_s3_bucket.tfstate.bucket }
```

Run once from your machine:

```powershell
cd infra/bootstrap
terraform init
terraform apply
```

Note the `deploy_role_arn` output — it goes into both workflow files. The local bootstrap state files are already covered by the `*.tfstate*` rule in `.gitignore`.

> **Account-level check:** in the S3 console → *Block Public Access settings for this account*, make sure account-wide blocking is **off** (bucket-level settings are managed by Terraform), otherwise the public bucket policy in Step 3 will be rejected no matter what Terraform does.

---

## 6. Step 3 — Core Terraform (the public website bucket)

### 6.1 `infra/providers.tf`

```hcl
terraform {
  required_version = ">= 1.10"
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 5.80" }
  }

  backend "s3" {
    bucket       = "nyt-game-solvers-tfstate-<ACCOUNT_ID>"
    key          = "prod/terraform.tfstate"
    region       = "eu-west-1"
    use_lockfile = true   # native S3 locking, no DynamoDB table
    encrypt      = true
  }
}

provider "aws" {
  region = "eu-west-1"
}

data "aws_caller_identity" "current" {}

locals {
  name       = "nyt-game-solvers"
  account_id = data.aws_caller_identity.current.account_id
}
```

### 6.2 `infra/s3.tf` — public static website bucket

```hcl
resource "aws_s3_bucket" "site" {
  bucket = "${local.name}-site-${local.account_id}"
}

resource "aws_s3_bucket_website_configuration" "site" {
  bucket = aws_s3_bucket.site.id

  index_document { suffix = "index.html" }
  error_document { key = "index.html" } # fall back to the games page
}

# Public website: bucket-level blocking must be off so the
# public-read policy below can attach.
resource "aws_s3_bucket_public_access_block" "site" {
  bucket                  = aws_s3_bucket.site.id
  block_public_acls       = false
  block_public_policy     = false
  ignore_public_acls      = false
  restrict_public_buckets = false
}

resource "aws_s3_bucket_policy" "site" {
  bucket = aws_s3_bucket.site.id

  # The policy must attach *after* the public-access block is relaxed.
  depends_on = [aws_s3_bucket_public_access_block.site]

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "PublicReadGetObject"
      Effect    = "Allow"
      Principal = "*"
      Action    = "s3:GetObject"
      Resource  = "${aws_s3_bucket.site.arn}/*"
    }]
  })
}
```

### 6.3 `infra/outputs.tf`

```hcl
output "site_url" {
  value = "http://${aws_s3_bucket_website_configuration.site.website_endpoint}"
}
output "site_bucket" {
  value = aws_s3_bucket.site.bucket
}
```

---

## 7. Step 4 — Site content

1. `site/connections-solver.html` and `site/wordle-solver.html` are already in place, unchanged. (The Connections solver's optional "Solve with Claude" feature calls the Anthropic API directly from the browser with a user-supplied key — no backend required.)
2. Fill in `site/index.html` — the games landing page. Keep it in the same self-contained single-file style as the solvers: a title and one card per game, with light/dark support via `prefers-color-scheme`. Skeleton:

```html
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>NYT Game Solvers</title>
<style>
  :root { --bg:#fafafa; --surface:#fff; --text:#121212; --muted:#6b6b6b; --border:#dcdcdc; }
  @media (prefers-color-scheme: dark) {
    :root { --bg:#161616; --surface:#222; --text:#f0f0f0; --muted:#9a9a9a; --border:#3a3a3a; }
  }
  body { font-family:"Segoe UI",system-ui,sans-serif; background:var(--bg); color:var(--text);
         min-height:100vh; margin:0; padding:40px 16px; }
  .wrap { max-width:640px; margin:0 auto; text-align:center; }
  h1 { letter-spacing:.5px; }
  .games { display:grid; gap:16px; grid-template-columns:repeat(auto-fit,minmax(240px,1fr)); margin-top:28px; }
  a.card { display:block; background:var(--surface); border:1px solid var(--border); border-radius:12px;
           padding:28px 20px; text-decoration:none; color:inherit; transition:transform .1s, box-shadow .1s; }
  a.card:hover { transform:translateY(-2px); box-shadow:0 6px 18px rgba(0,0,0,.12); }
  .card .emoji { font-size:2.2rem; }
  .card h2 { margin:10px 0 6px; font-size:1.1rem; }
  .card p { color:var(--muted); font-size:.85rem; margin:0; }
</style>
</head>
<body>
<div class="wrap">
  <h1>🎮 NYT Game Solvers</h1>
  <p>Pick a puzzle to work on.</p>
  <div class="games">
    <a class="card" href="wordle-solver.html">
      <div class="emoji">🟩</div><h2>Wordle Solver</h2>
      <p>Ranked next-guess suggestions from your board.</p>
    </a>
    <a class="card" href="connections-solver.html">
      <div class="emoji">🟪</div><h2>Connections Solver</h2>
      <p>A workspace for grouping the 16 words, with optional AI assist.</p>
    </a>
  </div>
</div>
</body>
</html>
```

Adding a future game is then just: drop `newgame.html` into `site/`, add a card to `index.html`, open a PR.

---

## 8. Step 5 — GitHub Actions workflows

Both workflows authenticate with the OIDC deploy role — **no AWS secrets are stored in GitHub**. Replace `<ACCOUNT_ID>` with your account ID (or store the role ARN as a repo *variable* `AWS_DEPLOY_ROLE_ARN` and reference `${{ vars.AWS_DEPLOY_ROLE_ARN }}`).

### 8.1 `.github/workflows/pr-validate.yml`

```yaml
name: Validate

on:
  pull_request:
    branches: [main]

permissions:
  id-token: write   # OIDC token for AWS
  contents: read

env:
  AWS_REGION: eu-west-1
  TF_IN_AUTOMATION: "true"

jobs:
  validate:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - uses: hashicorp/setup-terraform@v3

      - uses: aws-actions/configure-aws-credentials@v4
        with:
          role-to-assume: arn:aws:iam::<ACCOUNT_ID>:role/nyt-game-solvers-deploy
          aws-region: ${{ env.AWS_REGION }}

      - name: Terraform format check
        working-directory: infra
        run: terraform fmt -check -recursive

      - name: Terraform init
        working-directory: infra
        run: terraform init -input=false

      - name: Terraform validate
        working-directory: infra
        run: terraform validate

      - name: Terraform plan
        working-directory: infra
        run: terraform plan -input=false -no-color
```

### 8.2 `.github/workflows/deploy.yml`

```yaml
name: Deploy

on:
  push:
    branches: [main]

permissions:
  id-token: write
  contents: read

# Never run two production deploys at once; queue instead.
concurrency:
  group: deploy-production
  cancel-in-progress: false

env:
  AWS_REGION: eu-west-1
  TF_IN_AUTOMATION: "true"

jobs:
  deploy:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - uses: hashicorp/setup-terraform@v3
        with:
          terraform_wrapper: false   # so `terraform output -raw` works cleanly

      - uses: aws-actions/configure-aws-credentials@v4
        with:
          role-to-assume: arn:aws:iam::<ACCOUNT_ID>:role/nyt-game-solvers-deploy
          aws-region: ${{ env.AWS_REGION }}

      - name: Terraform init
        working-directory: infra
        run: terraform init -input=false

      - name: Terraform apply (infrastructure)
        working-directory: infra
        run: terraform apply -input=false -auto-approve

      - name: Read Terraform outputs
        id: tf
        working-directory: infra
        run: |
          echo "bucket=$(terraform output -raw site_bucket)" >> "$GITHUB_OUTPUT"
          echo "url=$(terraform output -raw site_url)" >> "$GITHUB_OUTPUT"

      - name: Sync site content to S3
        run: aws s3 sync site/ "s3://${{ steps.tf.outputs.bucket }}" --delete

      - name: Site URL
        run: echo "Deployed to ${{ steps.tf.outputs.url }}"
```

No cache invalidation step is needed — with no CDN in front, S3 serves the newly synced files immediately.

---

## 9. Step 6 — First deployment

1. Commit everything and push to `main` (or open a PR first to exercise the validate workflow). The deploy workflow will `terraform apply` the bucket and sync `site/` into it — the whole run takes under a minute.
2. Get the site URL from the workflow's final step, or locally:

   ```powershell
   cd infra
   terraform output site_url
   # http://nyt-game-solvers-site-<account-id>.s3-website-eu-west-1.amazonaws.com
   ```
3. Open it in a browser — the games page should load for anyone, no login.

---

## 10. Step 7 — Verification checklist

- [ ] **Site loads publicly** — the website endpoint URL opens the games landing page in any browser, no credentials.
- [ ] **Both solvers work** — tiles, keyboard input, localStorage persistence, and (optionally) the Connections AI assist.
- [ ] **Default document** — visiting the bare URL (no `/index.html`) serves the landing page.
- [ ] **State bucket is private** — `https://nyt-game-solvers-tfstate-<account-id>.s3.eu-west-1.amazonaws.com/prod/terraform.tfstate` returns `403 Access Denied`.
- [ ] **CI check** — open a PR with a trivial change: the Validate workflow runs `fmt`/`validate`/`plan` and reports its status on the PR (advisory only — no branch protection on this plan, so check it's green before merging).
- [ ] **CD** — merge the PR: the Deploy workflow applies and syncs; the change is live at the URL as soon as the workflow finishes.
- [ ] **No secrets in GitHub** — repo Settings → Secrets shows no AWS keys (OIDC only).

---

## 11. Ongoing operations

- **Add a game:** drop the new HTML file in `site/`, add a card to `index.html`, open a PR, merge. Nothing else.
- **Rotate nothing:** there are no long-lived credentials anywhere in this design.
- **Teardown:** empty the site bucket (`aws s3 rm s3://<bucket> --recursive`), `terraform destroy` in `infra/`, then the bootstrap config.

## 12. Future enhancements (optional, all IaC-able)

- **HTTPS + caching** — put CloudFront (with Origin Access Control and the free default certificate) in front of the bucket. This is the first thing to add if the site gets real traffic or you want the padlock. The bucket can then be made private again.
- **Custom domain** — Route 53 + free ACM certificate (requires the CloudFront enhancement; certs for CloudFront live in us-east-1).
- **AWS Budget alarm** — e.g. alert at £5/month as a cost tripwire.
- **Re-adding a login later** — the previous revision of this plan (in git history) documents the full CloudFront + Lambda@Edge + Cognito architecture.
- **Staging environment** — second Terraform state key + a `develop` branch workflow.
