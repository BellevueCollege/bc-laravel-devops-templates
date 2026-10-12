# BC Laravel DevOps Templates

Shared Azure DevOps YAML pipelines for Bellevue College **Laravel** applications on on-prem Apache (split docroot).

---

## Overview

Each Laravel repo uses two pipeline files that extend templates from this repository:

| Pipeline file | When it runs | What it does |
|---|---|---|
| `azure-pipelines.yml` (CI) | Pull requests and `trunk`/tag pushes | Builds on hosted agents; on PR and `trunk`, rolling-deploys to each test Environment |
| `azure-pipelines-release.yml` (Release) | After a `v*` tag CI run completes | Attaches the build `tar.gz` to the GitHub Release, then rolling-deploys production |

**Build** and GitHub upload run on hosted **ubuntu-latest**. **Deploy** runs on **VirtualMachine** resources registered in Azure DevOps Environments (agents on each Apache node).

---

## Prerequisites

- **Replace Tokens** extension (`replacetokens@6`) in the Azure DevOps organization
- **GitHub service connection** `github-service-connection` with access to this repo and app repos
- **Library variable groups** per environment (token values only — not server paths)
- **Environments** under Pipelines → Environments, each with **VirtualMachine** resources (one agent per Apache node)
- Template repo authorized under **Project Settings → Pipelines → Settings**
- VM agents can reach GitHub (to checkout this template repo for `scripts/deploy-laravel.sh`)
- Deployment agent user: write access to app, public, temp, and backup paths; **no sudo**; `php` on `PATH`
- Apache must be able to read files written by the agent user (check ACLs / group membership)

---

## Setup

1. Copy [examples/azure-pipelines.yml](examples/azure-pipelines.yml) and [examples/azure-pipelines-release.yml](examples/azure-pipelines-release.yml) into the app repo root.
2. Set `appName`, server paths, `testEnvironments`, and `productionEnvironments`.
3. Set each environment entry’s `environment` to the ADO Environment name (e.g. `ApacheTest-C`) and `variableGroup` to the Library group for that stage.
4. Register CI and release pipelines in Azure DevOps.
5. Set release `resources.pipelines[].source` to the **exact** CI pipeline name.
6. Add secret `GITHUB_PAT` on the **release** pipeline for GitHub Release upload.
7. On first run, **Permit** the Environment and template repository if prompted.

Pin the template ref to `refs/tags/v1.0.0` for production; use `refs/heads/trunk` while testing template changes.

### Environment object fields

| Field | Required | Description |
|---|---|---|
| `name` | Yes | Unique stage/job ID with no spaces (e.g. `ApacheTestC`) |
| `displayName` | Yes | Label in the Azure DevOps UI |
| `environment` | Yes | ADO Environment name that holds the VM resources (e.g. `ApacheTest-C`) |
| `variableGroup` | Yes | Library variable group for Replace Tokens |

Do **not** set `sshServiceConnection` or `agentPool` — deploy jobs run on the Environment VM agents.

---

## Server layout

| Path | Typical value |
|---|---|
| App root (non-public) | `/var/www/nonpub/<appname>` |
| Web root (public) | `/var/www/html/<appname>` |
| Temp / archives | `/var/www/nonpub/TEMP/` |
| Backups | e.g. `/var/www/nonpub/backups/<appname>` |

`public/index.php.azuredevops` must load maintenance mode from the app tree (see idlookup). `#{app.path}#` is the relative path from public to the app root (e.g. `/../../nonpub/idlookup`).

---

## Build artifact

- Created on the hosted agent: `composer install --no-dev`, optional `npm ci` / `npm run <npmScript>`.
- Published as `<appName>_$(Build.BuildId).tar.gz` — **no filled `.env`**.
- Includes `.env.azuredevops`, `public/index.php.azuredevops`, `vendor/`, and compiled assets.

---

## Deploy behavior (summary)

Deploy runs **on each VM** in the Environment (rolling, `maxParallel` default `1`):

1. Download the pipeline artifact (same tar on every node).
2. Checkout this template repo for `scripts/deploy-laravel.sh`.
3. Replace Tokens for `.env` and `index.php` under `Agent.TempDirectory` only.
4. Validate archive; extract to a fresh temp directory.
5. Preserve live `storage/` onto the new tree.
6. Backup live app/public (skipped if backup for this build ID already exists).
7. `mv -T` app root; `php artisan down`; copy public onto the **html** filesystem and `mv -T` into web root.
8. Optional `migrate --force` when `runMigrations: true` (default **false**). Note: with rolling, migrate would run on **every** VM — keep false for shared databases unless you add a one-node strategy later.
9. `config:cache`, `event:cache`, `view:cache`, optional `route:cache`, `queue:restart`, `php artisan up`.
10. On failure after swap: restore directories and run `php artisan up`.
11. Retain **3** backups per node; keep `.tar.gz` on the server for audit.

Release deploy downloads the **CI pipeline artifact** (`download: ci`), not the GitHub Release file.

---

## Pipeline parameters (app YAML)

