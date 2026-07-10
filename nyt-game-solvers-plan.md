# NYT Game Solvers — Implementation Plan

A step-by-step plan for hosting the **Wordle Solver** and **Connections Solver** as a secured static "games page" on AWS.

| Requirement | How it's met |
|---|---|
| Static site hosted in S3 | Private S3 bucket served through CloudFront |
| Publicly reachable but behind a login | CloudFront + Lambda@Edge enforcing an AWS Cognito session on **every** request |
| Identity via AWS Cognito | Cognito User Pool with Hosted UI, invite-only accounts |
| Source in GitHub `nyt-game-solvers` | New repository under your personal GitHub account |
| CI/CD on every change | GitHub Actions: PRs are validated, merges to `main` deploy to production |
| All infrastructure as code | Terraform (≥ 1.10), remote state in S3 |
| Cost effective | Serverless throughout; ~£0–1/month at personal usage (see §2) |

**Confirmed decisions:** Terraform · edge-enforced auth · invite-only users · default `*.cloudfront.net` URL (no custom domain) · primary region `eu-west-1` (Ireland) · GitHub OIDC role for CI (no stored AWS keys) · deploy on push to `main`.

---

## 1. Architecture overview

### Why not "just S3 static website hosting"?

S3's static website hosting mode serves every object to anyone — it has no concept of a session or login. To put a real lock on a static site you must place **CloudFront** in front of a **private** S3 bucket and check the visitor's identity **at the edge, before the file is served**:

```
Browser ──> CloudFront edge
              │
              ├─ Lambda@Edge (viewer-request): valid Cognito session cookie?
              │     ├─ NO  ──> 302 redirect to Cognito Hosted UI login page
              │     │            (user logs in, Cognito redirects back with a code,
              │     │             Lambda@Edge exchanges it for JWTs, sets cookies)
              │     └─ YES ──> continue
              │
              └──> S3 bucket (private; readable only by CloudFront via
                   Origin Access Control — direct bucket URLs return 403)
```

An unauthenticated user can never fetch even one byte of HTML. This is a genuine lock, unlike a JavaScript "login screen" bolted onto a public bucket (which anyone can bypass with `curl`).

### Components

| Component | Region | Purpose |
|---|---|---|
| S3 bucket `nyt-game-solvers-site-<account-id>` | eu-west-1 | Holds `index.html` + the two solver pages. All public access blocked. |
| CloudFront distribution | global | HTTPS entry point (`https://dxxxxxxxx.cloudfront.net`), caches content, runs the auth check. |
| CloudFront Origin Access Control (OAC) | global | Lets *only* this distribution read the bucket. |
| Cognito User Pool + Hosted UI domain + app client | eu-west-1 | Stores users, renders the login page, issues JWTs. Self-signup **disabled**. |
| Lambda@Edge function (`cognito-at-edge`) | **us-east-1** (CloudFront requirement) | Viewer-request handler: validates the session, handles the OAuth code exchange, sets cookies. |
| SSM Parameter `/nyt-game-solvers/auth-config` | us-east-1 | Runtime config for the edge function (see the note below). |
| S3 bucket `nyt-game-solvers-tfstate-<account-id>` | eu-west-1 | Terraform remote state (native S3 locking — no DynamoDB table needed). |
| GitHub OIDC provider + IAM role `nyt-game-solvers-deploy` | global (IAM) | Lets GitHub Actions deploy with short-lived credentials — no secrets stored in GitHub. |

> **Design note — why the SSM parameter?** Lambda@Edge does not support environment variables, and there is a dependency cycle if you bake config in: the Cognito app client's callback URL needs the CloudFront domain, CloudFront needs the Lambda's ARN, and the Lambda would need the app client ID. Storing the Cognito IDs in an SSM parameter that the function reads once at cold start breaks the cycle, so **a single `terraform apply` builds everything** — essential for a hands-off CI/CD pipeline.

---

## 2. Estimated monthly cost

At personal/family traffic levels (a handful of users, a few hundred page views/month):

| Service | Cost |
|---|---|
| Cognito | Free — well under the free monthly-active-user allowance |
| CloudFront | Free — always-free tier includes 1 TB data transfer + 10M requests/month |
| Lambda@Edge | ~£0 — pennies per million requests; you'll use thousands |
| S3 (site + state) | < £0.05 — a few MB of storage, minimal requests |
| SSM Parameter Store | Free (standard parameter) |
| **Total** | **~£0–1 / month** |

There are no fixed/hourly charges anywhere in this design — everything is pay-per-request. Add an AWS Budget alert (see §11) as a safety net.

