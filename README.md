# nyt-game-solvers

New York Times puzzle game solvers (Wordle, Connections), hosted as a static
site on AWS behind a Cognito login.

**Architecture:** private S3 bucket → CloudFront (+ Lambda@Edge enforcing a
Cognito session on every request) → visitors log in via the Cognito Hosted UI
(invite-only accounts). All infrastructure is Terraform; deployments run
through GitHub Actions using an OIDC role (no stored AWS keys).

See [nyt-game-solvers-plan.md](nyt-game-solvers-plan.md) for the full
step-by-step implementation plan.

## Repository layout

```
├── site/                       # everything deployed to S3
│   ├── index.html              # games landing page
│   ├── connections-solver.html
│   └── wordle-solver.html
├── lambda/
│   └── auth/                   # Lambda@Edge auth function (cognito-at-edge)
├── infra/                      # main Terraform config (remote state in S3)
│   └── bootstrap/              # one-time bootstrap: state bucket + CI role
└── .github/
    └── workflows/              # pr-validate.yml (PRs), deploy.yml (main)
```

## Workflow

- Open a pull request → the **Validate** workflow runs `terraform fmt`,
  `validate`, and `plan`.
- Merge to `main` → the **Deploy** workflow applies the Terraform, syncs
  `site/` to S3, and invalidates the CloudFront cache.

## Adding a game

1. Drop the new self-contained HTML file into `site/`.
2. Add a card linking to it in `site/index.html`.
3. Open a PR and merge — the pipeline does the rest.

## Managing users

Self-signup is disabled. Create users via the Cognito console or:

```powershell
aws cognito-idp admin-create-user `
  --region eu-west-1 `
  --user-pool-id <pool-id> `
  --username someone@example.com `
  --user-attributes Name=email,Value=someone@example.com Name=email_verified,Value=true
```