| Parameter | Default | Notes |
|---|---|---|
| `runMigrations` | `false` | Set `true` to run `php artisan migrate --force` (see rolling caveat above) |
| `cacheRoutes` | `true` | Set `false` if the app uses closure routes |
| `npmScript` | `production` | Laravel Mix / Vite production script |
| `runNpm` | `true` | Set `false` if no front-end build |
| `maxParallel` | `1` | VMs updated concurrently in a rolling batch |

Do not put server paths in Library groups. Lock secret tokens in the Library (`app.key`, API keys, OAuth secrets, etc.).

---

## Cluster note

Put **all** cluster nodes for a given site into **one** Environment as VirtualMachine resources (e.g. both Apache test nodes in `ApacheTest-C`). Rolling with `maxParallel: 1` updates them one at a time. Do not list two Environments that both contain the same app unless you intend two independent deploys.

Backups and `.tar.gz` archives are **per node**. Restoring one node does not restore the other.

---

## Manual restore

From a backup directory `<serverBackupPath>/<appName>_<buildId>/` **on that node**:

```bash
# Restore app (same filesystem — mv -T)
mv -T /path/to/backup/app /var/www/nonpub/<appname>

# Restore public (copy from backup)
rm -rf /var/www/html/<appname>
mkdir -p /var/www/html/<appname>
cp -a /path/to/backup/public/. /var/www/html/<appname>/
```

---

## Repository structure

```
bc-laravel-devops-templates/
├── templates/
│   ├── ci/laravel-ci.yml
│   ├── release/laravel-release.yml
│   └── steps/
├── scripts/deploy-laravel.sh
├── examples/
└── README.md
```

---

## Troubleshooting

| Symptom | Likely cause |
|---|---|
| No matching VM resources | Wrong Environment name, or `resourceType` casing; confirm VMs are online in the Environment |
| Deploy cannot checkout templates | VM agent cannot reach GitHub; check network / service connection |
| `php not found` | PHP not on the **deployment agent** user’s PATH |
| Apache cannot read files | Agent umask/ACLs; check `getfacl` and group membership |
| `mv` created nested directory | Missing `mv -T` (use current template script) |
| Tokens left in `.env` | Variable group missing a `#{token}#` name |
| Release deploy wrong archive | Must use `download: ci`, not GitHub asset |
| Site stuck in maintenance after failed deploy | Rollback should run `artisan up`; check deploy logs |
| Stage retry redeployed healthy nodes | ADO retries the whole Environment, not only failed VMs |

---

## idlookup

Library groups **IDLookup Test** and **IDLookup Prod**; Environments **ApacheTest-C** / **ApacheProd-C**; `runMigrations` left at default `false`.

---

## Second app checklist

| Check | Notes |
|---|---|
| Default branch | `trunk` (CI test deploy runs on PR and `refs/heads/trunk`) |
| Environments | VM resources registered; `environment:` matches ADO name |
| `runNpm` | `false` when there is no `package.json` |
| `cacheRoutes` | `false` when the app uses closure routes |
| `runMigrations` | Default `false` until migrate-once strategy is designed |
| `public/index.php.azuredevops` | Include maintenance bootstrap |
| Library groups | One group per deploy stage; Build job has none |
| Template checkout | Each VM agent can clone this repo |

Copy [examples/data-api-azure-pipelines.yml](examples/data-api-azure-pipelines.yml) for an API-only app without a front-end build.

---

## data-api

Laravel 12 API app; same templates with different parameters.

| Parameter | Value |
|---|---|
| `appName` | `data-api` |
| `runNpm` | `false` |
| `cacheRoutes` | `false` (closure routes in `web.php`) |
| `runMigrations` | `false` (default) |
| Test Environment | `ApacheTest-C` |
| Prod Environment | `ApacheProd-C` |

Suggested Library groups: **Data API Test** / **Data API Prod**.

### Replace Tokens — `.env.azuredevops`

Each row is a Library variable name (must match exactly). Lock values that are secrets.

| Variable | Typically secret |
|---|---|
| `app.env` | |
| `app.key` | Yes |
| `app.debug` | |
| `app.url` | |
| `log.channel` | |
| `db.connection` | |
| `default.driver` | |
| `default.host` | |
| `default.port` | |
| `default.username` | |
| `default.password` | Yes |
| `dadb.database` | |
| `odsdb.database` | |
| `empdir.database` | |
| `copilot.database` | |
| `pciforms.database` | |
| `azure.client.id` | |
| `azure.client.secret` | Yes |
| `azure.tenant.id` | |
| `azure.redirect.uri` | |
| `broadcast.driver` | |
| `cache.driver` | |
| `session.driver` | |
| `session.lifetime` | |
| `queue.driver` | |
| `redis.host` | |
| `redis.password` | Yes |
| `redis.port` | |
| `jwt.secret` | Yes |
| `internal.domain` | |

Also set **`app.path`** in the group (used in `public/index.php.azuredevops` for `#{app.path}#`, e.g. `/../../nonpub/data-api`).

Token names differ from idlookup (e.g. `azure.client.id` vs `azure.clientid`). Do not reuse idlookup’s group for data-api without renaming variables.

Quoted placeholders in `.env.azuredevops` (e.g. `DEFAULT_DB_USERNAME="#{default.username}#"`) replace only the `#{...}#` segment; quotes in the file stay unless you also put them in the Library value.