---

## 3. Prerequisites

1. **AWS account** with admin access for the one-time bootstrap (Step 2).
2. **AWS CLI v2** installed and configured (`aws configure`) — used for bootstrap and user creation.
3. **Terraform ≥ 1.10** (needed for native S3 state locking).
4. **Node.js 20+ and npm** — to install the edge function's dependency locally and in CI.
5. **Git + a personal GitHub account.**
6. Your **AWS account ID** (`aws sts get-caller-identity --query Account --output text`) — substitute it wherever you see `<ACCOUNT_ID>` below, and your GitHub username for `<GITHUB_USER>`.

---

## 4. Step 1 — Create the GitHub repository

Create a repository named **`nyt-game-solvers`** under your personal account (private or public — the site's security does not depend on the repo being private, but keep it **private** if you may ever commit anything sensitive).

Repository layout:

```
nyt-game-solvers/
├── site/                          # everything deployed to S3
│   ├── index.html                 # NEW games landing page (Step 4)
│   ├── connections-solver.html    # copied unchanged from C:\Repos
│   └── wordle-solver.html         # copied unchanged from C:\Repos
├── lambda/
│   └── auth/                      # Lambda@Edge source
│       ├── index.js
│       ├── package.json
│       └── package-lock.json      # commit this — CI uses `npm ci`
├── infra/                         # main Terraform config (remote state)
│   ├── providers.tf
│   ├── variables.tf
│   ├── s3.tf
│   ├── cloudfront.tf
│   ├── cognito.tf
│   ├── lambda-edge.tf
│   ├── ssm.tf
│   ├── outputs.tf
│   └── bootstrap/                 # one-time bootstrap config (local state)
│       └── main.tf
├── .github/
│   └── workflows/
│       ├── pr-validate.yml
│       └── deploy.yml
├── .gitignore                     # node_modules/, *.zip, .terraform/, *.tfstate*
└── README.md
```

Set a **branch protection rule on `main`** (Settings → Branches): require a pull request and require the "Validate" status check to pass. This makes the PR-validate workflow a real gate.

---

## 5. Step 2 — One-time bootstrap (state bucket + CI role)

Terraform needs an S3 bucket to store its state in, and GitHub Actions needs an IAM role to assume — but those can't be created by the pipeline that depends on them. So a **small separate Terraform config with local state** creates them once, run from your machine with your admin credentials. It is kept in the repo (`infra/bootstrap/`) for documentation and future changes.

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
  github_repo = "<GITHUB_USER>/nyt-game-solvers"
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

resource "aws_iam_role_policy" "deploy" {
  name = "deploy-permissions"
  role = aws_iam_role.deploy.id

  # Scoped to the services this stack manages. Tighten to specific
  # resource ARNs once the stack is stable, if desired.
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "ManageStack"
        Effect = "Allow"
        Action = [
          "s3:*", "cloudfront:*", "cognito-idp:*",
          "lambda:*", "ssm:*", "logs:*"
        ]
        Resource = "*"
      },
      {
        Sid    = "ManageLambdaEdgeRole"
        Effect = "Allow"
        Action = ["iam:*"]
        Resource = [
          "arn:aws:iam::${local.account_id}:role/nyt-game-solvers-*",
          "arn:aws:iam::${local.account_id}:policy/nyt-game-solvers-*"
        ]
      },
      {
        Sid      = "ReadOnlyIam"
        Effect   = "Allow"
        Action   = ["iam:GetRole", "iam:ListRoles", "iam:GetOpenIDConnectProvider"]
        Resource = "*"
      }
    ]
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

Note the `deploy_role_arn` output — it goes into both workflow files. Commit the bootstrap config; add `infra/bootstrap/terraform.tfstate*` to `.gitignore` (or migrate its state into the new bucket later).

---

## 6. Step 3 — Core Terraform (the whole stack, one apply)

### 6.1 `infra/providers.tf`

```hcl
terraform {
  required_version = ">= 1.10"
  required_providers {
    aws     = { source = "hashicorp/aws", version = "~> 5.80" }
    archive = { source = "hashicorp/archive", version = "~> 2.6" }
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

# Lambda@Edge, its IAM/SSM config, and anything CloudFront-attached
# must live in us-east-1.
provider "aws" {
  alias  = "us_east_1"
  region = "us-east-1"
}

data "aws_caller_identity" "current" {}

locals {
  name       = "nyt-game-solvers"
  account_id = data.aws_caller_identity.current.account_id
}
```

