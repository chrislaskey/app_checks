defmodule Mix.Tasks.AppChecks do
  @shortdoc "Runs the checks, the built-in ones and the project's own"

  @moduledoc """
  Builds and runs the checks: the built-in ones and the project's own in
  `priv/checks`, as `.app_checks.exs` configures them.

      $ mix app_checks                        # the "default" config, over the project
      $ mix app_checks lib test               # only what is under these paths
      $ mix app_checks --base feature/parent  # compare the branch with another ref
      $ mix app_checks --config-name review   # run another named config
      $ mix app_checks --check no_io_inspect  # one check, from the active config
      $ mix app_checks --scope changed        # every check on changed files only
      $ mix app_checks --verbose              # print every stage, not only the result

  Every run gathers the state of the code once, from git: every file in the
  project, and every file the branch changed since it left the base ref,
  with the lines it changed. Git is only read, never fetched. For a branch
  that builds on another unmerged branch, pass `--base` with that branch.

  Each enabled check runs with its config and that state and returns
  violations: a file, a line where there is one, and a message. The config
  says what a violation means: `error` fails the run, `warning` is printed
  and does not. It also says which files a check looks at: `all`, every
  file, or `changed`, only the files the branch changed and only the lines
  it changed, so a problem that was already there on a line the branch did
  not touch is not reported.

  Each violation prints as `file:line: message [check, level]`. A check
  over all files prints each one as soon as it is found. A check over
  changed files prints when it finishes, since the last step filters the
  list. The summary line comes last. The task fails when any violation is
  an error, which is what `mix check` (ex_check) looks for when the task
  is listed as a tool in `.check.exs`.

  The program is built before every run, into `_build`. When nothing
  changed, cargo sees that and the build finishes at once, so a run costs
  about as much as the checks themselves. Rust is needed, see the README.

  ## Configuration

  `.app_checks.exs` in the project root, a map in the shape of
  `.credo.exs`. See `AppChecks.Config` for every key. In short:

      %{
        custom_checks: "priv/checks",
        configs: [
          %{
            name: "default",
            base_ref: "main",
            exclude: ["lib/my_app/admin"],
            checks: [
              enabled: [
                {:core_component_tags, config: [paths: ["lib/my_app_web/components/core_components.ex"]]},
                {:no_io_inspect, level: :warning, scope: :changed},
                {:separate_pr, config: [groups: [agents: ["AGENTS.md"]]]}
              ],
              disabled: [:human_review]
            ]
          }
        ]
      }

  A config's `paths` limit the run to what is under them and its `exclude`
  leaves paths out, so one project can have a config per part of the code.
  Paths given on the command line replace the config's `paths`; `exclude`
  still applies.

  A check runs only when it is enabled in the active config. `--check`
  narrows the run to one of them. `--scope` overrides every check's scope
  for one run, so a tool that only wants to hear about what it touched can
  ask for that without editing the config.

  ## Built-in checks

  `core_component_tags`: a template uses a raw tag that the components
  modules define, `<button>` where `<.button>` exists. The tags are read
  from the modules, so adding `def p` there is all it takes to start
  requiring `<.p>`. Config: `paths`, the modules; without it, the one
  `core_components.ex` under `lib`.

  `separate_pr`: a file in a named group changed together with a file
  outside its group. Config: `groups`, a keyword list of group name to
  path patterns. Keeps the files that decide what gets checked, or who
  reviews, in a pull request of their own.

  `architect_review`: a changed path matches a pattern. Config: `paths`.
  Usually a warning, so the run says which files need an architect.

  `human_review`: the same, for paths an engineer must review rather than
  an automated reviewer alone.

  The three review checks look at what the branch changed whatever their
  scope is. Patterns match the whole path from the project root: `*` does
  not cross a `/`, `**` does.
  """

  use Mix.Task

  alias AppChecks.{Config, Program}

  @impl Mix.Task
  def run(args) do
    {opts, paths} =
      OptionParser.parse!(args,
        strict: [
          base: :string,
          config_name: :string,
          check: :string,
          scope: :string,
          verbose: :boolean
        ],
        aliases: [v: :verbose]
      )

    config = Config.load()
    named = Config.named(config, opts[:config_name] || "default")

    run_opts = [
      base: opts[:base],
      check: opts[:check],
      scope: scope!(opts[:scope]),
      verbose: opts[:verbose]
    ]

    Program.build!(config)
    Program.run!(named, paths, run_opts)
  end

  defp scope!(nil), do: nil

  defp scope!(scope) do
    Enum.find(Config.scopes(), &(to_string(&1) == scope)) ||
      Mix.raise("--scope must be one of #{Enum.map_join(Config.scopes(), ", ", &to_string/1)}")
  end
end
