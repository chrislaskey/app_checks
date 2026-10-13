# AppChecks

A library for building app-specific checks. Meant to help both humans and LLMs
write better code and conform to architecture patterns.

Provides a command line tool that can be run in local development when writing code
or in continuous integration pipelines as checks.

## Goals

Checks must be fast to execute even across large codebases. A check runs with
options for both a fast check to identify potential issues and then a slow run
to confirm the violation. A check can implement one or both of these checks.
A common example is identifying files with potential violations using regex
static analysis in the `fast` pass, then running those flagged files through
a AST parser in the `slow` pass.

Supports options for running on all the code, or just the most recent changes
from a given git ref.

## A run

A check is a small function that finds facts: these files, these lines,
break this rule. Driven by the config file and the command line: which checks
run, which files they look at, and what a violation means.

`mix app_checks` does these steps, in order.

1. **Load the config** from `.app_checks.exs`, pick the named config for
   this run, `default` unless the command line names another, and merge
   the command line over it.
2. **Gather the state of the code once**, so no check has to ask git or
   walk the disk itself:
   - every file in the project, and
   - every file the branch changed since it left the base ref, with the
     line numbers it changed in each one.
3. **Select the checks** the config enables, narrowed by the command line.
4. **Run each check** with its config and the state. A check returns its
   violations: a path, a line where there is one, and a message.
5. **Print** each violation with the level the config gives that check.
6. **Exit** `1` if any violation has the level `error`, `0` otherwise, and
   `2` if the config, the arguments or git are wrong.

## The state

Gathered once per run, read-only, shared by every check.

- `base`: the git ref the branch is compared with. `main` by default,
  `base_ref:` in the active config, `--base REF` on the command line.
- `all`: every file in the project. Git tracked files plus untracked files
  that are not ignored, from one `git ls-files` call, so `deps/` and
  `_build/` never appear. Relative paths from the project root.
- `changed`: every file the branch changed since it left the base, with the
  line numbers it changed. Commits, staged and unstaged edits and untracked
  files all count. A deleted file is listed with no lines. An untracked
  file is listed with every line. From one `git diff -U0` call.

Paths on the command line narrow both lists for that run.

## A check

One Rust file in `priv/checks`, built-in or the project's own. It is given
the state and its own config, and returns violations.

```rust
pub struct NoIoInspect;

pub const CHECK: &dyn Check = &NoIoInspect;

impl Check for NoIoInspect {
    fn name(&self) -> &'static str { "no_io_inspect" }

    fn run(&self, state: &State, config: &Config) -> Result<Vec<Violation>, String> {
        let files = state.files(config.scope()).with_extension(&["ex", "exs"]);
        let suspects = fast(files, |file| file.contents.contains("IO.inspect"));
        let violations = slow(suspects, |file| lines_outside_comments(file, "IO.inspect"));
        Ok(state.in_scope(config.scope(), violations))
    }
}
```

The shape every check follows:

1. **Pick the files.** `all` or `changed`, from the `scope` setting the
   config gives the check. A check that is about the branch, such as
   "a protected file must be alone in its pull request", always reads
   `changed` and says so in its docs.
2. **Fast pass** over those files: a cheap test that must never miss a
   real problem. Over-reporting is fine.
3. **Slow pass** over the files the fast pass kept: the careful work, such
   as parsing. Returns the real violations.
4. **Filter to the changed lines** when the scope is `changed`, so a
   violation that was already there on a line the branch did not touch is
   not reported.

The library provides helpers for each step so the check stays a few lines,
but the check calls them. Nothing happens to a check's files or violations
that the check did not ask for.

A check returns facts only: path, line, message. It does not decide whether
the fact is an error or a warning. It does not print. It does not know
about named configs, levels or the command line.

A check declares the config keys it accepts, as today. A key it does not
accept is an error before anything runs.

## Config

`.app_checks.exs` in the project root, in the shape of `.credo.exs`: a map
with named configs, each a complete list of what runs and what it means.

