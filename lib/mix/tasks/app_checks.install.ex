if Code.ensure_loaded?(Igniter) do
  defmodule Mix.Tasks.AppChecks.Install do
    @shortdoc "Sets up `mix app_checks` in the project"

    @moduledoc """
    #{@shortdoc}. Run by `mix igniter.install app_checks`, or on its own
    after adding the dependency.

        $ mix igniter.install app_checks
        $ mix app_checks.install

    What it does, each step only when needed:

    - Keeps the dependency out of releases: `only: [:dev, :test]` and
      `runtime: false` on `app_checks` in `mix.exs`.
    - Writes `.app_checks.exs` with one config that enables every built-in
      check, commented. The `core_component_tags` check is listed as
      disabled when there is no `core_components.ex` under `lib`, since it
      needs one.
    - Lists `mix app_checks` as a tool in `.check.exs` when the project has
      ex_check, creating the file when it is missing, so `mix check` runs it.
    - Pins Rust in `.tool-versions` when the file exists without it, so
      `asdf install` sets it up.

    Rust is needed to build the checks. It is not installed by this task.
    """

    use Igniter.Mix.Task

    # The version pinned in .tool-versions. The crate needs 1.85 or later.
    @rust_version "1.99.0"
    # An explicit tuple, so it is not mistaken for a keyword pair when printed
    @tool {:{}, [], [:app_checks, "mix app_checks"]}

    @impl Igniter.Mix.Task
    def info(_argv, _composing_task) do
      %Igniter.Mix.Task.Info{
        group: :app_checks,
        example: "mix igniter.install app_checks"
      }
    end

    @impl Igniter.Mix.Task
    def igniter(igniter) do
      igniter
      |> dev_and_test_only()
      |> create_config()
      |> add_check_tool()
      |> pin_rust()
      |> Igniter.add_notice("""
      mix app_checks needs Rust to build the checks. Install it with
      `asdf install` when .tool-versions pins it, or from https://rustup.rs,
      then run `mix app_checks`. See the app_checks README for CI.
      """)
    end

    defp dev_and_test_only(igniter) do
      if Igniter.Project.Deps.has_dep?(igniter, :app_checks) do
        igniter
        |> Igniter.Project.Deps.set_dep_option(:app_checks, :only, [:dev, :test])
        |> Igniter.Project.Deps.set_dep_option(:app_checks, :runtime, false)
      else
        igniter
      end
    end

    defp create_config(igniter) do
      path = AppChecks.Config.file_name()

      if Igniter.exists?(igniter, path) do
        igniter
      else
        Igniter.create_new_file(igniter, path, config_template(igniter))
      end
    end

    defp config_template(igniter) do
      {tags_enabled, tags_disabled} =
        if components_module?(igniter) do
          {"          :core_component_tags,\n", "disabled: []"}
        else
          {"",
           """
           # core_component_tags reads the tags to require from core_components.ex,
           # which this project does not have. Enable it when the module exists
                   disabled: [:core_component_tags]\
           """}
        end

      """
      # Configuration for `mix app_checks`, in the shape of `.credo.exs`. See
      # `mix help app_checks` for every key and the config of each check.
      %{
        # The project's own checks, one .rs file each, compiled in with the
        # built-in ones. See the app_checks README for how to write one
        custom_checks: "priv/checks",
        # `mix app_checks` runs the config called "default". Add another and
        # run it with `mix app_checks --config-name NAME`
        configs: [
          %{
            name: "default",
            # The git ref the branch is compared with, at the point the branch
            # left it. Only read, never fetched. `--base REF` overrides it
            base_ref: "origin/main",
            checks: [
              # A check runs only when it is listed here. `level: :warning`
              # prints a violation without failing the run. `scope: :changed`
              # limits a check to the files and lines the branch changed.
              # `config:` holds the check's own keys
              enabled: [
      #{tags_enabled}          # Files that decide what gets checked or who reviews. A pull
                # request that changes a file in a group may change other files
                # in the same group and nothing else
                {:separate_pr,
                 config: [
                   groups: [
                     agents: ["AGENTS.md"],
                     codeowners: [".github/CODEOWNERS"],
                     lint_config: [".credo.exs", ".check.exs", ".app_checks.exs"],
                     checks: ["priv/checks/**"]
                   ]
                 ]},
                # Shared code, configuration and dependencies
                {:architect_review,
                 level: :warning,
                 config: [
                   paths: [
                     "config/**",
                     "mix.exs",
                     "mix.lock",
                     "lib/*_web.ex",
                     "lib/*_web/router.ex",
                     "lib/*_web/endpoint.ex",
                     "lib/*_web/components/**",
                     ".github/**"
                   ]
                 ]},
                # Feature work, which an automated reviewer alone cannot approve
                {:human_review,
                 level: :warning,
                 config: [paths: ["lib/**/*.ex", "priv/repo/**", "test/**"]]}
              ],
              #{tags_disabled}
            ]
          }
        ]
      }
      """
    end

    # Whether the project has a core_components.ex under lib, the file the
    # core_component_tags check reads when its paths setting is not given.
    defp components_module?(igniter) do
      igniter
      |> Igniter.include_glob("lib/**/core_components.ex")
      |> Map.fetch!(:rewrite)
      |> Rewrite.sources()
      |> Enum.any?(&(Path.basename(&1.path) == "core_components.ex"))
    end

    defp add_check_tool(igniter) do
      cond do
        not Igniter.Project.Deps.has_dep?(igniter, :ex_check) ->
          igniter

        Igniter.exists?(igniter, ".check.exs") ->
          Igniter.update_elixir_file(igniter, ".check.exs", &append_tool/1)

        true ->
          Igniter.create_new_file(igniter, ".check.exs", """
          # Configuration for `mix check` (ex_check), the one command to run before
          # a commit. See `mix help check`.
          [
            tools: [
              # The checks in priv/checks and the built-in ones, see `mix help app_checks`
              {:app_checks, "mix app_checks"}
            ]
          ]
          """)
      end
    end

    # The file is one keyword list, possibly after other expressions that
    # compute a tool's command, so the list is the last expression at the
    # top level. An existing tools list is appended to in place, which keeps
    # its layout and comments. A missing one is created.
    defp append_tool(zipper) do
      list =
        zipper
        |> Igniter.Code.Common.maybe_move_to_block()
        |> Igniter.Code.Common.rightmost()

      cond do
        not Igniter.Code.List.list?(list) ->
          {:warning,
           ".check.exs does not end with a keyword list, so `mix app_checks` was not added " <>
             "to its tools. Add `{:app_checks, \"mix app_checks\"}` by hand."}

        match?({:ok, _}, Igniter.Code.Keyword.get_key(list, :tools)) ->
          {:ok, tools} = Igniter.Code.Keyword.get_key(list, :tools)

          Igniter.Code.List.append_new_to_list(tools, @tool, fn item, _tool ->
            Igniter.Code.Tuple.elem_equals?(item, 0, :app_checks)
          end)

        true ->
          Igniter.Code.Keyword.set_keyword_key(list, :tools, [@tool])
      end
    end

    defp pin_rust(igniter) do
      if Igniter.exists?(igniter, ".tool-versions") do
        Igniter.update_file(igniter, ".tool-versions", fn source ->
          content = Rewrite.Source.get(source, :content)

          if content =~ ~r/^rust\s/m do
            source
          else
            content =
              if content == "" or String.ends_with?(content, "\n"),
                do: content,
                else: content <> "\n"

            Rewrite.Source.update(source, :content, content <> "rust #{@rust_version}\n")
          end
        end)
      else
        igniter
      end
    end
  end
else
  defmodule Mix.Tasks.AppChecks.Install do
    @shortdoc "Sets up `mix app_checks` in the project | Install `igniter` to use"

    @moduledoc """
    #{@shortdoc}

    The installer uses igniter to edit the project. Without it, follow the
    manual steps in the app_checks README.
    """

    use Mix.Task

    @impl Mix.Task
    def run(_argv) do
      Mix.shell().error("""
      The task 'app_checks.install' requires igniter. Please install igniter and try again,
      or follow the manual steps in the app_checks README.

      For more information, see: https://hexdocs.pm/igniter/readme.html#installation
      """)

      exit({:shutdown, 1})
    end
  end
end