### 6.2 `infra/s3.tf` — private site bucket

```hcl
resource "aws_s3_bucket" "site" {
  bucket = "${local.name}-site-${local.account_id}"
}

resource "aws_s3_bucket_public_access_block" "site" {
  bucket                  = aws_s3_bucket.site.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Only this CloudFront distribution may read objects.
resource "aws_s3_bucket_policy" "site" {
  bucket = aws_s3_bucket.site.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "AllowCloudFrontOAC"
      Effect    = "Allow"
      Principal = { Service = "cloudfront.amazonaws.com" }
      Action    = "s3:GetObject"
      Resource  = "${aws_s3_bucket.site.arn}/*"
      Condition = {
        StringEquals = { "AWS:SourceArn" = aws_cloudfront_distribution.site.arn }
      }
    }]
  })
}
```

### 6.3 `infra/cognito.tf` — user pool, hosted UI, app client

```hcl
resource "aws_cognito_user_pool" "users" {
  name = local.name

  # Invite-only: nobody can self-register.
  admin_create_user_config {
    allow_admin_create_user_only = true
  }

  username_attributes      = ["email"]
  auto_verified_attributes = ["email"]

  password_policy {
    minimum_length    = 12
    require_lowercase = true
    require_uppercase = true
    require_numbers   = true
    require_symbols   = false
  }

  account_recovery_setting {
    recovery_mechanism {
      name     = "verified_email"
      priority = 1
    }
  }
}

# Hosted UI login page lives at:
#   https://<domain>.auth.eu-west-1.amazoncognito.com
# The prefix must be globally unique — adjust if taken.
resource "aws_cognito_user_pool_domain" "users" {
  domain       = "${local.name}-${local.account_id}"
  user_pool_id = aws_cognito_user_pool.users.id
}

resource "aws_cognito_user_pool_client" "site" {
  name         = "${local.name}-site"
  user_pool_id = aws_cognito_user_pool.users.id

  generate_secret                      = false
  allowed_oauth_flows_user_pool_client = true
  allowed_oauth_flows                  = ["code"]
  allowed_oauth_scopes                 = ["openid", "email"]
  supported_identity_providers         = ["COGNITO"]
  prevent_user_existence_errors        = "ENABLED"

  callback_urls = ["https://${aws_cloudfront_distribution.site.domain_name}"]
  logout_urls   = ["https://${aws_cloudfront_distribution.site.domain_name}"]

  access_token_validity  = 1   # hours
  id_token_validity      = 1
  refresh_token_validity = 30  # days
}
```

### 6.4 `infra/lambda-edge.tf` — the auth function

```hcl
# CI runs `npm ci` in lambda/auth before terraform, so node_modules
# is present when this zip is built.
data "archive_file" "auth" {
  type        = "zip"
  source_dir  = "${path.module}/../lambda/auth"
  output_path = "${path.module}/.build/auth.zip"
}

resource "aws_iam_role" "auth_lambda" {
  name = "${local.name}-auth-edge"

  # Lambda@Edge requires BOTH principals.
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = ["lambda.amazonaws.com", "edgelambda.amazonaws.com"] }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "auth_lambda" {
  name = "auth-edge-permissions"
  role = aws_iam_role.auth_lambda.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        # Replicated functions log in whichever region serves the viewer.
        Effect   = "Allow"
        Action   = ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = "arn:aws:logs:*:${local.account_id}:*"
      },
      {
        Effect   = "Allow"
        Action   = ["ssm:GetParameter"]
        Resource = aws_ssm_parameter.auth_config.arn
      }
    ]
  })
}

resource "aws_lambda_function" "auth" {
  provider = aws.us_east_1

  function_name    = "${local.name}-auth"
  role             = aws_iam_role.auth_lambda.arn
  runtime          = "nodejs20.x"
  handler          = "index.handler"
  filename         = data.archive_file.auth.output_path
  source_code_hash = data.archive_file.auth.output_base64sha256

  publish     = true  # Lambda@Edge attaches a *version*, not $LATEST
  memory_size = 128   # viewer-request maximums
  timeout     = 5
}
```

### 6.5 `infra/ssm.tf` — runtime config for the edge function

```hcl
resource "aws_ssm_parameter" "auth_config" {
  provider = aws.us_east_1

  name = "/${local.name}/auth-config"
  type = "String"
  value = jsonencode({
    region         = "eu-west-1"
    userPoolId     = aws_cognito_user_pool.users.id
    userPoolAppId  = aws_cognito_user_pool_client.site.id
    userPoolDomain = "${aws_cognito_user_pool_domain.users.domain}.auth.eu-west-1.amazoncognito.com"
  })
}
```

