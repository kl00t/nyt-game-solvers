# nyt-game-solvers

Game Hub — a public static website of small browser games (Wordle and
Connections solvers, Tic Tac Toe, Top-Down Shooter), served from AWS S3.

This repo holds the **site content only**. All AWS infrastructure lives in
[nyt-game-solvers-infra](https://github.com/kl00t/nyt-game-solvers-infra)
(Terraform). Deployments run through GitHub Actions using an OIDC role that
can only sync files to the site bucket — no stored AWS keys, no
infrastructure permissions.

See [nyt-game-solvers-plan.md](nyt-game-solvers-plan.md) for the original
implementation plan.

## Repository layout

```
├── site/                       # everything deployed to S3
│   ├── index.html              # Game Hub landing page
│   ├── connections-solver.html
│   ├── wordle-solver.html
│   ├── tictactoe.html
│   └── shooter.html
├── tests/                      # browser-run test suites (not deployed)
└── .github/workflows/
    └── deploy.yml              # main: sync site/ to the S3 bucket
```

## Workflow

Push (or merge) a change under `site/**` to `main` → the **Deploy** workflow
syncs `site/` to the bucket and the change is live within a minute at
http://nyt-game-solvers-site-159820161626.s3-website-eu-west-1.amazonaws.com

## Adding a game

1. Drop the new self-contained HTML file into `site/`.
2. Add a card linking to it in `site/index.html`.
3. Open a PR and merge — the pipeline does the rest.

## Running tests

Open the files in `tests/` directly in a browser — each is a self-contained
test page.
