# Orb Source

This directory contains the unpacked source for the Neon CircleCI orb.

- `@orb.yml`: top-level orb metadata.
- `commands/`: reusable Neon API commands (`create-branch`, `delete-branch`,
  `reset-branch`).
- `jobs/`: higher-level lifecycle jobs (`run_tests`).
- `executors/`: bundled executor defaults for orb jobs.
- `examples/`: registry examples shown to orb consumers.
- `scripts/`: shell implementations included into command steps.

Pack and validate locally:

```bash
circleci orb pack src > orb.yml
circleci orb validate orb.yml
```