### 6.6 `infra/cloudfront.tf` — distribution + OAC + auth hook

```hcl
resource "aws_cloudfront_origin_access_control" "site" {
  name                              = local.name
  origin_access_control_origin_type = "s3"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}

# AWS managed cache policy: "CachingOptimized"
data "aws_cloudfront_cache_policy" "caching_optimized" {
  name = "Managed-CachingOptimized"
}

resource "aws_cloudfront_distribution" "site" {
  enabled             = true
  comment             = local.name
  default_root_object = "index.html"
  price_class         = "PriceClass_100" # EU + North America edges only — cheapest

  origin {
    origin_id                = "s3-site"
    domain_name              = aws_s3_bucket.site.bucket_regional_domain_name
    origin_access_control_id = aws_cloudfront_origin_access_control.site.id
  }

  default_cache_behavior {
    target_origin_id       = "s3-site"
    viewer_protocol_policy = "redirect-to-https"
    allowed_methods        = ["GET", "HEAD"]
    cached_methods         = ["GET", "HEAD"]
    cache_policy_id        = data.aws_cloudfront_cache_policy.caching_optimized.id
    compress               = true

    # The lock on the door: every request is authenticated first.
    lambda_function_association {
      event_type   = "viewer-request"
      lambda_arn   = aws_lambda_function.auth.qualified_arn
      include_body = false
    }
  }

  restrictions {
    geo_restriction { restriction_type = "none" }
  }

  viewer_certificate {
    cloudfront_default_certificate = true
  }
}
```

### 6.7 `infra/outputs.tf`

```hcl
output "site_url" {
  value = "https://${aws_cloudfront_distribution.site.domain_name}"
}
output "site_bucket" {
  value = aws_s3_bucket.site.bucket
}
output "distribution_id" {
  value = aws_cloudfront_distribution.site.id
}
output "user_pool_id" {
  value = aws_cognito_user_pool.users.id
}
```

### 6.8 The edge function code

`lambda/auth/package.json`:

```json
{
  "name": "nyt-game-solvers-auth",
  "private": true,
  "dependencies": {
    "cognito-at-edge": "^1.5.2"
  }
}
```

`lambda/auth/index.js`:

```js
// Lambda@Edge viewer-request handler.
// Config is read from SSM at cold start (Lambda@Edge has no env vars);
// the AWS SDK v3 SSM client is built into the nodejs20.x runtime.
const { Authenticator } = require('cognito-at-edge');
const { SSMClient, GetParameterCommand } = require('@aws-sdk/client-ssm');

let authenticator;

exports.handler = async (event) => {
  if (!authenticator) {
    const ssm = new SSMClient({ region: 'us-east-1' });
    const { Parameter } = await ssm.send(
      new GetParameterCommand({ Name: '/nyt-game-solvers/auth-config' })
    );
    const cfg = JSON.parse(Parameter.Value);
    authenticator = new Authenticator({
      region: cfg.region,
      userPoolId: cfg.userPoolId,
      userPoolAppId: cfg.userPoolAppId,
      userPoolDomain: cfg.userPoolDomain,
      cookieExpirationDays: 7,
      logLevel: 'warn',
    });
  }
  return authenticator.handle(event);
};
```

Run `npm install` once locally in `lambda/auth/` and commit the generated `package-lock.json` (CI depends on it). `node_modules/` stays git-ignored — it is rebuilt by `npm ci` in the pipeline before Terraform zips the directory.

---

## 7. Step 4 — Site content

