# Repository Guidelines

## Project Structure & Module Organization

Primary infrastructure code lives in `pulumi_mrsharky/`, with provider-specific logic under `proxmox/`, `pfsense/`, `nixos/`, `remote/`, and shared helpers in `common/`. Legacy or experimental automation is split between `home_infra/` and `misc/`. Tests live in `tests/`, currently focused on Proxmox parsing logic in `tests/proxmox/`. OpenSpec change proposals and specs are stored in `openspec/`.

## Build, Test, and Development Commands

Create a local environment and install dependencies:

```sh
python3 -m venv .venv
. .venv/bin/activate
pip install -r requirements.txt -r requirements.dev.txt
```

Key commands:

- `python main.py`: run the main Python entrypoint for local development.
- `pytest`: run the test suite.
- `pre-commit run --all-files`: run formatting, linting, secret scanning, and Nix formatting hooks.
- `pip-compile --output-file=requirements.txt requirements.in`: refresh runtime dependencies.
- `pip-compile --output-file=requirements.dev.txt requirements.dev.in`: refresh dev dependencies.

## Coding Style & Naming Conventions

Use 4-space indentation and keep Python code compatible with the repository’s current style: type hints where practical, `snake_case` for functions and variables, `PascalCase` for classes, and descriptive module names. Format Python with `black` and sort imports with `isort --profile black`. Lint with `flake8`. Nix files are formatted with `alejandra`.

## Testing Guidelines

Write tests with `pytest` and place them under `tests/` mirroring the module area they cover. Use filenames like `test_<feature>.py` and test names like `test_<behavior>()`. Keep fixtures or static command output near the tests that use them, as in `tests/proxmox/nvidia_lspci_stdout.txt`. Run `pytest` before opening a PR; add or update tests for parser, provisioning, or config-generation changes.

## Commit & Pull Request Guidelines

Recent history favors short, imperative commit subjects such as `Various fixes and updates` and `Added some applications to install`. Keep commits focused and descriptive. For pull requests, include a concise summary, note any infrastructure impact, link related issues or OpenSpec changes, and attach logs or screenshots when changing generated UI, manifests, or provisioning output.

## Security & Configuration Tips

Do not commit real secrets or machine-specific configs. Use example files such as `Pulumi.dev.example.yaml` and `server_mini_example.json` as templates, and let `detect-secrets` guard new changes. Review any edits to `Pulumi.dev.yaml`, SSH material, and host-specific JSON carefully before committing.
