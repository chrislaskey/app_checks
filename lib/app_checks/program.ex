defmodule AppChecks.Program do
  @moduledoc """
  Builds and runs the program that does the checking, a Rust crate in this
  library's `priv/checks`.

  Cargo builds it into the project's `_build` directory, never into the
  dependency. The project's own checks, the `.rs` files in the directory
  named by `custom_checks`, are compiled in with the built-in ones, so one
  program runs them all. A build with nothing changed finishes at once,
  which is why `mix app_checks` builds before every run.

  The program never sees named configs. `arguments/3` turns the chosen one
  into flags: which checks to run, what a violation from each means, which
  files each looks at, and each check's own keys.
  """

  alias AppChecks.Config

  @crate "priv/checks"
  @custom_dir_var "APP_CHECKS_CUSTOM"

  @doc "The directory holding `Cargo.toml`, inside this library."
  def crate_dir, do: Application.app_dir(:app_checks, @crate)

  @doc """
  Where cargo writes the build: `_build/ENV/app_checks`, or `:target_dir`
  in `opts`.
  """
  def target_dir(opts \\ []) do
    opts
    |> Keyword.get_lazy(:target_dir, fn -> Path.join(Mix.Project.build_path(), "app_checks") end)
    |> Path.expand()
  end

  @doc "The built program."
  def binary(opts \\ []), do: Path.join(target_dir(opts), "release/checks")

  @doc """
  Builds the program with the custom checks named in `config`, a loaded
  `AppChecks.Config`. Raises when cargo is missing or the build fails, with
  cargo's output.
  """
  def build!(config, opts \\ []) do
    ensure_cargo!()

    unless File.exists?(binary(opts)) do
      Mix.shell().info("Compiling the checks, this only happens on the first run")
    end

    case cargo(["build", "--release", "--quiet"], config, opts, stderr_to_stdout: true) do
      {_, 0} -> :ok
      {output, _} -> Mix.raise("could not build the checks in #{crate_dir()}:\n\n" <> output)
    end
  end

  @doc """
  Runs the built program with `named`, one config from `AppChecks.Config`,
  over the config's `paths`, or over `paths` when any are given, leaving
  out the config's `exclude`. `opts`:

  - `base:` a git ref that overrides the config's `base_ref` for this run
  - `check:` the name of one enabled check to run on its own
  - `scope:` `:all` or `:changed`, overriding every check's scope
  - `verbose:` print every stage, not only the result
  - `cd:` run in another directory
  - `target_dir:` where the program was built

  Raises when a violation is an error or the program could not run.
  """
  def run!(named, paths, opts \\ []) do
    cmd_opts = [into: IO.stream(), stderr_to_stdout: true] ++ Keyword.take(opts, [:cd])

    case System.cmd(binary(opts), arguments(named, paths, opts), cmd_opts) do
      {_, 0} ->
        :ok

      {_, 1} ->
        Mix.raise("mix app_checks found problems, see the violations above")

      {_, status} ->
        Mix.raise("mix app_checks could not run (exit status #{status}), see the message above")
    end
  end

  @doc """
  Runs the Rust tests of every check, built-in and custom. `args` are passed
  on to `cargo test`, so a name there runs only the matching tests.
  """
  def test!(config, args \\ [], opts \\ []) do
    ensure_cargo!()

    case cargo(["test"] ++ args, config, opts, into: IO.stream(), stderr_to_stdout: true) do
      {_, 0} -> :ok
      {_, _} -> Mix.raise("mix app_checks.test failed, see the output above")
    end
  end

  @doc """
  The command line arguments for the program from `named`, one config, and
  the `opts` of `run!/3`: `--base`, `--verbose` when asked, then for each
  enabled check `--enable`, `--level`, `--scope` and one `--set` per config
  key, then one `--disable` per disabled check, one `--exclude` per
  excluded path, then the paths: `paths` when any are given, the config's
  otherwise.

  With `check:` only that check is enabled; naming one the config does not
  enable raises. With `scope:` every check gets that scope.
  """
  def arguments(named, paths, opts \\ []) do
    base = ["--base", opts[:base] || named.base_ref]
    verbose = if opts[:verbose], do: ["--verbose"], else: []

    enabled =
      named.enabled
      |> only(opts[:check], named)
      |> Enum.map(fn entry ->
        if opts[:scope], do: %{entry | scope: opts[:scope]}, else: entry
      end)

    enable =
      Enum.flat_map(enabled, fn entry ->
        name = to_string(entry.name)

        [
          "--enable",
          name,
          "--level",
          "#{name}=#{entry.level}",
          "--scope",
          "#{name}=#{entry.scope}"
        ] ++
          Enum.flat_map(Config.flatten(entry.config), &["--set", "#{name}.#{&1}"])
      end)

    disable = Enum.flat_map(named.disabled, &["--disable", to_string(&1)])
    exclude = Enum.flat_map(Map.get(named, :exclude, []), &["--exclude", &1])
    paths = if paths == [], do: Map.get(named, :paths, []), else: paths

    base ++ verbose ++ enable ++ disable ++ exclude ++ paths
  end

  defp only(enabled, nil, _named), do: enabled

  defp only(enabled, check, named) do
    name = to_string(check)

    case Enum.filter(enabled, &(to_string(&1.name) == name)) do
      [] ->
        Mix.raise(
          "#{name} is not enabled in the config #{inspect(named.name)}; the enabled checks are: " <>
            Enum.map_join(enabled, ", ", & &1.name)
        )

      found ->
        found
    end
  end

  defp cargo(command, config, opts, cmd_opts) do
    manifest = Path.join(crate_dir(), "Cargo.toml")
    args = command ++ ["--manifest-path", manifest, "--target-dir", target_dir(opts)]

    System.cmd("cargo", args, [env: [{@custom_dir_var, custom_dir(config)}]] ++ cmd_opts)
  end

  # The directory of the project's own checks when it exists, which build.rs
  # reads from the environment. Nil unsets the variable, so a stale value
  # from the shell cannot pull in checks from somewhere else.
  defp custom_dir(config) do
    dir = Path.expand(config.custom_checks)
    if File.dir?(dir), do: dir
  end

  defp ensure_cargo! do
    unless System.find_executable("cargo") do
      Mix.raise("""
      cargo was not found, so the checks could not be built.
      Install Rust with `asdf install` when .tool-versions pins it, or from
      https://rustup.rs
      """)
    end
  end
end