1. Copy `connections-solver.html` and `wordle-solver.html` from `C:\Repos` into `site/` **unchanged**. (The Connections solver's optional "Solve with Claude" feature calls the Anthropic API directly from the browser with a user-supplied key — it keeps working exactly as-is behind the login; no backend required.)
2. Create `site/index.html` — the games landing page. Keep it in the same self-contained single-file style as the solvers: a title, and one card per game linking to the solver page, with light/dark support via `prefers-color-scheme`. Skeleton:

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

      - uses: actions/setup-node@v4
        with:
          node-version: 20

      - name: Install edge function dependencies
        working-directory: lambda/auth
        run: npm ci

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

*(Optional polish: pipe the plan into a PR comment with `borchero/terraform-plan-comment` or similar.)*

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

      - uses: actions/setup-node@v4
        with:
          node-version: 20

      - name: Install edge function dependencies
        working-directory: lambda/auth
        run: npm ci

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
          echo "dist_id=$(terraform output -raw distribution_id)" >> "$GITHUB_OUTPUT"
          echo "url=$(terraform output -raw site_url)" >> "$GITHUB_OUTPUT"

      - name: Sync site content to S3
        run: aws s3 sync site/ "s3://${{ steps.tf.outputs.bucket }}" --delete

      - name: Invalidate CloudFront cache
        run: |
          aws cloudfront create-invalidation \
            --distribution-id "${{ steps.tf.outputs.dist_id }}" \
            --paths "/*"

      - name: Site URL
        run: echo "Deployed to ${{ steps.tf.outputs.url }}"
```

*(CloudFront includes 1,000 free invalidation paths/month — `"/*"` counts as one path, so this costs nothing at this cadence.)*

---

## 9. Step 6 — First deployment & creating users

1. Commit everything and push to `main` (or open a PR first to exercise the validate workflow). The deploy workflow will:
   - build the Lambda zip, `terraform apply` the whole stack (first CloudFront + Lambda@Edge creation takes **5–15 minutes** — normal),
   - sync `site/` to the bucket and invalidate the cache.
2. Get the site URL from the workflow's final step (or `terraform output site_url` locally).
3. **Create your users** (invite-only, so this is the only way in). Per user:

   ```powershell
   aws cognito-idp admin-create-user `
     --region eu-west-1 `
     --user-pool-id <user_pool_id output> `
     --username someone@example.com `
     --user-attributes Name=email,Value=someone@example.com Name=email_verified,Value=true
   ```

   Cognito emails them a temporary password. On first visit they log in at the Hosted UI and are forced to set a permanent password. (You can also do this in the AWS Console: Cognito → your pool → Users → *Create user*.)

---

## 10. Step 7 — Verification checklist

Work through all of these before calling it done:

- [ ] **Anonymous visit** — open the CloudFront URL in a private/incognito window: you are redirected to the Cognito Hosted UI login page, and **no game content is visible**.
- [ ] **Deep link protection** — `curl -I https://<dist>.cloudfront.net/wordle-solver.html` (no cookies) returns a `302` to Cognito, **not** `200` with content.
- [ ] **Bucket is sealed** — `https://<bucket>.s3.eu-west-1.amazonaws.com/index.html` returns `403 Access Denied`.
- [ ] **Login works** — sign in with a created user; you land back on the games page; both solvers load and function (localStorage persistence, tile interactions, keyboard).
- [ ] **Session persists** — close and reopen the browser within the cookie lifetime; no re-login needed.
- [ ] **Wrong password / unknown user is rejected** at the Hosted UI.
- [ ] **CI gate** — open a PR with a trivial change: the Validate workflow runs `fmt`/`validate`/`plan` and blocks merging until green.
- [ ] **CD** — merge the PR: the Deploy workflow applies, syncs, invalidates; the change is live at the URL within a minute or two of the workflow finishing.
- [ ] **No secrets in GitHub** — repo Settings → Secrets shows no AWS keys (OIDC only).

---

## 11. Ongoing operations

- **Add a game:** drop the new HTML file in `site/`, add a card to `index.html`, open a PR, merge. Nothing else.
- **Add / remove users:** `admin-create-user` (above) / `aws cognito-idp admin-delete-user`, or the Cognito console. No deploy needed.
- **Sign out:** cognito-at-edge supports a logout route — add `logoutConfiguration: { logoutUri: '/signout', logoutRedirectUri: 'https://<dist>.cloudfront.net' }` to the `Authenticator` options (values via the SSM parameter) and link "Sign out" to `/signout` from `index.html` if wanted.
- **Rotate nothing:** there are no long-lived credentials anywhere in this design.
- **Teardown:** `terraform destroy` in `infra/`, then the bootstrap config. **Caveat:** Lambda@Edge replicas take from ~30 minutes up to a few hours to drain after the CloudFront association is removed — if destroy fails on the Lambda function, simply re-run it later.

## 12. Future enhancements (optional, all IaC-able)

- **Custom domain** — Route 53 + free ACM certificate (cert must be in us-east-1 for CloudFront); update Cognito callback URLs.
- **AWS Budget alarm** — e.g. alert at £5/month as a cost tripwire.
- **Staging environment** — second Terraform workspace/state key + a `develop` branch workflow.
- **WAF on CloudFront** — rate limiting / geo rules (adds ~$6+/month, likely unnecessary behind auth).
- **Terraform module split** — refactor into modules if the stack grows beyond this single site.
