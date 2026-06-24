# ZFM web interface

Web interface for ZFM.

Note that this project uses Preact, not React.

## Project layout

Two projects live side by side in this directory: the main UI itself, and a Zig project providing Wasm binaries for synth and MML compiler functionality.

## Build and lint

- Use `vp` as the package manager in place of explicit `pnpm` commands
- Use `vp lint` to run lint checks on the entire project, or `vp lint FILE...` to lint specific files
- Use `zig build` to build the Wasm components

## Styling

- When adding new Preact components, use CSS modules (`.module.css`) to scope styles to each component

## Vite+ information

<!--VITE PLUS START-->

### Using Vite+, the Unified Toolchain for the Web

This project is using Vite+, a unified toolchain built on top of Vite, Rolldown, Vitest, tsdown, Oxlint, Oxfmt, and Vite Task. Vite+ wraps runtime management, package management, and frontend tooling in a single global CLI called `vp`. Vite+ is distinct from Vite, and it invokes Vite through `vp dev` and `vp build`. Run `vp help` to print a list of commands and `vp <command> --help` for information about a specific command.
Docs are local at `node_modules/vite-plus/docs` or online at https://viteplus.dev/guide/.

### Review Checklist

- [ ] Run `vp install` after pulling remote changes and before getting started.
- [ ] Run `vp check` and `vp test` to format, lint, type check and test changes.
- [ ] Check if there are `vite.config.ts` tasks or `package.json` scripts necessary for validation, run via `vp run <script>`.
- [ ] If setup, runtime, or package-manager behavior looks wrong, run `vp env doctor` and include its output when asking for help.
<!--VITE PLUS END-->
