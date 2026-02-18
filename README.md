# 🟢 Neon CircleCI Orb

[![CircleCI Build Status](https://circleci.com/gh/dhanushreddy291/neon-circle-ci-orb.svg?style=shield "CircleCI Build Status")](https://circleci.com/gh/dhanushreddy291/neon-circle-ci-orb)
[![CircleCI Orb Version](https://badges.circleci.com/orbs/dhanushreddy291/neon.svg)](https://circleci.com/developer/orbs/orb/dhanushreddy291/neon)
[![GitHub License](https://img.shields.io/badge/license-MIT-lightgrey.svg)](https://raw.githubusercontent.com/dhanushreddy291/neon-circle-ci-orb/master/LICENSE)

<p align="left">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="https://neon.com/brand/neon-logo-dark-color.svg">
    <img alt="Neon logo" src="https://neon.com/brand/neon-logo-light-color.svg" width="200">
  </picture>
</p>

This Orb allows you to easily manage **ephemeral Neon Postgres branches** within your CircleCI pipelines.

It enables workflows where you can instantly provision an isolated database for every CI run, run migrations and tests, and automatically clean it up afterwards. This is perfect for testing, preview environments, and database schema validation.

## 🚀 Available Commands

- **`create_branch`**: Create a new copy-on-write branch from your production or staging database.
- **`delete_branch`**: Clean up branches after your pipeline finishes.
- **`reset_branch`**: Reset a long-lived branch (like staging) to the latest production state.

## 🚀 Available Jobs

- **`run_tests`**: A complete, pre-configured job that handles the full lifecycle: create branch → run tests → delete branch.

## ⚙️ Setup

Using this Orb requires a Neon API Key.

1. **Obtain a Neon API key:**
   - Log in to the [Neon Console](https://console.neon.tech).
   - Go to your Account Profile > **API Keys**.
   - Create a new API key.

2. **Add Secrets to CircleCI:**
   - Go to your Project Settings in CircleCI.
   - Navigate to **Environment Variables**.
   - Add the following variables:
     - `NEON_API_KEY`: Your Neon API key.
     - `NEON_PROJECT_ID`: The ID of your Neon project (found in the Settings >
       General tab of your Neon dashboard).

   <p align="left">
      <img src="./assets/circleci-env-vars.png" alt="CircleCI Environment Variables" width="900">
    </p>

3. **Import the Orb:** Add the orb to your `.circleci/config.yml`:

   ```yaml
   version: 2.1

   orbs:
     neon: dhanushreddy291/neon@1.0 # Use the latest version from the CircleCI Orb Registry
   ```

## 📖 Usage

### Option 1: Run all tests with `run_tests`

The easiest way to get started is using the `run_tests` job. It automatically creates a branch, runs your migration and test commands, and ensures the branch is deleted even if tests fail.

```yaml
workflows:
  test-flow:
    jobs:
      - neon/run_tests:
          project_id: NEON_PROJECT_ID
          migrate_command: npm i && npm run db:migrate
          test_command: npm test
```

### Option 2: Manual Branch Management

For more control, you can use the individual steps in your own jobs.

```yaml
jobs:
  test-manual:
    docker:
      - image: cimg/node:lts

    steps:
      - checkout

      - neon/create_branch:
          project_id: NEON_PROJECT_ID
          # Optional: branch_name: "ci-custom-name"

      - run:
          name: Run Migrations and Tests
          command: |
            echo "Connecting to $PGHOST..."
            npm run db:migrate
            npm test

      - neon/delete_branch:
          when: always
```

## 🔧 Commands

### `create_branch`

Creates a new Neon branch and exports connection variables (`DATABASE_URL`, `PGHOST`, `PGPASSWORD`, etc.) to the environment for subsequent steps.

| Parameter          | Type         | Default            | Description                                          |
| ------------------ | ------------ | ------------------ | ---------------------------------------------------- |
| `project_id`       | env_var_name | `NEON_PROJECT_ID`  | Env var containing the Neon Project ID.              |
| `api_key`          | env_var_name | `NEON_API_KEY`     | Env var containing the Neon API Key.                 |
| `branch_name`      | string       | (Auto-generated)   | Custom name for the branch.                          |
| `parent_branch`    | string       | (Default branch)   | The parent branch to fork from.                      |
| `role`             | string       | `neondb_owner`     | The database role to use.                            |
| `database`         | string       | `neondb`           | The database name.                                   |
| `password`         | string       | (Fetched from API) | Password for the selected role.                      |
| `ttl_seconds`      | integer      | `3600`             | Safety limit: branch auto-deletes after this time.   |
| `schema_only`      | boolean      | `false`            | Create a schema-only branch.                         |
| `get_auth_url`     | boolean      | `false`            | Export `NEON_AUTH_URL` when Neon Auth is enabled.    |
| `get_data_api_url` | boolean      | `false`            | Export `NEON_DATA_API_URL` when Data API is enabled. |

### `delete_branch`

Deletes a Neon branch. Defaults to deleting the branch created by the `create_branch` step in the same job.

| Parameter    | Type         | Default           | Description                             |
| ------------ | ------------ | ----------------- | --------------------------------------- |
| `api_key`    | env_var_name | `NEON_API_KEY`    | Env var containing the Neon API Key.    |
| `project_id` | env_var_name | `NEON_PROJECT_ID` | Env var containing the Neon Project ID. |
| `branch_id`  | string       | `$NEON_BRANCH_ID` | The ID of the branch to delete.         |

### `reset_branch`

Resets a branch to the latest state of its parent. Useful for refreshing persistent staging environments.

| Parameter       | Type         | Required | Description                                               |
| --------------- | ------------ | -------- | --------------------------------------------------------- |
| `api_key`       | env_var_name | No       | Env var containing the Neon API Key.                      |
| `project_id`    | env_var_name | No       | Env var containing the Neon Project ID.                   |
| `branch_id`     | string       | **Yes**  | The ID or name of the branch to reset.                    |
| `parent_branch` | string       | No       | The parent branch to reset to (default: original parent). |

## 🌟 Example Workflow

Here is a complete example of a workflow that tests a Node.js application against an ephemeral Neon database.

```yaml
version: 2.1

orbs:
  neon: dhanushreddy291/neon@1.0 # Use the latest version from the CircleCI Orb Registry
  node: circleci/node@7.2.1

workflows:
  build_and_test:
    jobs:
      - neon/run_tests:
          name: test-with-neon
          context: neon-credentials # Context containing NEON_API_KEY and NEON_PROJECT_ID
          executor:
            name: node/default
            tag: "24.12"
          migrate_command: npm ci && npx prisma migrate deploy
          test_command: npm run test:ci
```

### Playwright E2E example

Use this setup when your CI job needs to provision an ephemeral Neon branch and run end-to-end tests with Playwright.

```yaml
version: 2.1

orbs:
  neon: dhanushreddy291/neon@1.0
  node: circleci/node@7.2.1

workflows:
  test-flow:
    jobs:
      - neon/run_tests:
          name: test-with-neon
          executor:
            name: node/default
            tag: "24.12"
          migrate_command: npm ci && npm run db:migrate && npx playwright install --with-deps chromium
          test_command: npm test
```

If you want a complete working project using this pattern, see:

- https://github.com/dhanushreddy291/hono-crud-api

## Resources

- [Neon Documentation](https://neon.com/docs)

## Development

- Pack source: `circleci orb pack src > orb.yml`
- Validate orb: `circleci orb validate orb.yml`
- Orb source docs: `src/README.md`

### Publish to CircleCI registry manually

> [!IMPORTANT]
> Manual publishing is not needed. The Orb is automatically published on every version tag push to GitHub. This section is only for manual releases outside of GitHub. See [How to release](#how-to-release) for the recommended release process that includes automatic publishing.

Run from repository root:

```bash
circleci orb pack src > orb.yml
circleci orb validate orb.yml
```

If this is the first release in the org, run one-time setup:

```bash
circleci namespace create dhanushreddy291 --org-id <CIRCLECI_ORG_ID>
circleci orb create dhanushreddy291/neon
```

Publish a dev version for testing:

```bash
circleci orb publish orb.yml dhanushreddy291/neon@dev:alpha
```

Publish a production release:

```bash
circleci orb publish orb.yml dhanushreddy291/neon@1.0.0
```

Check published versions:

```bash
circleci orb info dhanushreddy291/neon
```

### Test Locally

Use CircleCI CLI to validate and execute orb jobs locally (Docker required).

1. Pack and validate the orb source:

```bash
circleci orb pack src > orb.yml
circleci orb validate orb.yml
```

2. Process the local example pipeline:

```bash
circleci config process tests/example-orb-test.yml > tests/example-orb-test.processed.yml
```

3. Execute a specific job locally:

```bash
circleci local execute -c tests/example-orb-test.processed.yml test-create-delete \
  --env NEON_API_KEY="$NEON_API_KEY" \
  --env NEON_PROJECT_ID="$NEON_PROJECT_ID"
```

You can also run:

```bash
circleci local execute -c tests/example-orb-test.processed.yml test-idempotent-create \
  --env NEON_API_KEY="$NEON_API_KEY" \
  --env NEON_PROJECT_ID="$NEON_PROJECT_ID"
```

## How to release

1. Create a new version tag in GitHub (e.g., `v1.0.0`).

```bash
git tag v1.0.0
git push origin v1.0.0
```

2. This will trigger the CircleCI pipeline that automatically packs, validates, and publishes the orb to the CircleCI registry under `dhanushreddy291/neon` with the version `1.0.0`.
