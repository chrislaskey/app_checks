# AppChecks

Fast custom checks for an Elixir project, written in Rust and run as one Mix
task. A check is a rule the repository must follow, such as "templates must
use `<.button>` rather than a raw `<button>`" or "a change to `AGENTS.md`
must be the only change in the pull request". The checks read every file
and every change once, run in parallel, and print as they go, so a run on
a large codebase shows progress from the first second. The config says
which checks run, which files each looks at, and what a violation means.

```sh
mix app_checks
```

```
lib/example_web/components/layouts.ex:134: <button> is a raw tag, use <.button> from ExampleWeb.CoreComponents [core_component_tags, error]
lib/example_web/controllers/page_html/home.html.heex:12: <input> is a raw tag, use <.input> from ExampleWeb.CoreComponents [core_component_tags, error]
lib/example_web/components/layouts.ex: ask an architect to review this change [architect_review, warning]
4 check(s), 2 error(s), 1 warning(s)
```

Four checks are built in. The project adds its own as `.rs` files in
`priv/checks`, which are compiled in with the built-in ones.

## Install

Rust is needed to build the checks. Pin it in `.tool-versions` so
`asdf install` sets it up, or install it from <https://rustup.rs>.

With [igniter](https://hexdocs.pm/igniter):

```sh
mix igniter.install app_checks
```

Without it, add the dependency and run the installer, or do its steps by
hand:

```elixir
{:app_checks, "~> 0.1", only: [:dev, :test], runtime: false}
```

1. Write `.app_checks.exs` in the project root, see "Configuration" below.
   A project with no `core_components.ex` under `lib` leaves
   `core_component_tags` out of `enabled`.
2. With [ex_check](https://hexdocs.pm/ex_check), list the task as a tool in
   `.check.exs` so `mix check` runs it with everything else:

   ```elixir
   [
     tools: [
       {:app_checks, "mix app_checks"}
     ]
   ]
   ```

3. Add `rust 1.99.0` to `.tool-versions`. Any version from 1.85 works.

The first run builds the program into `_build`, which takes a little while.
Every run after that builds too, but when nothing changed cargo finishes at
once, so a run costs about as much as the checks themselves.

### CI

Set up Rust next to Elixir and cache `_build`. On GitHub Actions:

```yaml
- uses: actions/checkout@v4
  with:
    fetch-depth: 0 # the whole history, so the base branch is there to compare with

- name: Read the Rust version
  id: rust
  run: echo "version=$(awk '$1 == "rust" { print $2 }' .tool-versions)" >> "$GITHUB_OUTPUT"

- uses: dtolnay/rust-toolchain@master
  with:
    toolchain: ${{ steps.rust.outputs.version }}
```

The checks compare the branch with the config's `base_ref`. On a pull
request opened against another branch, pass that branch instead:

```sh
mix app_checks --base origin/${{ github.base_ref }}
```

## Run

```sh
mix app_checks                        # the "default" config, over the project
mix app_checks lib test               # only what is under these paths
mix app_checks --base feature/parent  # compare the branch with another ref
mix app_checks --config-name review   # run another named config
mix app_checks --check no_io_inspect  # one check, from the active config
mix app_checks --scope changed        # every check on changed files only
mix app_checks --verbose              # print every stage, not only the result
mix app_checks.test                   # the Rust tests of every check
```

## How a run works

1. The task reads `.app_checks.exs`, picks the named config, `default`
   unless `--config-name` says otherwise, and merges the command line over
   it.
2. The program gathers the state of the code once, from git, so no check
   has to: every file in the project, from `git ls-files`, and every file
   the branch changed since it left the base ref, with the lines it
   changed, from `git diff`. Commits, staged and unstaged edits and
   untracked files all count. Git is only read, never fetched.
3. Each enabled check runs in turn with its config and that state, and
   returns violations: a file, a line where there is one, and a message.
4. Each violation prints with the check's level. `error` fails the run,
   `warning` does not.
5. The summary line comes last. The exit code is `1` when any violation
   is an error, `0` otherwise, and `2` when the config, the arguments or
   git are wrong.

Each line is `file:line: message [check, level]`. A violation about a
whole file has no line. A check over `all` files prints each violation as
soon as it is found. A check over `changed` files prints when it finishes,
because its last step filters the list. With `--verbose` every check
prints every stage as it happens, labelled `fast` and `slow`, and then the
result.

### Scope

A check looks at `all` files, every file in the project, or at `changed`
files, only the files the branch changed, and reports only the lines it
changed. With `changed`, a `<button>` the branch added on line 3 is
reported, one that was already there on line 2 is not, and a file the
branch did not touch is not read at all. An untracked file is new, so
every line of it counts. A file where the branch only removed lines has
nothing in scope.

This is how a new or stricter check lands in a large codebase without a
sweep through every file first. The whole file is still given to the
check, so the careful pass has its full context. Two things to know: on
the default branch there is nothing changed, so a `changed` check checks
nothing there; and a change elsewhere that creates a violation on an
untouched line, such as adding `def p` to the components module, is only
seen by an `all` check.

The checks about the branch, such as `separate_pr`, read what the branch
changed whatever their scope is.

## Configuration

`.app_checks.exs` in the project root, a map in the shape of `.credo.exs`:
named configs, each a complete list of what runs and what it means.

```elixir
%{
  # The project's own checks, compiled in with the built-in ones. One
  # directory for the whole file, since it decides what gets built
  custom_checks: "priv/checks",

  # `mix app_checks` runs the config called "default". `--config-name review`
  # runs that one instead. Configs do not merge: each one is the whole list
  # for its run
  configs: [
    %{
      name: "default",
      # The git ref the branch is compared with. `--base REF` overrides it
      base_ref: "origin/main",
      checks: [
        # A check runs only when it is listed here. An atom alone runs with
        # the defaults, `level: :error` and `scope: :all`. A tuple sets either
        # of those, and `config:` holds the check's own keys
        enabled: [
          :example_check,
          {:no_io_inspect, level: :warning, scope: :changed},
          {:core_component_tags,
           config: [paths: ["lib/example_web/components/core_components.ex"]]},
          {:architect_review,
           level: :warning,
           config: [paths: ["config/**", "mix.exs", "lib/example_web/router.ex"]]},
          {:separate_pr,
           config: [
             groups: [
               agents: ["AGENTS.md"],
               lint_config: [".credo.exs", ".check.exs", ".app_checks.exs"]
             ]
           ]}
        ],
        # Checks the project knows about and chose not to run. A name here
        # must be a real check, and may not also be enabled
        disabled: [:human_review]
      ]
    },
    %{
      name: "review",
      checks: [
        enabled: [
          {:separate_pr, config: [groups: [agents: ["AGENTS.md"]]]},
          {:human_review, level: :warning, config: [paths: ["lib/example/**"]]}
        ]
      ]
    }
  ]
}
```

- `level`: what a violation means. `:error` fails the run, `:warning` is
  printed and does not. Default `:error`.
- `scope`: which files the check looks at, `:all` or `:changed`. Default
  `:all`.
- `config`: the check's own keys, refused if the check does not accept
  them. The task flattens them into `--set check.key=value` flags: a list
  gives the key once per element and a nested keyword list adds a segment,
  so `groups: [agents: ["AGENTS.md"]]` becomes
  `--set separate_pr.groups.agents=AGENTS.md`.
- `enabled` is the whole list for that config. A check file in neither
  list of the active config does not run, and the summary says how many
  such files there are, so a new check is not silently ignored.
- A name that matches no check file is an error. A name in both lists, or
  twice in `enabled`, is an error. So is an unknown key anywhere.

`--check NAME` narrows the active config to one check, with the level and
scope that config gives it. `--scope changed` overrides every check's scope
for one run, so a tool that only wants to hear about what it touched can
ask for that without editing the config.

## Built-in checks

Each check does one thing, and the config says what it means.

### `core_component_tags`

A template uses a raw tag that the components modules define: `<button>`
where `<.button>` exists. The tags are read from the modules themselves,
once, before any file is read. Every public `def` whose name could be an
HTML tag counts, so adding `def p` to the module is all it takes to start
requiring `<.p>`. The module files themselves are skipped. In an `.ex`
file only the `~H` templates count, so a mention in a doc string or a
comment is not a violation.

One key, `paths`: the components modules, one or several when the design
system spans files. Without it, the one file called `core_components.ex`
under `lib`. None or several is an error that says to set the paths.

### `separate_pr`

A file in a named group changed together with a file outside its group.
Several files from the same group may change together, nothing else may
change with them. This keeps the files that decide what gets checked, or
who reviews, in a pull request of their own. One key, `groups`, a keyword
list of group name to path patterns. No groups is an error.

### `architect_review`

A changed path matches one of the patterns under `paths`, for shared code,
configuration and dependencies. Usually a `warning`, so the run says which
files need an architect without failing. Pair it with a CODEOWNERS file
that requires the approval.

### `human_review`

The same, for paths an engineer must review rather than an automated
reviewer alone, such as contexts, schemas and tests. Paths that match
nothing, such as templates and docs, can go through an automated review.

Patterns in the three review checks match the whole path from the project
root. `*` does not cross a `/`, `**` does. These checks read what the
branch changed whatever their scope is, and every violation is about a
file.

## Writing a check

Every `.rs` file in `priv/checks` is a check. Dropping a file in is enough
to include it: the build lists the directory and compiles the file in with
the built-in ones. A file named like a built-in check stops the build. The
check runs once it is enabled in the config.

A check implements `Check` from the crate's `check` module and exports
itself as `CHECK`:

- `name` returns the file name without `.rs`, which is how the config
  refers to the check and what is shown next to each violation. A
  generated test fails the build when the two differ.
- `run` is given the `State` and the check's `Config` and returns
  `Violation`s, or an error message when the config cannot be used.

Here is a complete check that forbids `IO.inspect`, saved as
`priv/checks/no_io_inspect.rs`:

```rust
use crate::check::{fast, slow, Check, Config, Files, State, Violation};

pub struct NoIoInspect;

pub const CHECK: &dyn Check = &NoIoInspect;

impl Check for NoIoInspect {
    fn name(&self) -> &'static str {
        "no_io_inspect"
    }

    fn run(&self, state: &State, config: &Config) -> Result<Vec<Violation>, String> {
        let files = state.files(config.scope()).with_extension(&["ex", "exs"]);
        let suspects = fast(config, files, |file| file.contents().contains("IO.inspect"));
        let violations = slow(config, suspects, |file| {
            file.contents()
                .lines()
                .enumerate()
                .filter(|(_, line)| line.contains("IO.inspect") && !line.trim_start().starts_with('#'))
                .map(|(index, _)| Violation::at(index + 1, "remove the IO.inspect call"))
                .collect()
        });
        Ok(state.in_scope(config.scope(), violations))
    }
}
```

The four lines of `run` are the shape every check about files follows:

1. **Pick the files.** `state.files(config.scope())` is every file, or the
   files the branch changed, as the config says. `with_extension` keeps the
   ones the check applies to.
2. **The fast pass.** `fast` keeps the files the closure says yes to, in
   parallel. It is a cheap test that must never miss a real problem.
   Over-reporting is fine.
3. **The slow pass.** `slow` runs the closure on each kept file, in
   parallel, and collects the violations. This is the careful work, such
   as parsing. `Violation::at(line, message)` is on a line of the file in
   hand; `slow` fills in the path.
4. **Keep what is in scope.** `state.in_scope` drops violations on lines
   the branch did not change when the scope is `changed`, and does
   nothing otherwise.

The check calls each helper itself, so nothing happens to its files or
violations that it did not ask for. A check about the branch rather than
about a file reads `state.changed()`, every changed path with its lines,
deleted files included, and returns `Violation::file(path, message)` for
each. `Violation::run(message)` is about the whole run. The built-in
`separate_pr` is a worked example.

Read a file's contents with `file.contents()`. They are read from disk the
first time any check asks and shared after that. `file.line_of(offset)` is
the line of a byte offset.

### Config keys

A check that needs configuration declares the keys it accepts and reads
them from `Config`:

```rust
fn config_keys(&self) -> &'static [&'static str] {
    &["paths", "groups.*"]
}
```

A key ending in `.*` accepts any one more segment, so `groups.*` accepts
`groups.agents`. The runner refuses any other key before any check runs.
`config.one(key)` is the last value, `config.many(key)` every value, and
`config.under(prefix)` every key below `prefix.` with the prefix removed,
which is how `groups.agents` and `groups.lint_config` become named groups.
`config.scope()` and `config.level()` are the runner's keys.

A check that does expensive work from its config, such as reading a module
or building a regular expression, does it in `prepare`, which the runner
calls once for every enabled check before anything runs or prints. Return
an `Err` naming what is wrong rather than falling back to a default: a
check that quietly checks nothing is worse than no check. An `Err` from
`prepare` or `run` stops the run with exit code 2. The built-in
`core_component_tags` reads the components modules in `prepare` and keeps
the result in a `OnceLock`. `glob_set(key, patterns)` builds a matcher
from path patterns and refuses an empty list or a bad pattern.

### Testing a check

Each check file ends with its own tests, run with `mix app_checks.test`.
The helpers in `check::testing` keep them short:

- `state()` builds a `State` file by file: `.file(path, contents)` for a
  file the branch did not touch, `.changed(path, contents, &[lines])` for
  one it changed on those lines, `.added(path, contents)` for a new one,
  `.deleted(path)`, then `.build()`.
- `config(check, &[(key, value)])` is a config for the check with those
  keys, as an error over all files. `scoped(check, scope, keys)` sets the
  scope.
- `run(check, state, config)` prepares and runs the check and returns each
  violation as `path:line: message`, in path and line order.
- `error(check, state, config)` is the message when preparing or running
  fails.

Tests for the `IO.inspect` check above:

```rust
#[cfg(test)]
mod tests {
    use super::*;
    use crate::check::testing::{config, run, scoped, state};
    use crate::check::Scope;

    #[test]
    fn skips_comments() {
        let state = state().file("a.ex", "# IO.inspect\nIO.inspect(x)\n").build();
        assert_eq!(
            run(&NoIoInspect, &state, &config(&NoIoInspect, &[])),
            vec!["a.ex:2: remove the IO.inspect call"]
        );
    }

    #[test]
    fn the_changed_scope_skips_old_lines() {
        let state = state().changed("a.ex", "IO.inspect(x)\nIO.inspect(y)\n", &[2]).build();
        assert_eq!(
            run(&NoIoInspect, &state, &scoped(&NoIoInspect, Scope::Changed, &[])),
            vec!["a.ex:2: remove the IO.inspect call"]
        );
    }
}
```

### Writing a good check

- **The fast pass must not miss anything.** It is fine for it to
  over-report. It is not fine for it to stay quiet on a real problem,
  because the slow pass only looks at files the fast pass kept.
- **The slow pass may rescan the whole file.** It does not need to know
  what the fast pass found.
- **Write the message as an instruction.** Say what to use instead, as in
  `use <.p> from CoreComponents`. The reader may be a person or a tool
  fixing the code without any other context.
- **Skip files early.** Filter by extension before reading anything. A
  file is only read from disk when a check asks for its contents.
- **Do the expensive work once**, in `prepare`, not inside the closures,
  which run on every file.
- **Refuse bad config loudly.** Return an error for a value you cannot
  use, naming the key, rather than falling back to a default.
- **Leave the meaning to the config.** A check returns facts. Whether a
  fact fails the run is `level`, and whether old code counts is `scope`.

## How it is built

The program is a Rust crate in this library's `priv/checks`. `mix app_checks`
builds it with cargo into `_build/ENV/app_checks` of the project, never into
the dependency, and tells the build where the project's own checks are
through the `APP_CHECKS_CUSTOM` environment variable. The build script lists
both directories and generates the list of checks, so there is nothing to
register.

To work on the crate directly:

```sh
cargo build --release --manifest-path deps/app_checks/priv/checks/Cargo.toml --target-dir _build/dev/app_checks
APP_CHECKS_CUSTOM=$PWD/priv/checks cargo test --manifest-path deps/app_checks/priv/checks/Cargo.toml --target-dir _build/dev/app_checks
```

The program never sees named configs. The task resolves the active one
into flags: `--base REF`, `--verbose`, then per enabled check `--enable
NAME`, `--level NAME=LEVEL`, `--scope NAME=SCOPE` and one
`--set NAME.KEY=VALUE` per config key, then `--disable NAME` per disabled
check, then the paths.

| Path | What it is |
|---|---|
| `priv/checks/src/main.rs` | The runner. Parses the flags, prepares the enabled checks, gathers the state from git, runs each check, prints its violations, then the summary, and sets the exit code. |
| `priv/checks/src/check.rs` | The `Check` trait, the `State`, `File`, `Config` and `Violation` types, the `fast`, `slow` and `glob_set` helpers, and the `testing` helpers. |
| `priv/checks/build.rs` | Runs at compile time. Lists the built-in and custom checks, generates the `checks` module with `all()`, and a test that each check's `name` matches its file name. |
| `priv/checks/src/checks/` | The built-in checks, one file each. |
| `lib/app_checks/config.ex` | Reads and validates `.app_checks.exs`. |
| `lib/app_checks/program.ex` | Builds the crate, turns a named config into flags and runs it. |
| `lib/mix/tasks/` | `mix app_checks`, `mix app_checks.test` and `mix app_checks.install`. |
