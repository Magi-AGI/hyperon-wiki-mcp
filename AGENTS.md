# Repository Guidelines

## Project Structure & Module Organization
- Source code belongs in `lib/`, namespaced under `Magi` modules (e.g., `lib/magi/archive/...`); keep files small and grouped by domain.
- Executables and scripts go in `bin/`; keep CLI entrypoints thin and delegate to `lib/`.
- Tests live in `spec/`, mirroring the `lib/` layout with fixtures under `spec/support` or `spec/fixtures`.
- Packaging artifacts land in `pkg/` (ignored). Temporary work should stay in `tmp/` (ignored).

## Build, Test, and Development Commands
- `bundle install` — install Ruby dependencies locally.
- `bundle exec rspec` — run the test suite; add `--format documentation` when debugging.
- `bundle exec rubocop` — lint and auto-check style.
- `bundle exec rake build` — build the gem into `pkg/`; `bundle exec rake install` installs it locally.
- `bundle exec rake console` — open an IRB console with the project loaded for quick exploration.

## Coding Style & Naming Conventions
- Ruby code uses 2-space indentation, snake_case methods/variables, CamelCase classes/modules.
- Keep public APIs under a stable namespace; avoid global monkey-patching.
- Prefer explicit requires at the top of each file; freeze constants and use keyword arguments for clarity.
- Use RuboCop defaults; fix offenses or add minimal, justified cops in `.rubocop.yml`.
- Example: `lib/magi/archive/store.rb` should define `module Magi; module Archive; class Store; end; end; end`.

## Testing Guidelines
- Use RSpec; every new feature or bugfix should ship with an accompanying `_spec.rb`.
- Structure specs with `describe`/`context` blocks; stub external I/O; favor deterministic data via factories/fixtures.
- Aim for meaningful coverage of branches and error handling; prefer fast unit specs and tag slow/integration cases.

## Commit & Pull Request Guidelines
- Write imperative, scoped commit messages (e.g., `Add archive writer validation`); keep commits focused.
- PRs should describe intent, key changes, and any follow-up tasks; link issues when available.
- Include test evidence: command output or a checklist of what you ran; screenshots for CLI/UX output if relevant.
- Note breaking changes and migration steps; request reviews early if the work is large.

## Security & Configuration Tips
- Do not commit secrets; load environment variables from local `.env` files (ignored).
- Keep generated docs (`doc/`, `.yardoc/`, `rdoc/`) and vendor bundles out of git per `.gitignore`.
- When adding new dependencies, prefer well-maintained gems and pin versions in the gemspec.