```elixir
%{
  # The project's own checks, compiled in with the built-in ones. One
  # directory for the whole file, since it decides what gets built.
  custom_checks: "priv/checks",

  # `mix app_checks` runs the config named "default". `--config-name review`
  # runs that one instead. Configs do not merge: each one is the whole
  # list for its run.
  configs: [
    %{
      name: "default",
      # The ref the branch is compared with. `--base REF` overrides it.
      base_ref: "main",
      checks: [
        # A check runs only when it is listed here. An atom alone runs with
        # the defaults, `level: :error` and `scope: :all`. A tuple sets
        # either of those, and `config:` holds the check's own keys.
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
        # must be a real check, and may not also be enabled.
        disabled: [
          :human_review
        ]
      ]
    },
    %{
      name: "review",
      base_ref: "main",
      checks: [
        enabled: [
          {:separate_pr, config: [groups: [agents: ["AGENTS.md"]]]},
          {:architect_review, level: :warning, config: [paths: ["config/**"]]},
          {:human_review, level: :warning, config: [paths: ["lib/example/**"]]}
        ]
      ]
    }
  ]
}
```

- `level`: what a violation means. `:error` fails the run, `:warning` is
  printed and does not. Default `:error`.
- `scope`: which files the check looks at. `:all` is every file,
  `:changed` is the files the branch changed and only the lines it changed.
  Default `:all`. A check that is about the branch, such as `separate_pr`,
  reads `changed` whatever the scope says.
- `config`: the check's own keys, refused if the check does not accept
  them. Kept apart from `level` and `scope` so a check can never collide
  with the runner's keys.
- `enabled` is the whole list for that config. A check file that is in
  neither list of the active config does not run, and the summary says
  how many such files there are, so a new check is not silently ignored.
- A name in `enabled` or `disabled` that matches no check file is an
  error. A name in both is an error. A name twice in `enabled` is an error.

The Mix task resolves the active config into a flat list of check, level
and scope, and passes that to the program with each check's config keys.
The program never sees named configs.

## Command line

```sh
mix app_checks                        # the "default" config, over the project
mix app_checks lib test               # narrow both file lists to these paths
mix app_checks --base feature/parent  # compare the branch with another ref
mix app_checks --config-name review   # run another named config instead
mix app_checks --check no_io_inspect  # only this check, from the active config
mix app_checks --scope changed        # every check on changed files only, for this run
mix app_checks --verbose              # print every stage, not only the result
mix app_checks.test                   # the Rust tests of every check
```

`--config-name` is the credo flag, so it is already familiar. `--check`
narrows the active config to one check, with the level and scope that
config gives it; a check the config does not enable is an error. `--scope`
overrides every check's scope for one run, so a tool that only wants to
hear about what it touched can ask for that without editing the config.
`-v` is short for `--verbose`.

## Output

One line per violation:

```
lib/example_web/live/home_live.ex:42: IO.inspect left in, remove it [no_io_inspect, warning]
.app_checks.exs: changed with AGENTS.md from another protected group, open a separate pull request [separate_pr, error]
3 check(s), 1 error(s), 1 warning(s), 1 not listed
```

A check on `all` files prints each violation as soon as the slow pass
finds it. A check on `changed` files prints when the check finishes,
because the last step filters the list. With `--verbose` every check
prints every stage as it happens: the files the fast pass kept, what the
slow pass found in each, and the final list, each labelled with its stage.
The summary line comes last.

## Built-in checks

Each check does one thing, and the config says what it means.

- `core_component_tags`: a template uses a raw tag that the components
  module defines, `<button>` where `<.button>` exists. Config: `paths`,
  the components modules.
- `separate_pr`: a file in a named group changed together with a file
  outside its group. Config: `groups`. Reads `changed` only.
- `architect_review`: a changed path matches a pattern. Config: `paths`.
  Reads `changed` only. Normally a `warning`, so the run prints which
  files need an architect without failing.
- `human_review`: the same shape as `architect_review` with its own
  patterns, for paths an engineer must read.

The old `review_tier` is these three. Its tier ladder, where the highest
match wins, becomes three independent lists that may overlap, and the
reader sees every match.
