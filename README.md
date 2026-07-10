# nyt-game-solvers

New York Times puzzle game solvers (Wordle, Connections), hosted as a public
static website on AWS S3.

**Architecture:** a publicly readable S3 bucket with static website hosting —
no login, no CDN, nothing else. All infrastructure is Terraform; deployments
run through GitHub Actions using an OIDC role (no stored AWS keys).

See [nyt-game-solvers-plan.md](nyt-game-solvers-plan.md) for the full
step-by-step implementation plan.

## Repository layout

```
├── site/                       # everything deployed to S3
│   ├── index.html              # games landing page
│   ├── connections-solver.html
│   └── wordle-solver.html
├── infra/                      # main Terraform config (remote state in S3)
│   └── bootstrap/              # one-time bootstrap: state bucket + CI role
└── .github/
    └── workflows/              # pr-validate.yml (PRs), deploy.yml (main)
```

## Workflow

- Open a pull request → the **Validate** workflow runs `terraform fmt`,
  `validate`, and `plan`.
- Merge to `main` → the **Deploy** workflow applies the Terraform and syncs
  `site/` to S3.

## Adding a game

1. Drop the new self-contained HTML file into `site/`.
2. Add a card linking to it in `site/index.html`.
3. Open a PR and merge — the pipeline does the rest.
